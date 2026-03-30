// Favourites page — grid of saved stations with drag-to-reorder
namespace Receiver {

    public class FavouritesPage : Gtk.Box {

        private Gtk.FlowBox favourites_flow;
        private Gtk.Stack stack;
        private Adw.StatusPage empty_page;

        public signal void station_activated(Station station);

        public FavouritesPage(StationStore station_store) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            build_ui();
            AppState.get_default().favourites_changed.connect(update_favourites);
            station_store.loading_finished.connect(() => {
                update_favourites();
            });
        }

        private void build_ui() {
            // Empty state
            empty_page = new Adw.StatusPage();
            empty_page.icon_name = "starred-symbolic";
            empty_page.title = _("No Favourites");
            empty_page.description = _("Star stations while browsing to add them here");

            // Favourites grid
            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
            content.margin_start = content.margin_end = content.margin_top = content.margin_bottom = 16;

            favourites_flow = new Gtk.FlowBox();
            favourites_flow.selection_mode = Gtk.SelectionMode.NONE;
            favourites_flow.homogeneous = true;
            favourites_flow.max_children_per_line = 4;
            favourites_flow.min_children_per_line = 2;
            favourites_flow.row_spacing = favourites_flow.column_spacing = 8;
            content.append(favourites_flow);

            scrolled.child = content;

            stack = new Gtk.Stack();
            stack.add_named(empty_page, "empty");
            stack.add_named(scrolled, "grid");
            stack.visible_child_name = "empty";
            this.append(stack);
        }

        private void update_favourites() {
            Gtk.Widget? child;
            while ((child = favourites_flow.get_first_child()) != null) {
                favourites_flow.remove(child);
            }
            var favs = AppState.get_default().get_favourite_stations();
            if (favs.length == 0) {
                stack.visible_child_name = "empty";
            } else {
                stack.visible_child_name = "grid";
                for (int i = 0; i < favs.length; i++) {
                    favourites_flow.append(create_fav_card(favs[i], i));
                }
            }
        }

        private Gtk.Widget create_fav_card(Station s, int index) {
            var card = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            card.add_css_class("card");
            card.set_size_request(180, 60);

            var img_stack = new Gtk.Stack();
            var ph = new Gtk.Image.from_icon_name("audio-x-generic-symbolic");
            ph.set_size_request(48, 48);
            ph.pixel_size = 32;
            ph.add_css_class("dim-label");
            img_stack.add_named(ph, "placeholder");
            var art = new Gtk.Picture();
            art.set_size_request(48, 48);
            art.content_fit = Gtk.ContentFit.COVER;
            var frame = new Gtk.Frame(null);
            frame.child = art;
            frame.add_css_class("circular");
            frame.overflow = Gtk.Overflow.HIDDEN;
            frame.set_size_request(48, 48);
            img_stack.add_named(frame, "artwork");
            card.append(img_stack);

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

            load_artwork.begin(s, art, img_stack);

            // Click to play
            var g = new Gtk.GestureClick();
            g.released.connect(() => {
                station_activated(s);
            });
            card.add_controller(g);

            // Drag source — carry the position index
            var drag = new Gtk.DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect((src, x, y) => {
                var val = Value(typeof(uint));
                val.set_uint((uint) index);
                return new Gdk.ContentProvider.for_value(val);
            });
            card.add_controller(drag);

            // Drop target — reorder on drop
            var drop = new Gtk.DropTarget(typeof(uint), Gdk.DragAction.MOVE);
            drop.on_drop.connect((target, val, x, y) => {
                var from = (int) val.get_uint();
                var to = index;
                if (from != to) {
                    AppState.get_default().move_favourite(from, to);
                }
                return true;
            });
            card.add_controller(drop);

            return card;
        }

        private async void load_artwork(Station s, Gtk.Picture art, Gtk.Stack img_stack) {
            var tex = yield ImageLoader.get_default().load(s.image_hash);
            if (tex != null) {
                art.paintable = tex;
                img_stack.visible_child_name = "artwork";
            }
        }
    }
}
