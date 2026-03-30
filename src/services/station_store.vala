// Station store - SQLite-backed station data
namespace Receiver {

    public class StationStore : Object, ListModel {
        private Sqlite.Database? db;
        private GenericArray<Station> filtered_stations;
        private string _search_query = "";
        private string _language_filter = "";
        private string _country_filter = "";
        private string[] _available_languages;
        private string[] _available_country_codes;
        private string[] _available_country_names;
        private HashTable<int64?, bool> failed_stations;

        private const string COLS = "id, source, name, homepage, country, streams_raw, tags_raw, image_hash";

        public string search_query {
            get { return _search_query; }
            set {
                if (_search_query != value) {
                    _search_query = value;
                    apply_filter();
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

        public string country_filter {
            get { return _country_filter; }
            set {
                if (_country_filter != value) {
                    _country_filter = value;
                    apply_filter();
                    notify_property("country-filter");
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
            _available_country_codes = {};
            _available_country_names = {};
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
            load_countries();

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


        private void detect_locale(out string? country, out string? language) {
            country = null;
            language = null;
            // Cascade through locale variables in gettext priority order
            string? locale = null;
            foreach (var key in new string[] {"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) {
                var val = Environment.get_variable(key);
                if (val == null || val == "" || val == "C" || val == "POSIX") continue;
                // LANGUAGE can be colon-separated (e.g. "de_CH:de:en"); use first entry
                locale = val.split(":")[0];
                break;
            }
            if (locale == null) return;
            // Strip encoding suffix (e.g. ".UTF-8")
            locale = locale.split(".")[0];
            int sep = locale.index_of_char('_');
            if (sep < 2 || locale.length < sep + 3) return;
            language = locale.substring(0, sep).down();  // "de" stays "de"
            country = locale.substring(sep + 1, 2);      // "CH" from de_CH
        }




        public string? get_locale_country_name() {
            string? code;
            string? lang;
            detect_locale(out code, out lang);
            if (code == null || db == null) return null;
            Sqlite.Statement stmt;
            db.prepare_v2("SELECT DISTINCT country FROM stations WHERE country_code = ?", -1, out stmt);
            stmt.bind_text(1, code);
            if (stmt.step() == Sqlite.ROW) {
                return stmt.column_text(0);
            }
            return null;
        }

        public string[] get_available_languages() {
            return _available_languages;
        }

        public string[] get_available_country_codes() {
            return _available_country_codes;
        }

        public string[] get_available_country_names() {
            return _available_country_names;
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

        private void load_countries() {
            var codes = new GenericArray<string>();
            var names = new GenericArray<string>();
            Sqlite.Statement stmt;
            db.prepare_v2(
                "SELECT DISTINCT country_code, country FROM stations " +
                "WHERE country_code IS NOT NULL AND country_code != '' " +
                "AND country IS NOT NULL AND country != '' " +
                "ORDER BY country", -1, out stmt);
            while (stmt.step() == Sqlite.ROW) {
                var code = stmt.column_text(0);
                var name = stmt.column_text(1);
                if (code != null && name != null) {
                    codes.add(code);
                    names.add(name);
                }
            }
            _available_country_codes = codes.data;
            _available_country_names = names.data;
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

            // Tier sort: 1=favourite, 2=somafm, 3=has image, 4=other
            var order_clause = "ORDER BY CASE"
                + " WHEN id IN (" + fav_list + ") THEN 1"
                + " WHEN source = " + SOURCE_SOMAFM.to_string() + " THEN 2"
                + " WHEN image_hash != 0 THEN 3"
                + " ELSE 4 END, RANDOM()";

            var sql = new StringBuilder();
            bool use_fts = _search_query != "";

            var prefix = use_fts ? "s." : "";
            if (use_fts) {
                sql.append("SELECT s.").append(COLS.replace(", ", ", s."));
                sql.append(" FROM stations s JOIN stations_fts f ON s.rowid = f.rowid WHERE stations_fts MATCH ?");
            } else {
                sql.append("SELECT ").append(COLS).append(" FROM stations WHERE 1=1");
            }
            if (_language_filter != "all") sql.append(" AND " + prefix + "languages_raw LIKE ?");
            if (_country_filter != "all") sql.append(" AND " + prefix + "country_code = ?");

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
            if (_country_filter != "all") {
                stmt.bind_text(idx++, _country_filter);
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
            st.image_hash = s.column_int64(7);
            return st;
        }
    }
}
