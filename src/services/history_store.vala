// Song history — persists recently played songs as JSON
namespace Receiver {

    public class HistoryEntry : Object {
        public int64 station_id { get; set; }
        public string station_name { get; set; default = ""; }
        public string song_title { get; set; default = ""; }
        public string played_at { get; set; default = ""; }
    }

    public class HistoryStore : Object, ListModel {
        private static HistoryStore? _instance;
        private GenericArray<HistoryEntry> entries;
        private string file_path;
        private bool save_pending = false;
        private const int MAX_ENTRIES = 500;

        public static HistoryStore get_default() {
            if (_instance == null) {
                _instance = new HistoryStore();
            }
            return _instance;
        }

        // ListModel interface
        public Object? get_item(uint pos) {
            return pos < entries.length ? entries[(int)pos] : null;
        }
        public Type get_item_type() {
            return typeof(HistoryEntry);
        }
        public uint get_n_items() {
            return entries.length;
        }

        private HistoryStore() {
            entries = new GenericArray<HistoryEntry>();
            var app_dir = Path.build_filename(Environment.get_user_config_dir(), "receiver");
            try {
                var dir = File.new_for_path(app_dir);
                if (!dir.query_exists()) {
                    dir.make_directory_with_parents();
                }
            } catch (Error e) {}
            file_path = Path.build_filename(app_dir, "history.json");
            load();
        }

        public void add(Station station, string song_title) {
            // Skip if not a song (must contain separator)
            if (!MetadataExtractor.get_default().extract_artist_title(song_title).is_song()) return;

            // Deduplicate: skip if last entry is same station + song
            if (entries.length > 0) {
                var last = entries[0];
                if (last.station_id == station.id && last.song_title == song_title) return;
            }

            var entry = new HistoryEntry();
            entry.station_id = station.id;
            entry.station_name = station.name;
            entry.song_title = song_title;
            entry.played_at = new DateTime.now_local().format_iso8601();
            entries.insert(0, entry);

            // Cap size + notify removals from the end
            uint removed = 0;
            while (entries.length > MAX_ENTRIES) {
                entries.remove_index(entries.length - 1);
                removed++;
            }

            // Notify: 1 item added at position 0
            items_changed(0, 0, 1);
            // Notify any trimmed items from the tail
            if (removed > 0) {
                items_changed(entries.length, removed, 0);
            }

            schedule_save();
        }

        public void clear() {
            uint old_len = entries.length;
            entries = new GenericArray<HistoryEntry>();
            items_changed(0, old_len, 0);
            schedule_save();
        }


        // --- JSON persistence ---

        private void load() {
            var file = File.new_for_path(file_path);
            if (!file.query_exists()) return;

            try {
                uint8[] contents;
                file.load_contents(null, out contents, null);
                var parser = new Json.Parser();
                parser.load_from_data((string) contents);

                var arr = parser.get_root()?.get_array();
                if (arr == null) return;

                for (uint i = 0; i < arr.get_length(); i++) {
                    var obj = arr.get_element(i).get_object();
                    if (obj == null) continue;
                    var e = new HistoryEntry();
                    e.station_id = obj.has_member("station_id") ? obj.get_int_member("station_id") : 0;
                    e.station_name = obj.has_member("station_name") ? obj.get_string_member("station_name") : "";
                    e.song_title = obj.has_member("song_title") ? obj.get_string_member("song_title") : "";
                    e.played_at = obj.has_member("played_at") ? obj.get_string_member("played_at") : "";
                    if (e.station_id != 0 && e.song_title != "") {
                        entries.add(e);
                    }
                }
                message("Loaded %d history entries", entries.length);
            } catch (Error e) {
                warning("Failed to load history: %s", e.message);
            }
        }

        private void schedule_save() {
            if (save_pending) return;
            save_pending = true;
            Timeout.add(1000, () => {
                do_save.begin();
                save_pending = false;
                return false;
            });
        }

        private async void do_save() {
            try {
                var b = new Json.Builder();
                b.begin_array();
                for (int i = 0; i < entries.length; i++) {
                    var e = entries[i];
                    b.begin_object();
                    b.set_member_name("station_id"); b.add_int_value(e.station_id);
                    b.set_member_name("station_name"); b.add_string_value(e.station_name);
                    b.set_member_name("song_title"); b.add_string_value(e.song_title);
                    b.set_member_name("played_at"); b.add_string_value(e.played_at);
                    b.end_object();
                }
                b.end_array();

                var gen = new Json.Generator();
                gen.set_root(b.get_root());
                gen.pretty = true;

                yield File.new_for_path(file_path).replace_contents_async(
                    gen.to_data(null).data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                warning("Failed to save history: %s", e.message);
            }
        }
    }
}
