// Main application window
namespace Receiver {
    private extern const string APP_VERSION;

    public class MainWindow : Adw.ApplicationWindow {
        private Application app;
        private HomeScreen home_screen;
        private StationList station_list;
        private PlayerBar player_bar;
        private Adw.NavigationView nav_view;
        private Adw.NavigationPage search_page;
        private Adw.ToastOverlay toast_overlay;
        private GLib.Menu lastfm_menu;
        private HistoryPage history_page;
        private Adw.NavigationPage history_nav_page;
        private uint auth_poll_timer = 0;

        public MainWindow(Application application) {
            var s = AppState.get_default().settings;
            Object(application: application, title: "Receiver",
                default_width: s.get_int("window-width"),
                default_height: s.get_int("window-height"));
            this.app = application;
            build_ui();
            connect_signals();

            this.close_request.connect(() => {
                s.set_int("window-width", this.default_width);
                s.set_int("window-height", this.default_height);
                return false;
            });
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

            // Hamburger menu
            var menu_button = new Gtk.MenuButton();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = _("Menu");
            menu_button.primary = true;
            var menu = new GLib.Menu();

            // Last.fm — dynamic label (needs its own GLib.Menu for updates)
            lastfm_menu = new GLib.Menu();
            update_lastfm_label();
            menu.append_section(null, lastfm_menu);
            app.scrobbler.status_changed.connect(update_lastfm_label);


            menu.append(_("Song History"), "win.history");
            menu.append(_("About Receiver"), "win.about");

            menu_button.menu_model = menu;

            // Last.fm indicator — visible only when connected
            var lastfm_btn = new Gtk.Button.with_label("Last.fm");
            lastfm_btn.add_css_class("flat");
            lastfm_btn.add_css_class("success");
            lastfm_btn.add_css_class("caption");
            lastfm_btn.visible = app.scrobbler.is_enabled();
            lastfm_btn.clicked.connect(() => {
                var username = AppState.get_default().settings.get_string("lastfm-username");
                var url = username != ""
                    ? "https://www.last.fm/user/" + username
                    : "https://www.last.fm";
                var launcher = new Gtk.UriLauncher(url);
                launcher.launch.begin(this, null);
            });
            app.scrobbler.status_changed.connect(() => {
                lastfm_btn.visible = app.scrobbler.is_enabled();
            });
            home_header.pack_end(menu_button);
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

            // History page
            history_page = new HistoryPage();
            history_nav_page = new Adw.NavigationPage(history_page, _("Song History"));
            history_nav_page.tag = "history";

            toast_overlay.child = nav_view;
            main_box.append(toast_overlay);

            // Window actions
            setup_win_actions();

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

            home_screen.local_selected.connect((country_name) => {
                station_list.set_search_text(country_name);
                search_page.title = country_name;
                nav_view.push(search_page);
            });

            home_screen.view_all_clicked.connect(() => {
                station_list.set_search_text("");
                search_page.title = _("Search");
                nav_view.push(search_page);
            });

            station_list.station_activated.connect(play_station);

            history_page.station_requested.connect((id) => {
                var s = app.store.get_station_by_id(id);
                if (s != null) {
                    play_station(s);
                }
            });

            app.store.loading_finished.connect((c) => {
                toast(_("Loaded %d stations").printf(c));
                restore_last();
            });

            app.store.loading_error.connect((m) => {
                toast(_("Error: %s").printf(m));
            });

            app.player.error_occurred.connect((m) => {
                toast(_("Playback error: %s").printf(m));
                warning("Playback error: " + m);
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

        private void setup_win_actions() {

            // Last.fm action
            var lastfm_action = new SimpleAction("lastfm-toggle", null);
            lastfm_action.activate.connect(on_lastfm_clicked);
            this.add_action(lastfm_action);

            // History action
            var history_action = new SimpleAction("history", null);
            history_action.activate.connect(() => {
                nav_view.push(history_nav_page);
            });
            this.add_action(history_action);

            // About action
            var about_action = new SimpleAction("about", null);
            about_action.activate.connect(show_about);
            this.add_action(about_action);
        }

        private void update_lastfm_label() {
            lastfm_menu.remove_all();
            if (auth_poll_timer > 0) {
                lastfm_menu.append(_("Cancel Last.fm Authorization"), "win.lastfm-toggle");
            } else if (app.scrobbler.is_enabled()) {
                lastfm_menu.append(_("Disconnect from Last.fm"), "win.lastfm-toggle");
            } else {
                lastfm_menu.append(_("Connect to Last.fm"), "win.lastfm-toggle");
            }
        }


        private void on_lastfm_clicked() {
            if (auth_poll_timer > 0) {
                cancel_auth_poll();
                toast(_("Last.fm authorization cancelled"));
                return;
            }

            if (app.scrobbler.is_enabled()) {
                app.scrobbler.disconnect_lastfm();
                toast(_("Disconnected from Last.fm"));
                return;
            }

            toast(_("Connecting to Last.fm…"));
            app.scrobbler.start_auth.begin((obj, res) => {
                var url = app.scrobbler.start_auth.end(res);
                if (url == null) {
                    toast(_("Failed to connect to Last.fm"));
                    return;
                }

                var launcher = new Gtk.UriLauncher(url);
                launcher.launch.begin(this, null);

                toast(_("Grant access in your browser…"));
                update_lastfm_label();

                var attempts = 0;
                auth_poll_timer = Timeout.add_seconds(3, () => {
                    attempts++;
                    if (attempts > 40) {
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
                    return auth_poll_timer > 0;
                });
            });
        }

        private void cancel_auth_poll() {
            if (auth_poll_timer > 0) {
                Source.remove(auth_poll_timer);
                auth_poll_timer = 0;
            }
            update_lastfm_label();
        }

        private void show_about() {
            var about = new Adw.AboutDialog();
            about.application_name = "Receiver";
            about.application_icon = "io.github.meehow.Receiver";
            about.version = APP_VERSION;
            about.comments = _("Discover 30,000+ verified radio stations from around the world");
            about.website = "https://github.com/meehow/receiver";
            about.issue_url = "https://github.com/meehow/receiver/issues";
            about.developer_name = "meehow";
            about.developers = {"meehow https://github.com/meehow"};
            about.copyright = "© 2026 meehow";
            about.license_type = Gtk.License.GPL_3_0;
            about.present(this);
        }
    }
}
