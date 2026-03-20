// Song history page — virtualized list of recently played songs
namespace Receiver {

    public class HistoryPage : Gtk.Box {
        private HistoryStore history;
        private Gtk.ListView list_view;
        private Gtk.Stack stack;

        public signal void station_requested(int64 station_id);

        public HistoryPage() {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.history = HistoryStore.get_default();
            build_ui();
            update_empty();
            history.items_changed.connect((p, r, a) => update_empty());
        }

        private void build_ui() {
            var header = new Adw.HeaderBar();
            header.title_widget = new Gtk.Label(_("Song History"));
            this.append(header);

            stack = new Gtk.Stack();
            stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            stack.vexpand = true;

            // Empty state
            var empty = new Adw.StatusPage();
            empty.icon_name = "document-open-recent-symbolic";
            empty.title = _("No Songs Yet");
            empty.description = _("Songs will appear here as you listen to radio stations");
            stack.add_named(empty, "empty");

            // Virtualized list
            var factory = new Gtk.SignalListItemFactory();
            factory.setup.connect((f, o) => {
                ((Gtk.ListItem)o).child = new HistoryRow();
            });
            factory.bind.connect((f, o) => {
                var li = (Gtk.ListItem)o;
                ((HistoryRow)li.child).bind((HistoryEntry)li.item);
            });
            factory.unbind.connect((f, o) => {
                ((HistoryRow)((Gtk.ListItem)o).child).unbind();
            });

            var sel = new Gtk.SingleSelection(history);
            sel.autoselect = false;
            sel.can_unselect = true;
            list_view = new Gtk.ListView(sel, factory);
            list_view.single_click_activate = true;
            list_view.add_css_class("navigation-sidebar");
            list_view.margin_start = list_view.margin_end = 12;
            list_view.margin_top = 6;
            list_view.margin_bottom = 12;

            list_view.activate.connect((pos) => {
                var entry = history.get_item(pos) as HistoryEntry;
                if (entry != null) {
                    station_requested(entry.station_id);
                }
            });

            var scrolled = new Gtk.ScrolledWindow();
            scrolled.vexpand = true;
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.child = list_view;
            stack.add_named(scrolled, "list");

            this.append(stack);
        }

        private void update_empty() {
            stack.visible_child_name = history.get_n_items() == 0 ? "empty" : "list";
        }
    }

    public class HistoryRow : Gtk.Box {
        private Gtk.Label title_label;
        private Gtk.Label subtitle_label;
        private DownloadButton dl;
        private HistoryEntry? entry;

        public HistoryRow() {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 12);
            margin_top = margin_bottom = 8;
            margin_start = margin_end = 4;
            build_ui();
        }

        private void build_ui() {
            var icon = new Gtk.Image.from_icon_name("music-note-single-symbolic");
            icon.add_css_class("dim-label");
            icon.valign = Gtk.Align.CENTER;
            this.append(icon);

            var text = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text.valign = Gtk.Align.CENTER;
            text.hexpand = true;

            title_label = new Gtk.Label("");
            title_label.xalign = 0;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.max_width_chars = 1;
            title_label.hexpand = true;
            title_label.selectable = true;
            title_label.lines = 1;
            title_label.add_css_class("heading");
            text.append(title_label);

            subtitle_label = new Gtk.Label("");
            subtitle_label.xalign = 0;
            subtitle_label.ellipsize = Pango.EllipsizeMode.END;
            subtitle_label.max_width_chars = 1;
            subtitle_label.hexpand = true;
            subtitle_label.lines = 1;
            subtitle_label.add_css_class("dim-label");
            subtitle_label.add_css_class("caption");
            text.append(subtitle_label);
            this.append(text);

            dl = new DownloadButton();
            dl.clicked.connect(() => {
                if (entry != null) dl.download(entry.song_title);
            });
            this.append(dl);
        }

        public void bind(HistoryEntry e) {
            entry = e;
            title_label.label = e.song_title;
            subtitle_label.label = e.station_name + "  ·  " + format_time(e.played_at);
        }

        public void unbind() {
            entry = null;
        }

        private string format_time(string iso_time) {
            var dt = new DateTime.from_iso8601(iso_time, null);
            if (dt == null) return iso_time;

            var now = new DateTime.now_local();
            var diff = now.difference(dt);
            var minutes = (int)(diff / TimeSpan.MINUTE);
            var hours = (int)(diff / TimeSpan.HOUR);
            var days = (int)(diff / TimeSpan.DAY);

            if (minutes < 1) return _("Just now");
            if (minutes < 60) return ngettext("%d min ago", "%d min ago", minutes).printf(minutes);
            if (hours < 24) return ngettext("%d hour ago", "%d hours ago", hours).printf(hours);
            if (days < 7) return ngettext("%d day ago", "%d days ago", days).printf(days);

            // Older than a week: show date
            return dt.format("%b %e");
        }
    }
}
