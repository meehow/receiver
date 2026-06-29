// Main application class
namespace Receiver {

    public class Application : Adw.Application, MprisHost {
        public StationStore store { get; private set; }
        public Player player { get; private set; }
        public Scrobbler scrobbler { get; private set; }
        private MprisService mpris;

        public Application() {
            Object(
                application_id: "io.github.meehow.Receiver",
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
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
            Gtk.Window? win = active_window;
            if (win == null) {
                unowned List<Gtk.Window> wins = get_windows();
                if (wins != null) {
                    win = wins.data;
                }
            }
            if (win == null) {
                win = new MainWindow(this);
                open_database();
            }
            win.set_visible(true);
            win.present();
        }

        // Called by the window when it hides itself instead of quitting.
        // Tells the desktop we intend to keep running and lets the user know.
        public void enter_background() {
            request_background_portal();

            var n = new GLib.Notification(_("Receiver is playing in the background"));
            n.set_body(_("Use the system media controls or Stop to exit."));
            send_notification("background-playback", n);
        }

        // Best-effort Background portal request over D-Bus (no libportal needed,
        // and a no-op when no portal is running, e.g. outside Flatpak).
        private void request_background_portal() {
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

        private void open_database() {
            // Search XDG data dirs (/usr/share, /app/share, dev via make run)
            foreach (var data_dir in Environment.get_system_data_dirs()) {
                var path = Path.build_filename(data_dir, "receiver", "receiver.db");
                if (FileUtils.test(path, FileTest.EXISTS)) {
                    store.open(path);
                    message("Loaded %d stations from %s", store.total_count, path);
                    return;
                }
            }

            warning("Database not found");
        }
    }
}
