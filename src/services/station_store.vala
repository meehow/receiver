// Station store - SQLite-backed station data
namespace Receiver {

    public class StationStore : Object, ListModel {
        private Sqlite.Database? db;
        private GenericArray<Station> filtered_stations;
        private string _search_query = "";
        private string _language_filter = "";
        private string[] _available_languages;
        private HashTable<int64?, bool> failed_stations;

        private const string COLS = "id, source, name, homepage, country, streams_raw, tags_raw, image_width, image_hash";

        public string search_query {
            get { return _search_query; }
            set {
                if (_search_query != value) {
                    _search_query = value;
                    apply_filter();
                    notify_property("search-query");
                }
            }
        }

        public string language_filter {
            get { return _language_filter; }
            set {
                if (_language_filter != value) {
                    _language_filter = value;
                    apply_filter();
                    notify_property("language-filter");
                }
            }
        }

        public int total_count { get; private set; default = 0; }
        public bool is_loading { get; private set; default = false; }
        public signal void loading_started();
        public signal void loading_finished(int count);
        public signal void loading_error(string message);
        public signal void station_failed(int64 station_id);
        public signal void station_cleared(int64 station_id);
        public signal void favourites_changed();

        public StationStore() {
            filtered_stations = new GenericArray<Station>();
            _available_languages = {};
            failed_stations = new HashTable<int64?, bool>(int64_hash, int64_equal);
        }

        // ListModel interface
        public Object? get_item(uint pos) {
            return pos < filtered_stations.length ? filtered_stations[(int)pos] : null;
        }
        public Type get_item_type() {
            return typeof(Station);
        }
        public uint get_n_items() {
            return filtered_stations.length;
        }



        // Failed station tracking
        public void mark_station_failed(int64 id) {
            if (!failed_stations.contains(id)) {
                failed_stations.insert(id, true);
                station_failed(id);
            }
        }

        public void clear_station_failed(int64 id) {
            if (failed_stations.contains(id)) {
                failed_stations.remove(id);
                station_cleared(id);
            }
        }

        public bool is_station_failed(int64 id) {
            return failed_stations.contains(id);
        }

        // Favourites (delegates to AppState)
        public bool is_favourite(int64 id) {
            return AppState.get_default().is_favourite(id);
        }
        public void toggle_favourite(Station station) {
            AppState.get_default().toggle_favourite(station);
            favourites_changed();
        }

        public void open(string path) {
            is_loading = true;
            loading_started();

            if (Sqlite.Database.open_v2(path, out db, Sqlite.OPEN_READONLY) != Sqlite.OK) {
                is_loading = false;
                loading_error("Cannot open database");
                return;
            }

            Sqlite.Statement stmt;
            db.prepare_v2("SELECT COUNT(*) FROM stations", -1, out stmt);
            if (stmt.step() == Sqlite.ROW) {
                total_count = stmt.column_int(0);
            }

            _available_languages = load_languages();

            // Default to user's locale language on first launch only
            if (_language_filter == "") {
                string? country;
                string? lang;
                detect_locale(out country, out lang);
                string? target = locale_to_language_code(lang, country);
                if (target != null) {
                    foreach (var code in _available_languages) {
                        if (code == target) {
                            language_filter = target;
                            break;
                        }
                    }
                }
                // If no locale match, mark as explicitly "all"
                if (_language_filter == "") {
                    language_filter = "all";
                }
            }

            apply_filter();

            is_loading = false;
            loading_finished(total_count);
        }

        public Station? get_station_by_id(int64 id) {
            if (db == null) {
                return null;
            }
            Sqlite.Statement stmt;
            db.prepare_v2("SELECT " + COLS + " FROM stations WHERE id = ?", -1, out stmt);
            stmt.bind_int64(1, id);
            if (stmt.step() == Sqlite.ROW) {
                return parse(stmt);
            }
            return null;
        }

        public GenericArray<Station> get_featured_stations(int limit = 10) {
            var result = new GenericArray<Station>();
            if (db == null) {
                return result;
            }
            Sqlite.Statement stmt;
            db.prepare_v2(
                "SELECT " + COLS + " FROM stations WHERE source = 2 ORDER BY RANDOM() LIMIT ?",
                -1,
                out stmt
            );
            stmt.bind_int(1, limit);
            while (stmt.step() == Sqlite.ROW) {
                result.add(parse(stmt));
            }
            return result;
        }

        public GenericArray<Station> get_local_stations(int limit = 50) {
            var result = new GenericArray<Station>();
            if (db == null) {
                return result;
            }

            string? country;
            string? language;
            detect_locale(out country, out language);

            if (country == null) {
                return get_featured_stations(limit);
            }

            var img_filter = "image_width >= 200 AND image_height >= 200 AND CAST(image_width AS REAL) / image_height BETWEEN 0.8 AND 1.2";
            Sqlite.Statement stmt;
            db.prepare_v2(
                "SELECT " + COLS + " FROM stations"
                + " WHERE (country_code = ? OR languages_raw LIKE ?) AND " + img_filter
                + " ORDER BY CASE"
                + "   WHEN country_code = ? AND languages_raw LIKE ? THEN 0"
                + "   WHEN country_code = ? THEN 1"
                + "   ELSE 2 END, RANDOM()"
                + " LIMIT ?",
                -1,
                out stmt
            );
            var lang_pattern = "%" + (language ?? country) + "%";
            stmt.bind_text(1, country);         // WHERE country_code = ?
            stmt.bind_text(2, lang_pattern);    // WHERE languages_raw LIKE ?
            stmt.bind_text(3, country);         // CASE: country_code = ?
            stmt.bind_text(4, lang_pattern);    // CASE: languages_raw LIKE ?
            stmt.bind_text(5, country);         // CASE: country_code = ?
            stmt.bind_int(6, limit);            // LIMIT ?
            while (stmt.step() == Sqlite.ROW) {
                result.add(parse(stmt));
            }

            // Fallback to SomaFM if no local stations found
            if (result.length == 0) {
                return get_featured_stations(limit);
            }
            return result;
        }

        private string? locale_to_language_code(string? lang, string? country) {
            if (lang == null) return null;
            // Map specific locale combinations to database language codes
            if (lang == "de" && country == "CH") return "gsw";  // Swiss German
            if (lang == "zh" && country == "HK") return "yue";  // Cantonese
            if (lang == "es" && country != null && country != "ES") {
                // Latin American Spanish
                switch (country) {
                    case "MX": case "AR": case "CO": case "CL": case "PE":
                    case "VE": case "EC": case "GT": case "CU": case "BO":
                    case "DO": case "HN": case "PY": case "SV": case "NI":
                    case "CR": case "PA": case "UY":
                        return "es-419";
                }
            }
            // Map locale codes to database language codes
            switch (lang) {
                case "nb": return "no";   // Norwegian Bokmål
                case "nn": return "no";   // Norwegian Nynorsk
                case "hsb": return "wen"; // Upper Sorbian
                case "dsb": return "wen"; // Lower Sorbian
                case "tl": return "fil";  // legacy Tagalog → Filipino
            }
            return lang;
        }

        private void detect_locale(out string? country, out string? language) {
            country = null;
            language = null;
            string? locale = Environment.get_variable("LANG");
            if (locale == null) return;
            int sep = locale.index_of_char('_');
            if (sep < 2 || locale.length < sep + 3) return;
            language = locale.substring(0, sep).down();  // "de" stays "de"
            country = locale.substring(sep + 1, 2);      // "CH" from de_CH
        }

        public GenericArray<Station> get_favourite_stations() {
            return AppState.get_default().get_favourite_stations();
        }

        public string[] get_available_languages() {
            return _available_languages;
        }

        private string[] load_languages() {
            var result = new GenericArray<string>();
            Sqlite.Statement stmt;
            db.prepare_v2("SELECT code FROM languages", -1, out stmt);
            while (stmt.step() == Sqlite.ROW) {
                var lang = stmt.column_text(0);
                if (lang != null) result.add(lang);
            }
            return result.data;
        }

        private void apply_filter() {
            uint old_len = filtered_stations.length;
            filtered_stations = new GenericArray<Station>();
            if (db == null) {
                return;
            }

            // Build favourite ID list for SQL IN clause
            var fav_ids = AppState.get_default().get_favourite_ids();
            var fav_parts = new string[fav_ids.length];
            for (int i = 0; i < fav_ids.length; i++) {
                fav_parts[i] = fav_ids[i].to_string();
            }
            string fav_list = fav_ids.length > 0 ? string.joinv(",", fav_parts) : "0";

            // Tier sort: 1=favourite, 2=somafm, 3=image>=48px, 4=any image, 5=other
            var order_clause = "ORDER BY CASE"
                + " WHEN id IN (" + fav_list + ") THEN 1"
                + " WHEN source = " + SOURCE_SOMAFM.to_string() + " THEN 2"
                + " WHEN image_width >= 48 THEN 3"
                + " WHEN image_width > 0 THEN 4"
                + " ELSE 5 END, RANDOM()";

            var sql = new StringBuilder();
            bool use_fts = _search_query != "";

            if (use_fts) {
                sql.append("SELECT s.").append(COLS.replace(", ", ", s."));
                sql.append(" FROM stations s JOIN stations_fts f ON s.rowid = f.rowid WHERE stations_fts MATCH ?");
                if (_language_filter != "all") sql.append(" AND s.languages_raw LIKE ?");
            } else {
                sql.append("SELECT ").append(COLS).append(" FROM stations WHERE 1=1");
                if (_language_filter != "all") sql.append(" AND languages_raw LIKE ?");
            }

            sql.append(" ").append(order_clause);

            Sqlite.Statement stmt;
            if (db.prepare_v2(sql.str, -1, out stmt) != Sqlite.OK) {
                return;
            }

            int idx = 1;
            if (use_fts) {
                var parts = _search_query.strip().split(" ");
                var fts = new StringBuilder();
                foreach (var p in parts) {
                    if (p != "") {
                        if (fts.len > 0) {
                            fts.append(" ");
                        }
                        fts.append(p.replace("&", " ")).append("*");
                    }
                }
                stmt.bind_text(idx++, fts.str);
            }
            if (_language_filter != "all") {
                stmt.bind_text(idx++, "%" + _language_filter + "%");
            }

            while (stmt.step() == Sqlite.ROW) {
                filtered_stations.add(parse(stmt));
            }

            items_changed(0, old_len, filtered_stations.length);
        }


        private Station parse(Sqlite.Statement s) {
            var st = new Station();
            st.id = s.column_int64(0);
            st.source = s.column_int(1);
            st.name = s.column_text(2) ?? "";
            st.homepage = s.column_text(3);
            st.country = s.column_text(4);
            st.streams_raw = s.column_text(5);
            st.tags_raw = s.column_text(6);
            st.image_width = s.column_int(7);
            st.image_hash = s.column_int64(8);
            return st;
        }
    }
}
