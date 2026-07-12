// Main application class
namespace Receiver {

    public class Application : Adw.Application, MprisHost {
        public StationStore store { get; private set; }
        public Player player { get; private set; }
        public Scrobbler scrobbler { get; private set; }
        private MprisService mpris;
        private SearchProvider search_provider;
        private uint search_provider_reg = 0;

        public Application() {
            Object(
                application_id: "io.github.meehow.Receiver",
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        // Register the GNOME Shell search provider on the session bus alongside
        // the app's own object. The Shell finds it via the .ini in data/ and
        // can D-Bus-activate the app to answer queries without a window.
        public override bool dbus_register(DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register(connection, object_path)) {
                return false;
            }
            search_provider = new SearchProvider(this);
            search_provider_reg = connection.register_object(
                object_path + "/SearchProvider", search_provider);
            return true;
        }

        public override void dbus_unregister(DBusConnection connection, string object_path) {
            if (search_provider_reg != 0) {
                connection.unregister_object(search_provider_reg);
                search_provider_reg = 0;
            }
            base.dbus_unregister(connection, object_path);
        }

        // MprisHost
        public void raise() {
            present_main_window();
        }

        // Bring the main window to the front, re-showing it if it was hidden by
        // background mode. active_window is null while the only window is hidden,
        // so look through the full window list (which still includes it) and only
        // build a fresh window when there genuinely isn't one.
        private void present_main_window() {
            var win = ensure_main_window();
            win.set_visible(true);
            win.present();
        }

        // Return the main window, creating it (and loading the browse list) if
        // there is not one yet.
        private MainWindow ensure_main_window() {
            Gtk.Window? win = active_window;
            if (win == null) {
                unowned List<Gtk.Window> wins = get_windows();
                if (wins != null) {
                    win = wins.data;
                }
            }
            if (win == null) {
                var created = new MainWindow(this);
                open_database();
                return created;
            }
            return (MainWindow) win;
        }

        // Best-effort Background portal request over D-Bus (no libportal needed,
        // and a no-op when no portal is running, e.g. outside Flatpak). Called by
        // the window when it hides itself instead of quitting, so the desktop
        // knows we intend to keep running (surfaced via the Background Apps menu).
        public void request_background_portal() {
            try {
                var conn = Bus.get_sync(BusType.SESSION);
                var options = new VariantBuilder(new VariantType("a{sv}"));
                options.add("{sv}", "reason", new Variant.string(
                    _("Receiver keeps playing radio after the window is closed")));
                options.add("{sv}", "autostart", new Variant.boolean(false));
                conn.call.begin(
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.Background",
                    "RequestBackground",
                    new Variant("(sa{sv})", "", options),
                    new VariantType("(o)"),
                    DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                debug("Background portal unavailable: %s", e.message);
            }
        }

        protected override void startup() {
            base.startup();

            // Strip flat-button padding so the station title in the player
            // bar lines up with the subtitle below it
            var css = new Gtk.CssProvider();
            css.load_from_data("button.title-link { padding-left: 0; padding-right: 0; min-height: 0; }".data);
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            // Initialize services
            store = new StationStore();
            player = new Player();
            mpris = new MprisService(this, player);
            scrobbler = new Scrobbler(player);

            // Restore saved state and bind volume
            var state = AppState.get_default();
            state.settings.bind("volume", player, "volume", SettingsBindFlags.DEFAULT);
            
            // Mark stations as failed when stream errors occur
            player.error_occurred.connect((msg) => {
                if (player.current_station != null) {
                    store.mark_station_failed(player.current_station.id);
                }
            });
            
            // Clear failed status when stream plays successfully
            player.state_changed.connect((new_state) => {
                if (new_state == PlayerState.PLAYING && player.current_station != null) {
                    store.clear_station_failed(player.current_station.id);
                }
            });

            // When running in the background (window hidden), Stop means "done":
            // tear the process down. Pause keeps it alive.
            player.state_changed.connect((new_state) => {
                var win = active_window;
                if (new_state == PlayerState.STOPPED && win != null && !win.visible) {
                    this.quit();
                }
            });

            // Record songs to history
            player.metadata_changed.connect((title) => {
                if (player.current_station != null && player.state == PlayerState.PLAYING) {
                    HistoryStore.get_default().add(player.current_station, title);
                }
            });

            // Set up actions
            setup_actions();
        }

        protected override void activate() {
            present_main_window();
        }


        private void setup_actions() {
            // Run-in-background toggle (stateful, backed by GSettings)
            var bg_action = AppState.get_default().settings.create_action("run-in-background");
            this.add_action(bg_action);

            // Quit action
            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => {
                player.stop();
                this.quit();
            });
            this.add_action(quit_action);
            this.set_accels_for_action("app.quit", {"<Ctrl>q"});

            // Play/Pause action (no shortcut - spacebar conflicts with search entry)
            var play_action = new SimpleAction("play-pause", null);
            play_action.activate.connect(() => {
                player.toggle_pause();
            });
            this.add_action(play_action);
            // Use media key or Ctrl+Space instead of bare space
            this.set_accels_for_action("app.play-pause", {"<Ctrl>space", "AudioPlay"});

            // Stop action - explicitly clears last station
            var stop_action = new SimpleAction("stop", null);
            stop_action.activate.connect(() => {
                AppState.get_default().settings.set_int64("last-station-id", 0);
                player.stop();
            });
            this.add_action(stop_action);
        }

        // Search XDG data dirs (/usr/share, /app/share, dev via make run)
        private string? find_db_path() {
            foreach (var data_dir in Environment.get_system_data_dirs()) {
                var path = Path.build_filename(data_dir, "receiver", "receiver.db");
                if (FileUtils.test(path, FileTest.EXISTS)) {
                    return path;
                }
            }
            return null;
        }

        private void open_database() {
            var path = find_db_path();
            if (path == null) {
                warning("Database not found");
                return;
            }
            store.open(path);
            message("Loaded %d stations from %s", store.total_count, path);
        }

        // Open just the SQLite connection so the search provider can answer
        // queries when the app was D-Bus-activated without a window.
        private void ensure_db() {
            if (store.db_ready) {
                return;
            }
            var path = find_db_path();
            if (path != null) {
                store.open_connection(path);
            } else {
                warning("Database not found");
            }
        }

        // ---- GNOME Shell search provider backends (called from SearchProvider) ----

        public string[] search_station_ids(string query) {
            ensure_db();
            var found = store.search_stations(query, 20);
            var ids = new string[found.length];
            for (int i = 0; i < found.length; i++) {
                ids[i] = found.get(i).id.to_string();
            }
            return ids;
        }

        public HashTable<string, Variant>[] search_result_metas(string[] identifiers) {
            ensure_db();
            HashTable<string, Variant>[] metas = {};
            foreach (var idstr in identifiers) {
                var station = store.get_station_by_id(int64.parse(idstr));
                if (station == null) {
                    continue;
                }
                var meta = new HashTable<string, Variant>(str_hash, str_equal);
                meta.insert("id", new Variant.string(idstr));
                meta.insert("name", new Variant.string(station.name));
                var subtitle = station.get_subtitle();
                if (subtitle != "") {
                    meta.insert("description", new Variant.string(subtitle));
                }
                metas += meta;
            }
            return metas;
        }

        public void play_station_id(string identifier) {
            ensure_db();
            var station = store.get_station_by_id(int64.parse(identifier));
            if (station != null) {
                // Set before creating the window so its restore-last logic
                // resumes this station rather than the previous one.
                AppState.get_default().settings.set_int64("last-station-id", station.id);
            }
            present_main_window();
            if (station != null &&
                    (player.current_station == null || player.current_station.id != station.id)) {
                player.play(station);
            }
        }

        public void open_with_search(string query) {
            var win = ensure_main_window();
            win.set_visible(true);
            win.present();
            win.show_search(query);
        }
    }
}
