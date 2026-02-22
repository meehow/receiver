// GStreamer-based audio player for internet radio
namespace Receiver {

    public enum PlayerState {
        STOPPED, PLAYING, PAUSED, ERROR
    }

    public class Player : Object {
        private Gst.Element? pipeline;
        private Gst.Bus? bus;
        private ulong bus_handler_id = 0;
        private string? last_raw_title = null;
        private int retry_count = 0;
        private uint retry_timeout = 0;
        private const int MAX_RETRIES = 3;
        private Cancellable? play_cancellable = null;

        public Station? current_station { get; private set; }
        public PlayerState state { get; private set; default = PlayerState.STOPPED; }

        public string now_playing { get; private set; default = ""; }

        private double _volume = 1.0;
        public double volume {
            get { return _volume; }
            set {
                _volume = value.clamp(0.0, 1.0);
                if (pipeline != null) pipeline.set_property("volume", _volume);
            }
        }

        public signal void state_changed(PlayerState new_state);
        public signal void error_occurred(string message);

        public signal void metadata_changed(string title);

        ~Player() { stop(); }

        private void cleanup() {
            if (bus != null && bus_handler_id != 0) {
                bus.disconnect(bus_handler_id);
                bus.remove_signal_watch();
                bus_handler_id = 0;
                bus = null;
            }
            if (pipeline != null) {
                var old = pipeline;
                pipeline = null;
                new Thread<void>("cleanup", () => {
                    old.set_state(Gst.State.NULL);
                });
            }
        }

        public void play(Station station) {
            var url = station.get_stream_url();
            if (url == null || url == "") {
                error_occurred("No stream URL available");
                return;
            }

            cancel_retry();
            if (play_cancellable != null) play_cancellable.cancel();
            play_cancellable = new Cancellable();
            retry_count = 0;
            current_station = station;

            now_playing = "";
            last_raw_title = null;
            metadata_changed(station.name);

            // Resolve playlists (.pls, .m3u, .m3u8), otherwise resolve redirects
            var cancel = play_cancellable;
            if (url.has_suffix(".pls") || url.has_suffix(".m3u") || url.has_suffix(".m3u8")) {
                resolve_playlist.begin(url, cancel);
            } else {
                resolve_redirects.begin(url, cancel);
            }
        }

        // Pre-resolve HTTP redirects since GStreamer's souphttpsrc fails on some 302s
        private async void resolve_redirects(string url, Cancellable cancel) {
            var resolved = url;
            try {
                var session = new Soup.Session();
                session.timeout = 5;
                var msg = new Soup.Message("GET", url);
                msg.set_force_http1(true);
                // Accept expired/invalid TLS certs — we only follow redirects here
                msg.accept_certificate.connect(() => { return true; });
                // Let libsoup follow redirects automatically
                var stream = yield session.send_async(msg, Priority.DEFAULT, cancel);
                // Close immediately — we only need the final resolved URI
                try { stream.close(); } catch {}
                resolved = msg.get_uri().to_string();
                session.abort();
            } catch (Error e) {
                if (cancel.is_cancelled()) return;
                message("Redirect resolution failed: %s", e.message);
            }

            if (cancel.is_cancelled()) return;
            if (resolved != url) {
                message("Resolved redirect: %s -> %s", url, resolved);
            }
            start(resolved);
        }

        private void start(string url) {
            message("Playing: %s - %s", current_station.name, url);
            cleanup();
            state = PlayerState.STOPPED;  // Reset so STATE_CHANGED is processed

            pipeline = Gst.ElementFactory.make("playbin", "player");
            if (pipeline == null) {
                error_occurred("Failed to create player");
                return;
            }

            pipeline.set_property("uri", url);
            pipeline.set_property("volume", _volume);
            pipeline.set_property("flags", 0x02);  // Audio only
            pipeline.set_property("buffer-duration", (int64) Gst.SECOND * 2);

            // Set User-Agent so Shoutcast/Icecast servers don't reject us
            //  ((Gst.Bin) pipeline).deep_element_added.connect((bin, element) => {
            //      if (pipeline == null || bin != pipeline) return;
            //      var factory = element.get_factory();
            //      if (factory != null && factory.get_name() == "souphttpsrc") {
            //          element.set_property("user-agent", "Receiver/1.0");
            //      }
            //  });

            bus = pipeline.get_bus();
            bus.add_signal_watch();
            bus_handler_id = bus.message.connect(on_message);
            pipeline.set_state(Gst.State.PLAYING);
        }

        private void on_message(Gst.Bus b, Gst.Message msg) {
            switch (msg.type) {
                case Gst.MessageType.STATE_CHANGED:
                    if (msg.src == pipeline) {
                        Gst.State old_s, new_s, pending;
                        msg.parse_state_changed(out old_s, out new_s, out pending);
                        // After error, GStreamer transitions to NULL — ignore it
                        if (state == PlayerState.ERROR) break;
                        if (new_s == Gst.State.PLAYING) {
                            retry_count = 0;  // Reset on successful playback
                            update_state(PlayerState.PLAYING);
                        } else if (new_s == Gst.State.PAUSED) update_state(PlayerState.PAUSED);
                        else if (new_s == Gst.State.NULL || new_s == Gst.State.READY) update_state(PlayerState.STOPPED);
                    }
                    break;

                case Gst.MessageType.ERROR:
                    Error err; string debug;
                    msg.parse_error(out err, out debug);
                    warning("GStreamer: %s (%s)", err.message, debug);
                    cleanup();
                    update_state(PlayerState.ERROR);
                    schedule_retry(err.message);
                    break;

                case Gst.MessageType.EOS:
                    stop();
                    break;

                case Gst.MessageType.TAG:
                    Gst.TagList tags;
                    msg.parse_tag(out tags);
                    handle_tags(tags);
                    break;

                default: break;
            }
        }

        private void handle_tags(Gst.TagList tags) {
            string? title = null;
            string? artist = null;

            if (tags.get_string(Gst.Tags.TITLE, out title) && title != null && title != "") {
                if (title == last_raw_title) return;
                last_raw_title = title;

                tags.get_string(Gst.Tags.ARTIST, out artist);
                title = MetadataParser.get_default().clean_metadata(title, artist);

                if (title.has_prefix("{")) return;  // Skip JSON metadata

                if (now_playing != title) {
                    now_playing = title;
                    metadata_changed(title);
                    message("Now playing: %s", title);
                }
            }
        }

        private void update_state(PlayerState s) {
            if (state != s) {
                state = s;
                state_changed(s);
            }
        }

        public void stop() {
            cancel_retry();
            if (play_cancellable != null) play_cancellable.cancel();
            cleanup();
            current_station = null;
            now_playing = "";
            update_state(PlayerState.STOPPED);
        }

        public void toggle_pause() {
            if (pipeline == null || state != PlayerState.PLAYING) {
                if (current_station != null) {
                    var s = current_station;
                    Idle.add(() => {
                        play(s);
                        return false;
                    });
                }
                return;
            }
            pipeline.set_state(Gst.State.PAUSED);
        }

        private void schedule_retry(string error_msg) {
            if (current_station == null || retry_count >= MAX_RETRIES) {
                error_occurred(error_msg);
                return;
            }

            retry_count++;
            var delay = (uint)(2000 * (1 << (retry_count - 1)));  // 2s, 4s, 8s
            message("Reconnecting in %ums (attempt %d/%d)...", delay, retry_count, MAX_RETRIES);

            retry_timeout = Timeout.add(delay, () => {
                retry_timeout = 0;
                if (current_station != null) {
                    message("Retry attempt %d for %s", retry_count, current_station.name);
                    var url = current_station.get_stream_url();
                    if (url != null && url != "") {
                        var cancel = play_cancellable;
                        if (url.has_suffix(".pls") || url.has_suffix(".m3u") || url.has_suffix(".m3u8")) {
                            resolve_playlist.begin(url, cancel);
                        } else {
                            resolve_redirects.begin(url, cancel);
                        }
                    }
                }
                return false;
            });
        }

        private void cancel_retry() {
            if (retry_timeout > 0) {
                Source.remove(retry_timeout);
                retry_timeout = 0;
            }
        }

        // Resolve .pls, .m3u, and .m3u8 playlists to a stream URL
        private async void resolve_playlist(string url, Cancellable cancel) {
            try {
                var session = new Soup.Session();
                session.timeout = 10;
                var msg = new Soup.Message("GET", url);
                var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, cancel);
                if (cancel.is_cancelled()) return;
                if (msg.status_code != 200) {
                    error_occurred("Playlist fetch failed: HTTP %u".printf(msg.status_code));
                    return;
                }
                var content = (string) bytes.get_data();
                var base_url = url.substring(0, url.last_index_of("/") + 1);

                string? stream_url = null;
                bool next_is_uri = false;
                foreach (var line in content.split("\n")) {
                    var l = line.strip();
                    // PLS: File1=http://...
                    if (url.has_suffix(".pls") && l.has_prefix("File") && l.contains("=")) {
                        stream_url = l.split("=", 2)[1];
                        break;
                    }
                    // HLS master playlist: line after #EXT-X-STREAM-INF
                    if (l.has_prefix("#EXT-X-STREAM-INF")) {
                        next_is_uri = true;
                        continue;
                    }
                    if (l == "" || l.has_prefix("#")) continue;
                    // Non-comment, non-empty line — it's a URL
                    if (next_is_uri || l.has_prefix("http://") || l.has_prefix("https://")) {
                        stream_url = l;
                        break;
                    }
                }

                // Resolve relative URLs (common in HLS)
                if (stream_url != null && !stream_url.has_prefix("http")) {
                    stream_url = base_url + stream_url;
                }

                if (cancel.is_cancelled()) return;
                if (stream_url != null) {
                    message("Playlist resolved: %s -> %s", url, stream_url);
                    start(stream_url);
                } else {
                    error_occurred("No stream URL in playlist");
                }
            } catch (Error e) {
                if (cancel.is_cancelled()) return;
                // HLS: fall back to original URL; others: report error
                if (url.has_suffix(".m3u8")) {
                    start(url);
                } else {
                    error_occurred("Playlist error: " + e.message);
                }
            }
        }
    }
}
