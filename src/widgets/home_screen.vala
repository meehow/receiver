// Home screen with favourites and genre browsing
namespace Receiver {

    public class HomeScreen : Gtk.Box {
        private StationStore store;
        private Gtk.Box? favourites_section;
        private Gtk.FlowBox? favourites_flow;
        private Gtk.FlowBox? genres_flow;

        public signal void station_activated(Station station);
        public signal void genre_selected(string genre);
        public signal void local_selected(string country_name);
        public signal void view_all_clicked();

        private const string[] GENRES = {
            "pop", "kpop", "rock", "jazz", "classical", "electronic", "dance",
            "hits", "70s", "80s", "90s", "oldies", "chill",
            "news", "talk", "sports",
            "alternative", "indie", "metal", "punk",
            "house", "hiphop", "latin", "soul", "blues", "folk",
            "country", "reggae", "disco"
        };

        public HomeScreen(StationStore station_store) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.store = station_store;
            build_ui();
            store.favourites_changed.connect(update_favourites);
            store.loading_finished.connect(() => {
                update_favourites();
                add_local_pill();
            });
        }

        private void build_ui() {
            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 24);
            content.margin_start = content.margin_end = content.margin_top = content.margin_bottom = 16;

            build_favourites(content);
            build_genres(content);

            scrolled.child = content;
            this.append(scrolled);
        }

        private void build_favourites(Gtk.Box parent) {
            favourites_section = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            var header = new Gtk.Label(_("Favourite Stations"));
            header.xalign = 0;
            header.add_css_class("title-2");
            favourites_section.append(header);

            favourites_flow = new Gtk.FlowBox();
            favourites_flow.selection_mode = Gtk.SelectionMode.NONE;
            favourites_flow.homogeneous = true;
            favourites_flow.max_children_per_line = 4;
            favourites_flow.min_children_per_line = 2;
            favourites_flow.row_spacing = favourites_flow.column_spacing = 8;
            favourites_section.append(favourites_flow);
            parent.append(favourites_section);
            favourites_section.visible = false;
        }

        private void update_favourites() {
            if (favourites_flow == null) {
                return;
            }
            Gtk.Widget? child;
            while ((child = favourites_flow.get_first_child()) != null) {
                favourites_flow.remove(child);
            }
            var favs = store.get_favourite_stations();
            favourites_section.visible = favs.length > 0;
            for (int i = 0; i < favs.length; i++) {
                favourites_flow.append(create_fav_card(favs[i]));
            }
        }

        private Gtk.Widget create_fav_card(Station s) {
            var card = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            card.add_css_class("card");
            card.set_size_request(180, 60);

            var stack = new Gtk.Stack();
            var ph = new Gtk.Image.from_icon_name("audio-x-generic-symbolic");
            ph.set_size_request(48, 48);
            ph.pixel_size = 32;
            ph.add_css_class("dim-label");
            stack.add_named(ph, "placeholder");
            var art = new Gtk.Picture();
            art.set_size_request(48, 48);
            art.content_fit = Gtk.ContentFit.COVER;
            var frame = new Gtk.Frame(null);
            frame.child = art;
            frame.add_css_class("circular");
            frame.overflow = Gtk.Overflow.HIDDEN;
            frame.set_size_request(48, 48);
            stack.add_named(frame, "artwork");
            card.append(stack);

            var text = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text.valign = Gtk.Align.CENTER;
            text.hexpand = true;
            var title = new Gtk.Label(s.name);
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class("heading");
            text.append(title);
            var subtitle = s.get_subtitle();
            if (subtitle != "") {
                var sub = new Gtk.Label(subtitle);
                sub.xalign = 0;
                sub.ellipsize = Pango.EllipsizeMode.END;
                sub.add_css_class("dim-label");
                sub.add_css_class("caption");
                text.append(sub);
            }
            card.append(text);

            load_artwork.begin(s, art, stack);
            var g = new Gtk.GestureClick();
            g.released.connect(() => {
                station_activated(s);
            });
            card.add_controller(g);
            return card;
        }



        private async void load_artwork(Station s, Gtk.Picture art, Gtk.Stack stack) {
            var tex = yield ImageLoader.get_default().load(s.image_hash);
            if (tex != null) {
                art.paintable = tex;
                stack.visible_child_name = "artwork";
            }
        }

        private void build_genres(Gtk.Box parent) {
            var section = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            var hdr = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            var lbl = new Gtk.Label(_("Discover"));
            lbl.xalign = 0;
            lbl.hexpand = true;
            lbl.add_css_class("title-2");
            hdr.append(lbl);
            var btn = new Gtk.Button.with_label(_("View All"));
            btn.add_css_class("flat");
            btn.clicked.connect(() => {
                view_all_clicked();
            });
            hdr.append(btn);
            section.append(hdr);

            genres_flow = new Gtk.FlowBox();
            var flow = genres_flow;
            flow.selection_mode = Gtk.SelectionMode.NONE;
            flow.homogeneous = true;
            flow.max_children_per_line = 6;
            flow.min_children_per_line = 2;
            flow.row_spacing = flow.column_spacing = 8;

            foreach (var g in GENRES) {
                var tile = new Gtk.Button();
                tile.add_css_class("pill");
                tile.add_css_class("suggested-action");
                tile.set_size_request(80, 40);
                tile.child = new Gtk.Label(g.substring(0, 1).up() + g.substring(1));
                tile.clicked.connect(() => {
                    genre_selected(g);
                });
                flow.append(tile);
            }
            section.append(flow);
            parent.append(section);
        }

        private void add_local_pill() {
            if (genres_flow == null) return;
            var country_name = store.get_locale_country_name();
            if (country_name == null) return;
            var local_tile = new Gtk.Button();
            local_tile.add_css_class("pill");
            local_tile.add_css_class("suggested-action");
            local_tile.set_size_request(80, 40);
            local_tile.child = new Gtk.Label(country_name);
            local_tile.clicked.connect(() => {
                local_selected(country_name);
            });
            genres_flow.insert(local_tile, 0);
        }
    }
}
