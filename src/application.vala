// Main application class
namespace Receiver {

    public class Application : Adw.Application {
        public StationStore store { get; private set; }
        public Player player { get; private set; }
        private MprisService mpris;

        public Application() {
            Object(
                application_id: "io.github.meehow.Receiver",
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        protected override void startup() {
            base.startup();

            // Initialize services
            store = new StationStore();
            player = new Player();
            mpris = new MprisService(this, player);

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

            // Set up actions
            setup_actions();
        }

        protected override void activate() {
            var window = this.active_window;
            if (window == null) {
                window = new MainWindow(this);
            }
            window.present();

            // Open database after window is shown
            open_database();
        }


        private void setup_actions() {
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
