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
            home_header.pack_end(search_btn);
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
    }
}
