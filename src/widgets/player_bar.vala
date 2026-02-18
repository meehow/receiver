// Player bar with playback controls
namespace Receiver {

    public class PlayerBar : Gtk.Box {
        private Player player;
        private Gtk.Picture artwork;
        private Gtk.Stack image_stack;
        private Gtk.Label title_label;
        private Gtk.Label subtitle_label;
        private Gtk.Button play_button;
        private Gtk.Image play_icon;
        private Gtk.Scale volume_scale;

        private Gtk.Revealer revealer;
        private Gtk.Button website_button;
        private Gtk.Button favourite_button;
        private Gtk.Button download_button;
        private Gtk.Stack download_stack;
        private Gtk.ProgressBar download_progress;
        private SongDownloader downloader;

        public PlayerBar(Player audio_player) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.player = audio_player;
            this.downloader = new SongDownloader();
            build_ui();
            connect_signals();
        }

        private void build_ui() {
            revealer = new Gtk.Revealer();
            revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            this.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));

            var main = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            main.margin_start = main.margin_end = main.margin_top = main.margin_bottom = 10;
            main.set_size_request(-1, 72);

            // Artwork stack
            image_stack = new Gtk.Stack();
            image_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            var placeholder = new Gtk.Image.from_icon_name("audio-x-generic-symbolic");
            placeholder.set_size_request(64, 64);
            placeholder.pixel_size = 64;
            image_stack.add_named(placeholder, "placeholder");
            artwork = new Gtk.Picture();
            artwork.set_size_request(64, 64);
            artwork.content_fit = Gtk.ContentFit.COVER;
            var frame = new Gtk.Frame(null);
            frame.child = artwork;
            frame.add_css_class("circular");
            frame.overflow = Gtk.Overflow.HIDDEN;
            frame.set_size_request(64, 64);
            image_stack.add_named(frame, "artwork");
            var artwork_click = new Gtk.GestureClick();
            artwork_click.released.connect(() => {
                if (image_stack.visible_child_name == "artwork" && artwork.paintable != null) {
                    show_artwork_dialog();
                }
            });
            image_stack.add_controller(artwork_click);
            image_stack.cursor = new Gdk.Cursor.from_name("pointer", null);
            main.append(image_stack);

            // Right side
            var right = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            right.hexpand = true;
            right.valign = Gtk.Align.CENTER;

            // Controls row
            var controls = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            title_label = new Gtk.Label(_("Not Playing"));
            title_label.xalign = 0;
            title_label.hexpand = true;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.add_css_class("heading");
            controls.append(title_label);



            website_button = new Gtk.Button.from_icon_name("web-browser-symbolic");
            website_button.add_css_class("circular");
            website_button.add_css_class("flat");
            website_button.visible = false;
            website_button.clicked.connect(() => {
                var s = player.current_station;
                if (s != null && s.homepage != null) {
                    var launcher = new Gtk.UriLauncher(s.homepage);
                    launcher.launch.begin(get_root() as Gtk.Window, null);
                }
            });
            controls.append(website_button);

            favourite_button = new Gtk.Button.from_icon_name("non-starred-symbolic");
            favourite_button.add_css_class("circular");
            favourite_button.add_css_class("flat");
            favourite_button.visible = false;
            favourite_button.clicked.connect(() => {
                var s = player.current_station;
                if (s != null) {
                    var app = GLib.Application.get_default() as Application;
                    if (app != null) {
                        app.store.toggle_favourite(s);
                    }
                }
            });
            controls.append(favourite_button);

            play_icon = new Gtk.Image.from_icon_name("media-playback-start-symbolic");
            play_button = new Gtk.Button();
            play_button.child = play_icon;
            play_button.add_css_class("circular");
            play_button.add_css_class("suggested-action");
            play_button.clicked.connect(() => {
                player.toggle_pause();
            });
            controls.append(play_button);

            var stop = new Gtk.Button.from_icon_name("media-playback-stop-symbolic");
            stop.add_css_class("circular");
            stop.clicked.connect(() => {
                player.stop();
            });
            controls.append(stop);

            var vol_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            vol_box.append(new Gtk.Image.from_icon_name("audio-volume-high-symbolic"));
            volume_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.01);
            volume_scale.set_value(player.volume);
            volume_scale.set_size_request(100, -1);
            volume_scale.draw_value = false;
            volume_scale.value_changed.connect(() => {
                player.volume = volume_scale.get_value();
            });
            vol_box.append(volume_scale);
            controls.append(vol_box);
            right.append(controls);

            var subtitle_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            subtitle_row.set_size_request(-1, 34);
            subtitle_label = new Gtk.Label(_("Select a station"));
            subtitle_label.xalign = 0;
            subtitle_label.hexpand = true;
            subtitle_label.selectable = true;
            subtitle_label.ellipsize = Pango.EllipsizeMode.END;
            subtitle_label.add_css_class("dim-label");
            subtitle_label.add_css_class("caption");
            subtitle_row.append(subtitle_label);

            download_button = new Gtk.Button.from_icon_name("document-save-symbolic");
            download_button.add_css_class("flat");
            download_button.add_css_class("circular");
            download_button.add_css_class("dim-label");
            download_button.tooltip_text = _("Download song");
            download_button.valign = Gtk.Align.CENTER;
            download_button.halign = Gtk.Align.END;
            download_button.hexpand = false;
            download_button.clicked.connect(() => {
                if (!downloader.is_downloading) {
                    var q = player.now_playing;
                    var win = get_root() as Gtk.Window;
                    download_button.sensitive = false;
                    downloader.download_song.begin(q, win, (obj, res) => {
                        downloader.download_song.end(res);
                        download_stack.visible_child_name = "button";
                        download_button.sensitive = true;
                        download_progress.fraction = 0;
                    });
                }
            });

            download_progress = new Gtk.ProgressBar();
            download_progress.valign = Gtk.Align.CENTER;
            download_progress.hexpand = true;
            download_progress.set_size_request(64, -1);

            var cancel_button = new Gtk.Button.from_icon_name("process-stop-symbolic");
            cancel_button.add_css_class("circular");
            cancel_button.add_css_class("flat");
            cancel_button.add_css_class("dim-label");
            cancel_button.valign = Gtk.Align.CENTER;
            cancel_button.tooltip_text = _("Cancel download");
            cancel_button.clicked.connect(() => {
                downloader.cancel();
            });

            var progress_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            progress_box.valign = Gtk.Align.CENTER;
            progress_box.append(download_progress);
            progress_box.append(cancel_button);

            download_stack = new Gtk.Stack();
            download_stack.hhomogeneous = false;
            download_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            download_stack.add_named(download_button, "button");
            download_stack.add_named(progress_box, "progress");
            download_stack.visible_child_name = "button";
            download_stack.visible = false;
            download_stack.valign = Gtk.Align.CENTER;

            downloader.progress_updated.connect((frac) => {
                if (frac >= 0) {
                    download_progress.fraction = frac;
                    download_stack.visible_child_name = "progress";
                }
            });

            subtitle_row.append(download_stack);
            right.append(subtitle_row);

            main.append(right);
            var clamp = new Adw.Clamp();
            clamp.orientation = Gtk.Orientation.VERTICAL;
            clamp.maximum_size = 64;
            clamp.child = main;
            revealer.child = clamp;
            this.append(revealer);
        }

        private void connect_signals() {
            player.state_changed.connect(on_state);

            player.notify["current-station"].connect(() => {
                if (player.current_station != null) {
                    update_info();
                }
            });

            player.metadata_changed.connect((t) => {
                if (t != "" && player.state == PlayerState.PLAYING) {
                    subtitle_label.label = format_now_playing(t);
                    download_stack.visible = looks_like_song(t);
                }
            });

            var app = GLib.Application.get_default() as Application;
            if (app != null) {
                app.store.favourites_changed.connect(update_fav);
            }
        }

        private void on_state(PlayerState state) {
            revealer.reveal_child = player.current_station != null || state != PlayerState.STOPPED;


            switch (state) {
                case PlayerState.PLAYING:
                    play_icon.icon_name = "media-playback-pause-symbolic";
                    update_info();
                    break;
                case PlayerState.PAUSED:
                    play_icon.icon_name = "media-playback-start-symbolic";
                    subtitle_label.label = _("Paused");
                    break;

                case PlayerState.ERROR:
                    play_icon.icon_name = "media-playback-start-symbolic";
                    subtitle_label.label = _("Reconnecting…");
                    break;
                default:
                    play_icon.icon_name = "media-playback-start-symbolic";
                    website_button.visible = favourite_button.visible = download_stack.visible = false;
                    title_label.label = _("Not Playing");
                    subtitle_label.label = _("Select a station");
                    artwork.paintable = null;
                    image_stack.visible_child_name = "placeholder";
                    break;
            }
        }

        private void update_info() {
            var s = player.current_station;
            if (s == null) {
                return;
            }
            title_label.label = s.name;
            website_button.visible = s.homepage != null;
            website_button.tooltip_text = s.homepage;
            update_fav();
            var np = player.now_playing;
            subtitle_label.label = (np != null && np != "") ? format_now_playing(np) : _("Now playing");
            download_stack.visible = np != null && looks_like_song(np);
            load_artwork.begin(s);
        }

        private async void load_artwork(Station s) {
            var tex = yield ImageLoader.get_default().load(s.image_hash);
            if (player.current_station != s) return;
            if (tex != null) {
                artwork.paintable = tex;
                image_stack.visible_child_name = "artwork";
            } else {
                artwork.paintable = null;
                image_stack.visible_child_name = "placeholder";
            }
        }

        private void update_fav() {
            var s = player.current_station;
            if (s == null) {
                favourite_button.visible = false;
                return;
            }
            favourite_button.visible = true;
            var app = GLib.Application.get_default() as Application;
            var is_fav = app != null && app.store.is_favourite(s.id);
            favourite_button.icon_name = is_fav ? "starred-symbolic" : "non-starred-symbolic";
        }


        private bool looks_like_song(string t) {
            return t.contains("- ");
        }

        private string format_now_playing(string title) {
            return "♪ " + title;
        }

        private void show_artwork_dialog() {
            var tex = artwork.paintable;
            if (tex == null || tex.get_intrinsic_width() <= 64) return;

            var win = new Gtk.Window();
            win.decorated = false;
            win.modal = true;
            win.transient_for = get_root() as Gtk.Window;
            win.default_width = tex.get_intrinsic_width();
            win.default_height = tex.get_intrinsic_height();

            var pic = new Gtk.Picture();
            pic.paintable = tex;
            pic.content_fit = Gtk.ContentFit.CONTAIN;
            pic.can_shrink = true;
            var click = new Gtk.GestureClick();
            click.released.connect(() => win.close());
            pic.add_controller(click);

            win.child = pic;
            win.present();
        }
    }
}
