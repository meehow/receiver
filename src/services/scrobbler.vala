// Last.fm scrobbling manager — track timing and state machine
namespace Receiver {

    public class Scrobbler : Object {
        private LastfmService lastfm;
        private Player player;
        private Settings settings;
        private MetadataExtractor extractor;

        // Current track state
        private string? current_artist = null;
        private string? current_title = null;
        private int64 track_start_time = 0;  // Unix timestamp when track started
        private uint scrobble_timer = 0;

        // Scrobble after 30 seconds (Last.fm minimum track length)
        private const int SCROBBLE_THRESHOLD_SECONDS = 30;


        public signal void status_changed();

        public Scrobbler(Player player) {
            this.player = player;
            this.lastfm = new LastfmService();
            this.settings = new Settings("io.github.meehow.Receiver");
            this.extractor = MetadataExtractor.get_default();

            // Connect to player signals
            player.metadata_changed.connect(on_metadata_changed);
            player.state_changed.connect(on_state_changed);
        }

        public bool is_enabled() {
            return settings.get_string("lastfm-session-key") != "";
        }

        private string? get_session_key() {
            var val = settings.get_string("lastfm-session-key");
            return val != "" ? val : null;
        }

        /**
         * Start the desktop auth flow.
         * Returns the auth URL to open in the browser, or null on failure.
         * After user grants access, call complete_auth().
         */
        private string? auth_token = null;

        public async string? start_auth() {
            auth_token = yield lastfm.auth_get_token();
            if (auth_token == null) return null;
            return lastfm.get_auth_url(auth_token);
        }

        /**
         * Complete auth after user has granted access in browser.
         * Returns true on success.
         */
        public async bool complete_auth() {
            if (auth_token == null) return false;

            var result = yield lastfm.auth_get_session(auth_token);

            if (result != null) {
                auth_token = null;
                settings.set_string("lastfm-session-key", result);
                status_changed();
                return true;
            }
            return false;
        }

        /**
         * Disconnect from Last.fm.
         */
        public void disconnect_lastfm() {
            settings.set_string("lastfm-session-key", "");
            cancel_scrobble_timer();
            current_artist = null;
            current_title = null;
            status_changed();
        }

        private void on_metadata_changed(string title) {
            if (!is_enabled()) return;

            // Try to scrobble the previous track
            maybe_scrobble_current();

            // Extract artist/title from the new metadata
            var cleaned = extractor.clean(title);
            var info = extractor.extract_artist_title(cleaned);

            if (!info.is_song() || info.artist == null) {
                // Non-song or no artist — can't scrobble
                current_artist = null;
                current_title = null;
                cancel_scrobble_timer();
                return;
            }

            current_artist = info.artist;
            current_title = info.title;
            track_start_time = new DateTime.now_utc().to_unix();

            // Send Now Playing
            var sk = get_session_key();
            if (sk != null) {
                lastfm.update_now_playing.begin(current_artist, current_title, sk);
            }

            // Set timer for scrobble
            start_scrobble_timer();
        }

        private void on_state_changed(PlayerState new_state) {
            if (!is_enabled()) return;

            if (new_state == PlayerState.STOPPED || new_state == PlayerState.ERROR) {
                maybe_scrobble_current();
                current_artist = null;
                current_title = null;
                cancel_scrobble_timer();
            }
        }

        private void maybe_scrobble_current() {
            if (current_artist == null || current_title == null || track_start_time == 0) {
                return;
            }

            var now = new DateTime.now_utc().to_unix();
            var elapsed = now - track_start_time;
            if (elapsed >= SCROBBLE_THRESHOLD_SECONDS) {
                do_scrobble.begin(current_artist, current_title, track_start_time);
            }
        }

        private void start_scrobble_timer() {
            cancel_scrobble_timer();
            scrobble_timer = Timeout.add_seconds(SCROBBLE_THRESHOLD_SECONDS, () => {
                scrobble_timer = 0;
                if (current_artist != null && current_title != null) {
                    do_scrobble.begin(current_artist, current_title, track_start_time);
                }
                return false;
            });
        }

        private void cancel_scrobble_timer() {
            if (scrobble_timer > 0) {
                Source.remove(scrobble_timer);
                scrobble_timer = 0;
            }
        }

        private async void do_scrobble(string artist, string title, int64 timestamp) {
            var sk = get_session_key();
            if (sk == null) return;

            message("Scrobbling: %s - %s", artist, title);
            var response = yield lastfm.scrobble(artist, title, timestamp, sk);

            if (!response.ok) {
                // Error 9: invalid session — clear key
                if (response.error_code == 9) {
                    warning("Last.fm session invalid, disconnecting");
                    disconnect_lastfm();
                }
            }
        }

    }
}
