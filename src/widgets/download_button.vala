// Reusable download button with progress indicator
namespace Receiver {

    public class DownloadButton : Gtk.Box {
        private Gtk.Button save_button;
        private Gtk.ProgressBar progress_bar;
        private Gtk.Stack dl_stack;
        private SongDownloader downloader;
        private ulong progress_handler = 0;

        public signal void clicked();

        public DownloadButton() {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 0);
            this.downloader = new SongDownloader();
            this.valign = Gtk.Align.CENTER;
            build_ui();
        }

        private void build_ui() {
            dl_stack = new Gtk.Stack();
            dl_stack.hhomogeneous = false;
            dl_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            dl_stack.valign = Gtk.Align.CENTER;

            save_button = new Gtk.Button.from_icon_name("document-save-symbolic");
            save_button.add_css_class("flat");
            save_button.add_css_class("circular");
            save_button.add_css_class("dim-label");
            save_button.tooltip_text = _("Download song");
            save_button.valign = Gtk.Align.CENTER;
            save_button.halign = Gtk.Align.END;
            save_button.hexpand = false;
            save_button.clicked.connect(() => clicked());
            dl_stack.add_named(save_button, "button");

            progress_bar = new Gtk.ProgressBar();
            progress_bar.valign = Gtk.Align.CENTER;
            progress_bar.hexpand = true;
            progress_bar.set_size_request(64, -1);

            var cancel = new Gtk.Button.from_icon_name("process-stop-symbolic");
            cancel.add_css_class("circular");
            cancel.add_css_class("flat");
            cancel.valign = Gtk.Align.CENTER;
            cancel.tooltip_text = _("Cancel download");
            cancel.clicked.connect(() => downloader.cancel());

            var progress_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            progress_box.valign = Gtk.Align.CENTER;
            progress_box.append(progress_bar);
            progress_box.append(cancel);
            dl_stack.add_named(progress_box, "progress");

            dl_stack.visible_child_name = "button";
            this.append(dl_stack);
        }

        public void download(string query) {
            if (downloader.is_downloading) return;

            var win = get_root() as Gtk.Window;
            save_button.sensitive = false;
            dl_stack.visible_child_name = "progress";
            progress_bar.fraction = 0;

            progress_handler = downloader.progress_updated.connect((frac) => {
                if (frac >= 0) {
                    progress_bar.fraction = frac;
                }
            });

            downloader.download_song.begin(query, win, (obj, res) => {
                downloader.download_song.end(res);
                if (progress_handler > 0) {
                    downloader.disconnect(progress_handler);
                    progress_handler = 0;
                }
                dl_stack.visible_child_name = "button";
                save_button.sensitive = true;
                progress_bar.fraction = 0;
            });
        }
    }
}
