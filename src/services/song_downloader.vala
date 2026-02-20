// Song downloader - YouTube search + download in background threads
namespace Receiver {

    public class SongDownloader : Object {
        public signal void progress_updated(double fraction);

        private bool downloading = false;
        private weak Gtk.Window? window;
        private Cancellable? cancellable;

        public bool is_downloading {
            get { return downloading; }
        }

        public void cancel() {
            if (cancellable != null) {
                cancellable.cancel();
            }
        }

        public async void download_song(string? query, Gtk.Window? parent_window) {
            this.window = parent_window;
            if (query == null || query == "" || downloading) return;

            downloading = true;
            cancellable = new Cancellable();
            progress_updated(-1);  // indeterminate while searching
            show_toast(_("Searching YouTube…"));

            // Run search + extract in background thread
            Ytdl.VideoInfo? info = null;
            string? error_msg = null;

            new Thread<void>("ytdl-search", () => {
                var session = new Soup.Session();
                session.timeout = 30;
                Ytdl.SearchResult[] results;
                warning("ytdl: searching for '%s'", query);
                try {
                    results = Ytdl.search(session, query, 5);
                } catch (Error e) {
                    error_msg = _("Search failed: %s").printf(e.message);
                    warning("ytdl search error for '%s': %s", query, e.message);
                    Idle.add(download_song.callback);
                    return;
                }
                if (results.length == 0) {
                    error_msg = _("No YouTube results found");
                    Idle.add(download_song.callback);
                    return;
                }
                for (int i = 0; i < results.length; i++) {
                    message("ytdl: trying '%s' (%s)", results[i].title, results[i].video_id);
                    try {
                        info = Ytdl.extract(session, results[i].video_id);
                        break;
                    } catch (Error e) {
                        message("ytdl: result %d skipped: %s", i, e.message);
                    }
                }
                if (info == null) {
                    error_msg = _("All results unavailable");
                }
                Idle.add(download_song.callback);
            });
            yield;

            if (error_msg != null) {
                show_toast(_("Error: %s").printf(error_msg));
                downloading = false;
                progress_updated(0);
                return;
            }

            // Build filename from YouTube title
            var filename = sanitize_filename(info.title) + ".mp4";

            // Show save dialog
            var dialog = new Gtk.FileDialog();
            dialog.initial_name = filename;
            var saved_dir = AppState.get_default().settings.get_string("download-dir");
            if (saved_dir != "") {
                dialog.initial_folder = File.new_for_path(saved_dir);
            }


            try {
                var file = yield dialog.save(parent_window, null);
                if (file == null) {
                    downloading = false;
                    progress_updated(0);
                    return;
                }
                show_toast(_("Downloading: %s").printf(info.title));
                progress_updated(0);

                // Download in background with progress
                var dest = file;
                var url = info.url;
                string? dl_error = null;

                new Thread<void>("ytdl-download", () => {
                    try {
                        var session = new Soup.Session();
                        session.timeout = 120;
                        var msg = new Soup.Message("GET", url);
                        var stream = session.send(msg, cancellable);
                        if (msg.status_code != 200) {
                            dl_error = "HTTP %u".printf(msg.status_code);
                            Idle.add(download_song.callback);
                            return;
                        }
                        int64 total = msg.response_headers.get_content_length();
                        int64 received = 0;
                        var out_stream = dest.replace(null, false, FileCreateFlags.REPLACE_DESTINATION, cancellable);
                        uint8[] buffer = new uint8[65536];
                        while (true) {
                            var n = stream.read(buffer, cancellable);
                            if (n <= 0) break;
                            out_stream.write(buffer[0:n], cancellable);
                            received += n;
                            if (total > 0) {
                                double frac = (double) received / (double) total;
                                Idle.add(() => { progress_updated(frac); return false; });
                            }
                        }
                        out_stream.close(null);
                    } catch (IOError.CANCELLED e) {
                        // Clean up partial file
                        try { dest.delete(null); } catch (Error de) {}
                        dl_error = _("Cancelled");
                    } catch (Error e) {
                        dl_error = e.message;
                    }
                    Idle.add(download_song.callback);
                });
                yield;

                if (dl_error != null) {
                    show_toast(_("Download failed: %s").printf(dl_error));
                } else {
                    show_toast(_("Saved: %s").printf(dest.get_basename()));
                    AppState.get_default().settings.set_string("download-dir", dest.get_parent().get_path());
                }
            } catch (Error e) {
                // User dismissed the dialog — no toast needed
                if (!(e is Gtk.DialogError.DISMISSED || e is Gtk.DialogError.CANCELLED)) {
                    show_toast(_("Error: %s").printf(e.message));
                }
            }

            downloading = false;
            cancellable = null;
        }

        private void show_toast(string msg) {
            var win = window as Adw.ApplicationWindow;
            if (win == null) return;
            var box = win.content as Gtk.Box;
            if (box == null) return;
            var child = box.get_first_child();
            if (child is Adw.ToastOverlay) {
                var t = new Adw.Toast(Markup.escape_text(msg));
                t.timeout = 3;
                ((Adw.ToastOverlay) child).add_toast(t);
            }
        }

        private string sanitize_filename(string name) {
            return name.replace("/", "-").replace("\\", "-")
                       .replace(":", "-").replace("*", "")
                       .replace("?", "").replace("\"", "")
                       .replace("<", "").replace(">", "")
                       .replace("|", "-").strip();
        }
    }
}
