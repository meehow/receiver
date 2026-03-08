// Song history page — list of recently played songs
namespace Receiver {

    public class HistoryPage : Gtk.Box {
        private HistoryStore history;
        private Gtk.ListBox list_box;
        private Gtk.Stack stack;

        public signal void station_requested(int64 station_id);

        public HistoryPage() {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.history = HistoryStore.get_default();
            build_ui();
            history.changed.connect(refresh);
            refresh();
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

            // List
            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;

            list_box = new Gtk.ListBox();
            list_box.selection_mode = Gtk.SelectionMode.NONE;
            list_box.add_css_class("boxed-list");
            list_box.margin_start = list_box.margin_end = 16;
            list_box.margin_top = list_box.margin_bottom = 16;
            scrolled.child = list_box;
            stack.add_named(scrolled, "list");

            this.append(stack);
        }

        private void refresh() {
            Gtk.Widget? child;
            while ((child = list_box.get_first_child()) != null) {
                list_box.remove(child);
            }

            var entries = history.get_entries();
            if (entries.length == 0) {
                stack.visible_child_name = "empty";
                return;
            }

            stack.visible_child_name = "list";
            for (int i = 0; i < entries.length; i++) {
                list_box.append(create_row(entries[i]));
            }
        }

        private Gtk.Widget create_row(HistoryEntry entry) {
            var row = new Adw.ActionRow();
            row.title = Markup.escape_text(entry.song_title);
            row.title_selectable = true;
            row.subtitle = Markup.escape_text(entry.station_name)
                + "  ·  " + format_time(entry.played_at);
            row.activatable = true;
            row.activated.connect(() => {
                station_requested(entry.station_id);
            });

            var dl = new DownloadButton();
            dl.clicked.connect(() => dl.download(entry.song_title));
            row.add_suffix(dl);

            return row;
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
