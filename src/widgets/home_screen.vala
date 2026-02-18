// Home screen with featured stations and genre browsing
namespace Receiver {

    public class HomeScreen : Gtk.Box {
        private StationStore store;
        private Adw.Carousel featured_carousel;
        private Gtk.Box? favourites_section;
        private Gtk.FlowBox? favourites_flow;
        private const int FEATURED_LIMIT = 30;


        public signal void station_activated(Station station);
        public signal void genre_selected(string genre);
        public signal void view_all_clicked();

        private const string[] GENRES = {"pop", "rock", "jazz", "classical", "80s", "dance", "news", "oldies", "hits", "talk", "chill", "electronic"};

        public HomeScreen(StationStore station_store) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.store = station_store;
            build_ui();
            store.favourites_changed.connect(update_favourites);
        }

        private void build_ui() {
            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 24);
            content.margin_start = content.margin_end = content.margin_top = content.margin_bottom = 16;

            build_featured(content);
            build_favourites(content);
            build_genres(content);

            scrolled.child = content;
            this.append(scrolled);
        }

        private void build_featured(Gtk.Box parent) {
            var section = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            var header = new Gtk.Label(_("Featured Stations"));
            header.xalign = 0;
            header.add_css_class("title-2");
            section.append(header);

            featured_carousel = new Adw.Carousel();
            featured_carousel.interactive = true;
            featured_carousel.spacing = 12;
            featured_carousel.vexpand = false;
            featured_carousel.set_size_request(-1, 200);

            // Capture mouse wheel so it moves the carousel without scrolling the page
            var scroll_ctl = new Gtk.EventControllerScroll(
                Gtk.EventControllerScrollFlags.VERTICAL |
                Gtk.EventControllerScrollFlags.DISCRETE
            );
            scroll_ctl.scroll.connect((dx, dy) => {
                if (featured_carousel.n_pages < 2) {
                    return false;
                }
                uint current = (uint) (featured_carousel.position + 0.5);
                if (dy > 0 && current < featured_carousel.n_pages - 1) {
                    featured_carousel.scroll_to(featured_carousel.get_nth_page(current + 1), true);
                    return true;
                } else if (dy < 0 && current > 0) {
                    featured_carousel.scroll_to(featured_carousel.get_nth_page(current - 1), true);
                    return true;
                }
                return false;  // at boundary, let page scroll
            });
            featured_carousel.add_controller(scroll_ctl);

            var dots = new Adw.CarouselIndicatorDots();
            dots.carousel = featured_carousel;
            dots.halign = Gtk.Align.CENTER;
            dots.margin_top = 8;

            section.append(featured_carousel);
            section.append(dots);
            parent.append(section);

            store.loading_finished.connect((c) => {
                load_featured.begin();
                update_favourites();
            });
        }

        private async void load_featured() {
            var stations = store.get_local_stations(FEATURED_LIMIT);
            for (int i = 0; i < stations.length; i++) {
                load_featured_artwork.begin(stations[i]);
            }
        }

        private async void load_featured_artwork(Station station) {
            var tex = yield ImageLoader.get_default().load(station.image_hash);
            if (tex == null) return;
            featured_carousel.append(create_featured_card_with_texture(station, tex));
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

        private Gtk.Widget create_featured_card_with_texture(Station s, Gdk.Texture tex) {
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("card");
            card.set_size_request(200, 200);
            card.halign = Gtk.Align.CENTER;
            card.valign = Gtk.Align.CENTER;
            card.overflow = Gtk.Overflow.HIDDEN;

            var overlay = new Gtk.Overlay();

            var art = new Gtk.Picture();
            art.paintable = tex;
            art.content_fit = Gtk.ContentFit.COVER;
            overlay.child = art;

            var bg = new Gtk.DrawingArea();
            bg.set_size_request(-1, 60);
            bg.valign = Gtk.Align.END;
            bg.set_draw_func((a, cr, w, h) => {
                var grad = new Cairo.Pattern.linear(0, 0, 0, h);
                grad.add_color_stop_rgba(0, 0, 0, 0, 0.4);
                grad.add_color_stop_rgba(1, 0, 0, 0, 0.9);
                cr.set_source(grad);
                cr.rectangle(0, 0, w, h);
                cr.fill();
            });
            overlay.add_overlay(bg);

            var text = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text.valign = Gtk.Align.END;
            text.margin_start = text.margin_end = text.margin_bottom = 10;
            var title = new Gtk.Label(s.name);
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class("title-4");
            title.add_css_class("white-text");
            text.append(title);
            var subtitle = s.get_subtitle();
            if (subtitle != "") {
                var sub = new Gtk.Label(subtitle);
                sub.xalign = 0;
                sub.ellipsize = Pango.EllipsizeMode.END;
                sub.add_css_class("caption");
                sub.add_css_class("white-text");
                text.append(sub);
            }
            overlay.add_overlay(text);
            card.append(overlay);

            var clamp = new Adw.Clamp();
            clamp.maximum_size = 200;
            clamp.child = card;

            var g = new Gtk.GestureClick();
            g.released.connect(() => station_activated(s));
            clamp.add_controller(g);
            return clamp;
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
            var lbl = new Gtk.Label(_("Browse by Genre"));
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

            var flow = new Gtk.FlowBox();
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
    }
}
