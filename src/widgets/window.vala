// Main application window
namespace Receiver {

    public class MainWindow : Adw.ApplicationWindow {
        private Application app;
        private HomeScreen home_screen;
        private StationList station_list;
        private PlayerBar player_bar;
        private Adw.NavigationView nav_view;
        private Adw.NavigationPage search_page;
        private Adw.ToastOverlay toast_overlay;
        private Gtk.Button lastfm_btn;
        private uint auth_poll_timer = 0;

        public MainWindow(Application application) {
            Object(application: application, title: "Receiver", default_width: 580, default_height: 1000);
            this.app = application;
            build_ui();
            connect_signals();
        }

        private void build_ui() {
            var main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            toast_overlay = new Adw.ToastOverlay();
            nav_view = new Adw.NavigationView();

            // Home page
            home_screen = new HomeScreen(app.store);
            var home_content = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            var home_header = new Adw.HeaderBar();
            home_header.title_widget = new Gtk.Label("Receiver");
            var search_btn = new Gtk.Button.from_icon_name("system-search-symbolic");
            search_btn.tooltip_text = _("Search stations");
            search_btn.clicked.connect(() => {
                search_page.title = _("Search");
                nav_view.push(search_page);
            });

            // Last.fm button
            lastfm_btn = new Gtk.Button.with_label("Last.fm");
            lastfm_btn.add_css_class("flat");
            lastfm_btn.add_css_class("caption");
            update_lastfm_button();
            lastfm_btn.clicked.connect(on_lastfm_clicked);
            app.scrobbler.status_changed.connect(update_lastfm_button);

            home_header.pack_end(search_btn);
            home_header.pack_end(lastfm_btn);
            home_content.append(home_header);
            home_content.append(home_screen);
            var home_page = new Adw.NavigationPage(home_content, _("Home"));
            home_page.tag = "home";
            nav_view.add(home_page);

            station_list = new StationList(app.store);
            search_page = new Adw.NavigationPage(station_list, "Search");
            search_page.tag = "search";
            toast_overlay.child = nav_view;
            main_box.append(toast_overlay);

            player_bar = new PlayerBar(app.player);
            main_box.append(player_bar);
            this.content = main_box;
        }

        private void connect_signals() {
            home_screen.station_activated.connect(play_station);

            home_screen.genre_selected.connect((g) => {
                app.store.language_filter = "all";
                station_list.reset_language_filter();
                station_list.set_search_text(g);
                search_page.title = g.substring(0, 1).up() + g.substring(1);
                nav_view.push(search_page);
            });

            home_screen.view_all_clicked.connect(() => {
                station_list.set_search_text("");
                search_page.title = _("Search");
                nav_view.push(search_page);
            });

            station_list.station_activated.connect(play_station);

            app.store.loading_finished.connect((c) => {
                toast(_("Loaded %d stations").printf(c));
                restore_last();
            });

            app.store.loading_error.connect((m) => {
                toast(_("Error: %s").printf(m));
            });

            app.player.error_occurred.connect((m) => {
                toast(_("Playback error: %s").printf(m));
                message("Playback error: " + m);
            });
        }

        private void play_station(Station s) {
            app.player.play(s);
            AppState.get_default().settings.set_int64("last-station-id", s.id);
            toast(_("Now playing: %s").printf(s.name));
        }

        private void toast(string msg) {
            var t = new Adw.Toast(Markup.escape_text(msg));
            t.timeout = 3;
            toast_overlay.add_toast(t);
        }

        private void restore_last() {
            var id = AppState.get_default().settings.get_int64("last-station-id");
            if (id == 0) {
                return;
            }
            var s = app.store.get_station_by_id(id);
            if (s != null) {
                app.player.play(s);
                toast(_("Resuming: %s").printf(s.name));
            }
        }

        private void update_lastfm_button() {
            if (app.scrobbler.is_enabled()) {
                lastfm_btn.tooltip_text = _("Connected to Last.fm (click to disconnect)");
                lastfm_btn.add_css_class("success");
            } else {
                lastfm_btn.tooltip_text = _("Connect to Last.fm");
                lastfm_btn.remove_css_class("success");
            }
        }

        private void on_lastfm_clicked() {
            if (auth_poll_timer > 0) {
                // Polling in progress — cancel it
                cancel_auth_poll();
                toast(_("Last.fm authorization cancelled"));
                return;
            }

            if (app.scrobbler.is_enabled()) {
                // Already connected — disconnect
                app.scrobbler.disconnect_lastfm();
                toast(_("Disconnected from Last.fm"));
                return;
            }

            // Start auth flow
            toast(_("Connecting to Last.fm…"));
            app.scrobbler.start_auth.begin((obj, res) => {
                var url = app.scrobbler.start_auth.end(res);
                if (url == null) {
                    toast(_("Failed to connect to Last.fm"));
                    return;
                }

                // Open browser for authorization
                var launcher = new Gtk.UriLauncher(url);
                launcher.launch.begin(this, null);

                toast(_("Grant access in your browser…"));
                lastfm_btn.tooltip_text = _("Click to cancel Last.fm authorization");
                lastfm_btn.add_css_class("warning");

                // Poll every 3 seconds until auth succeeds or 2 minutes timeout
                var attempts = 0;
                auth_poll_timer = Timeout.add_seconds(3, () => {
                    attempts++;
                    if (attempts > 40) {  // 40 × 3s = 2 min timeout
                        cancel_auth_poll();
                        toast(_("Last.fm authorization timed out"));
                        return false;
                    }

                    app.scrobbler.complete_auth.begin((o, r) => {
                        var ok = app.scrobbler.complete_auth.end(r);
                        if (ok) {
                            cancel_auth_poll();
                            toast(_("Connected to Last.fm"));
                        }
                    });
                    return auth_poll_timer > 0;  // keep polling until cancelled
                });
            });
        }

        private void cancel_auth_poll() {
            if (auth_poll_timer > 0) {
                Source.remove(auth_poll_timer);
                auth_poll_timer = 0;
            }
            lastfm_btn.remove_css_class("warning");
            update_lastfm_button();
        }
    }
}
