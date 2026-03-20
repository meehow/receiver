// Station info page — full-page stream details view
namespace Receiver {

    public class StationInfoPage : Gtk.Box {
        private Player player;
        private Gtk.Picture artwork;
        private Gtk.Label name_label;
        private Gtk.Label country_label;
        private Gtk.Label codec_label;
        private Gtk.Label bitrate_label;
        private ulong info_handler = 0;
        private ulong station_handler = 0;

        public StationInfoPage(Player audio_player) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.player = audio_player;
            build_ui();
            connect_signals();
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

            // Artwork — just the picture, no frame
            artwork = new Gtk.Picture();
            artwork.content_fit = Gtk.ContentFit.SCALE_DOWN;
            artwork.halign = Gtk.Align.CENTER;
            artwork.vexpand = false;
            artwork.visible = false;
            content.append(artwork);

            // Info group
            var group = new Adw.PreferencesGroup();

            var name_row = new Adw.ActionRow();
            name_row.title = _("Station");
            name_label = make_value_label("");
            name_row.add_suffix(name_label);
            group.add(name_row);

            var country_row = new Adw.ActionRow();
            country_row.title = _("Country");
            country_label = make_value_label("");
            country_row.add_suffix(country_label);
            group.add(country_row);

            var tags_row = new Adw.ActionRow();
            tags_row.title = _("Tags");
            tags_row.subtitle_lines = 2;
            group.add(tags_row);

            var website_row = new Adw.ActionRow();
            website_row.title = _("Website");
            website_row.add_suffix(new Gtk.Image.from_icon_name("external-link-symbolic"));
            group.add(website_row);

            codec_label = make_value_label("—");
            var codec_row = new Adw.ActionRow();
            codec_row.title = _("Codec");
            codec_row.add_suffix(codec_label);
            group.add(codec_row);

            bitrate_label = make_value_label("—");
            var bitrate_row = new Adw.ActionRow();
            bitrate_row.title = _("Bitrate");
            bitrate_row.add_suffix(bitrate_label);
            group.add(bitrate_row);

            var stream_row = new Adw.ActionRow();
            stream_row.title = _("Stream URL");
            stream_row.subtitle_selectable = true;
            stream_row.subtitle_lines = 1;
            group.add(stream_row);

            content.append(group);
            scrolled.child = content;
            this.append(scrolled);

            // Store references for refresh
            this.set_data<Adw.ActionRow>("name_row", name_row);
            this.set_data<Adw.ActionRow>("country_row", country_row);
            this.set_data<Adw.ActionRow>("tags_row", tags_row);
            this.set_data<Adw.ActionRow>("website_row", website_row);
            this.set_data<Adw.ActionRow>("stream_row", stream_row);
        }

        private Gtk.Label make_value_label(string text) {
            var label = new Gtk.Label(text);
            label.add_css_class("dim-label");
            label.ellipsize = Pango.EllipsizeMode.END;
            return label;
        }

        private void connect_signals() {
            info_handler = player.stream_info_changed.connect(update_stream_info);
            station_handler = player.notify["current-station"].connect(() => refresh());
        }

        public void refresh() {
            var station = player.current_station;

            var name_row = this.get_data<Adw.ActionRow>("name_row");
            var country_row = this.get_data<Adw.ActionRow>("country_row");
            var tags_row = this.get_data<Adw.ActionRow>("tags_row");
            var website_row = this.get_data<Adw.ActionRow>("website_row");
            var stream_row = this.get_data<Adw.ActionRow>("stream_row");

            if (station == null) return;

            // Station name
            name_label.label = station.name;

            // Country
            country_label.label = station.country ?? "";
            country_row.visible = station.country != null && station.country != "";

            // Tags
            tags_row.subtitle = station.tags_raw != null ? station.tags_raw.replace(" ", ", ") : "";
            tags_row.visible = station.tags_raw != null && station.tags_raw != "";

            // Website
            website_row.visible = station.homepage != null && station.homepage != "";
            if (website_row.visible) {
                website_row.subtitle = station.homepage;
                website_row.subtitle_selectable = true;
                website_row.activatable = true;
                website_row.activated.connect(() => {
                    var launcher = new Gtk.UriLauncher(station.homepage);
                    launcher.launch.begin(get_root() as Gtk.Window, null);
                });
            }

            // Stream URL
            var url = station.get_stream_url();
            stream_row.subtitle = url ?? "";
            stream_row.visible = url != null && url != "";

            // Stream info
            update_stream_info();

            // Artwork
            load_artwork.begin(station);
        }

        private void update_stream_info() {
            codec_label.label = player.stream_codec != "" ? player.stream_codec : "—";
            bitrate_label.label = player.stream_bitrate > 0
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
