// Station info page — full-page stream details view
namespace Receiver {

    public class StationInfoPage : Gtk.Box {
        private Player player;
        private Gtk.Picture artwork;
        private Adw.ActionRow name_row;
        private Adw.ActionRow country_row;
        private Adw.ActionRow tags_row;
        private Adw.ActionRow website_row;
        private Adw.ActionRow codec_row;
        private Adw.ActionRow bitrate_row;
        private Adw.ActionRow stream_row;

        public StationInfoPage(Player audio_player) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.player = audio_player;
            build_ui();
            player.stream_info_changed.connect(update_stream_info);
            player.notify["current-station"].connect(() => refresh());
        }

        private void build_ui() {
            var header = new Adw.HeaderBar();
            header.title_widget = new Gtk.Label(_("Station Info"));
            this.append(header);

            var scrolled = new Gtk.ScrolledWindow();
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.vexpand = true;

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            content.valign = Gtk.Align.START;
            content.margin_start = content.margin_end = 16;
            content.margin_top = 8;
            content.margin_bottom = 16;

            artwork = new Gtk.Picture();
            artwork.content_fit = Gtk.ContentFit.SCALE_DOWN;
            artwork.halign = Gtk.Align.CENTER;
            artwork.vexpand = false;
            artwork.visible = false;
            content.append(artwork);

            var group = new Adw.PreferencesGroup();

            name_row = new Adw.ActionRow();
            name_row.title = _("Station");
            group.add(name_row);

            country_row = new Adw.ActionRow();
            country_row.title = _("Country");
            group.add(country_row);

            tags_row = new Adw.ActionRow();
            tags_row.title = _("Tags");
            tags_row.subtitle_lines = 2;
            group.add(tags_row);

            website_row = new Adw.ActionRow();
            website_row.title = _("Website");
            website_row.use_markup = true;
            group.add(website_row);

            codec_row = new Adw.ActionRow();
            codec_row.title = _("Codec");
            group.add(codec_row);

            bitrate_row = new Adw.ActionRow();
            bitrate_row.title = _("Bitrate");
            group.add(bitrate_row);

            stream_row = new Adw.ActionRow();
            stream_row.title = _("Stream URL");
            stream_row.subtitle_selectable = true;
            stream_row.subtitle_lines = 1;
            group.add(stream_row);

            content.append(group);
            scrolled.child = content;
            this.append(scrolled);
        }

        public void refresh() {
            var station = player.current_station;
            if (station == null) return;

            name_row.subtitle = station.name;

            country_row.subtitle = station.country ?? "";
            country_row.visible = station.country != null && station.country != "";

            tags_row.subtitle = station.tags_raw != null ? station.tags_raw.replace(" ", ", ") : "";
            tags_row.visible = station.tags_raw != null && station.tags_raw != "";

            website_row.visible = station.homepage != null && station.homepage != "";
            if (website_row.visible) {
                var escaped = Markup.escape_text(station.homepage);
                website_row.subtitle = "<a href=\"%s\">%s</a>".printf(escaped, escaped);
            }

            var url = station.get_stream_url();
            stream_row.subtitle = url ?? "";
            stream_row.visible = url != null && url != "";

            update_stream_info();
            load_artwork.begin(station);
        }

        private void update_stream_info() {
            codec_row.subtitle = player.stream_codec != "" ? player.stream_codec : "—";
            bitrate_row.subtitle = player.stream_bitrate > 0
                ? "%u kbps".printf(player.stream_bitrate / 1000) : "—";
        }

        private async void load_artwork(Station s) {
            artwork.visible = false;
            if (s.image_hash == 0) return;

            var tex = yield ImageLoader.get_default().load(s.image_hash);
            if (player.current_station != s) return;
            if (tex != null) {
                artwork.paintable = tex;
                artwork.visible = true;
            }
        }
    }
}
