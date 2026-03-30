// Main application window
namespace Receiver {
    private extern const string APP_VERSION;

    public class MainWindow : Adw.ApplicationWindow {
        private Application app;
        private StationList station_list;
        private FavouritesPage favourites_page;
        private PlayerBar player_bar;
        private Adw.NavigationView nav_view;
        private Adw.ViewStack view_stack;
        private Adw.ToastOverlay toast_overlay;
        private GLib.Menu lastfm_menu;
        private HistoryPage history_page;
        private Adw.NavigationPage history_nav_page;
        private StationInfoPage station_info_page;
        private Adw.NavigationPage station_info_nav_page;
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

            // Root page with ViewStack
            var root_content = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);

            // Header bar
            var header = new Adw.HeaderBar();

            // ViewSwitcherTitle — shows tabs in header on wide windows
            var switcher_title = new Adw.ViewSwitcherTitle();
            header.title_widget = switcher_title;

            // Hamburger menu
            var menu_button = new Gtk.MenuButton();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = _("Menu");
            menu_button.primary = true;
            var menu = new GLib.Menu();

            // Last.fm — dynamic label
            lastfm_menu = new GLib.Menu();
            update_lastfm_label();
            menu.append_section(null, lastfm_menu);
            app.scrobbler.status_changed.connect(update_lastfm_label);

            menu.append(_("Song History"), "win.history");
            menu.append(_("About Receiver"), "win.about");

            menu_button.menu_model = menu;

            // Last.fm indicator
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

            header.pack_end(menu_button);
            header.pack_end(lastfm_btn);
            root_content.append(header);

            // ViewStack with Browse and Favourites tabs
            view_stack = new Adw.ViewStack();

            station_list = new StationList(app.store);
            view_stack.add_titled(station_list, "browse", _("Browse"))
                .icon_name = "audio-x-generic-symbolic";

            favourites_page = new FavouritesPage(app.store);
            view_stack.add_titled(favourites_page, "favourites", _("Favourites"))
                .icon_name = "starred-symbolic";

            switcher_title.stack = view_stack;

            root_content.append(view_stack);

            // ViewSwitcherBar — shows tabs at bottom on narrow windows
            var switcher_bar = new Adw.ViewSwitcherBar();
            switcher_bar.stack = view_stack;
            switcher_title.notify["title-visible"].connect(() => {
                switcher_bar.reveal = switcher_title.title_visible;
            });
            root_content.append(switcher_bar);

            var root_page = new Adw.NavigationPage(root_content, "Receiver");
            root_page.tag = "home";
            nav_view.add(root_page);

            // History page (pushed on demand)
            history_page = new HistoryPage();
            history_nav_page = new Adw.NavigationPage(history_page, _("Song History"));
            history_nav_page.tag = "history";

            // Station info page (pushed on demand)
            station_info_page = new StationInfoPage(app.player);
            station_info_nav_page = new Adw.NavigationPage(station_info_page, _("Station Info"));
            station_info_nav_page.tag = "station-info";

            toast_overlay.child = nav_view;
            main_box.append(toast_overlay);

            // Window actions
            setup_win_actions();

            player_bar = new PlayerBar(app.player);
            main_box.append(player_bar);
            this.content = main_box;
        }

        private void connect_signals() {
            station_list.station_activated.connect(play_station);
            favourites_page.station_activated.connect(play_station);

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

            player_bar.info_requested.connect(() => {
                station_info_page.refresh();
                nav_view.push(station_info_nav_page);
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
