// Persistent application state
// Scalar settings use GSettings; favourites use JSON file
namespace Receiver {

    public class AppState : Object {
        private static AppState? _instance;
        public Settings settings { get; private set; }
        private string favourites_file;
        private bool save_pending = false;
        private GenericArray<Station> _favourite_stations;

        public signal void favourites_changed();

        public static AppState get_default() {
            if (_instance == null) {
                _instance = new AppState();
            }
            return _instance;
        }

        private AppState() {
            settings = new Settings("io.github.meehow.Receiver");

            var app_dir = Path.build_filename(Environment.get_user_config_dir(), "receiver");
            try {
                var dir = File.new_for_path(app_dir);
                if (!dir.query_exists()) {
                    dir.make_directory_with_parents();
                }
            } catch (Error e) {}

            favourites_file = Path.build_filename(app_dir, "favourites.json");
            _favourite_stations = new GenericArray<Station>();
            load_favourites();
        }

        public bool is_favourite(int64 id) {
            for (int i = 0; i < _favourite_stations.length; i++) {
                if (_favourite_stations[i].id == id) {
                    return true;
                }
            }
            return false;
        }


        public void toggle_favourite(Station station) {
            if (is_favourite(station.id)) {
                for (int i = 0; i < _favourite_stations.length; i++) {
                    if (_favourite_stations[i].id == station.id) {
                        _favourite_stations.remove_index(i);
                        break;
                    }
                }
            } else {
                _favourite_stations.add(station);
            }
            favourites_changed();
            save_favourites();
        }

        public int64[] get_favourite_ids() {
            var ids = new int64[_favourite_stations.length];
            for (int i = 0; i < _favourite_stations.length; i++) {
                ids[i] = _favourite_stations[i].id;
            }
            return ids;
        }

        public GenericArray<Station> get_favourite_stations() {
            return _favourite_stations;
        }

        // --- Favourites persistence (JSON) ---

        private void load_favourites() {
            var file = File.new_for_path(favourites_file);
            if (!file.query_exists()) return;

            try {
                uint8[] contents;
                file.load_contents(null, out contents, null);
                var parser = new Json.Parser();
                parser.load_from_data((string) contents);

                var arr = parser.get_root()?.get_array();
                if (arr == null) return;

                for (uint i = 0; i < arr.get_length(); i++) {
                    var node = arr.get_element(i);
                    if (node.get_node_type() == Json.NodeType.OBJECT) {
                        var station = (Station) Json.gobject_deserialize(typeof(Station), node);
                        if (station != null && station.id != 0) {
                            _favourite_stations.add(station);
                        }
                    }
                }

                message("Loaded %d favourites", _favourite_stations.length);
            } catch (Error e) {
                warning("Failed to load favourites: %s", e.message);
            }
        }


        public void save_favourites() {
            if (save_pending) return;
            save_pending = true;
            Timeout.add(500, () => {
                do_save_favourites.begin();
                save_pending = false;
                return false;
            });
        }

        public void flush() {
            if (save_pending) {
                do_save_favourites.begin();
                save_pending = false;
            }
        }

        private async void do_save_favourites() {
            try {
                var b = new Json.Builder();
                b.begin_array();
                for (int i = 0; i < _favourite_stations.length; i++) {
                    b.add_value(Json.gobject_serialize(_favourite_stations[i]));
                }
                b.end_array();

                var gen = new Json.Generator();
                gen.set_root(b.get_root());
                gen.pretty = true;

                yield File.new_for_path(favourites_file).replace_contents_async(
                    gen.to_data(null).data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                warning("Failed to save favourites: %s", e.message);
            }
        }
    }
}
