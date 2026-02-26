// Last.fm API client for desktop authentication and scrobbling
namespace Receiver {

    private const string LASTFM_API_URL = "http://ws.audioscrobbler.com/2.0/";
    private const string LASTFM_API_KEY = "83f81327ea8f83f4becbc8fa1255611d";
    private const string LASTFM_API_SECRET = "037b74525c3c6ce5a5535ee04fa58a27";
    private const string LASTFM_AUTH_URL = "https://www.last.fm/api/auth/?api_key=" + LASTFM_API_KEY + "&token=";

    // Last.fm API response
    public struct LastfmResponse {
        public bool ok;
        public int error_code;
        public string? error_message;
        public string? body;
    }

    public class LastfmService : Object {
        private Soup.Session session;

        public LastfmService() {
            session = new Soup.Session();
            session.timeout = 15;
        }

        /**
         * Generate MD5 API method signature.
         * Sort params alphabetically, concatenate name+value, append secret, MD5.
         */
        private string sign(HashTable<string, string> params) {
            var keys = new GenericArray<string>();
            params.foreach((k, v) => {
                keys.add(k);
            });
            keys.sort(strcmp);

            var sb = new StringBuilder();
            for (int i = 0; i < keys.length; i++) {
                sb.append(keys[i]);
                sb.append(params[keys[i]]);
            }
            sb.append(LASTFM_API_SECRET);

            return Checksum.compute_for_string(ChecksumType.MD5, sb.str);
        }

        /**
         * Step 1: Get a request token for desktop auth.
         */
        public async string? auth_get_token() {
            var params = new HashTable<string, string>(str_hash, str_equal);
            params["method"] = "auth.getToken";
            params["api_key"] = LASTFM_API_KEY;

            var sig = sign(params);
            var url = LASTFM_API_URL + "?method=auth.getToken&api_key=" + LASTFM_API_KEY + "&api_sig=" + sig;

            try {
                var msg = new Soup.Message("GET", url);
                var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, null);
                var body = (string) bytes.get_data();

                // Parse <token>xxx</token>
                var start = body.index_of("<token>");
                var end = body.index_of("</token>");
                if (start >= 0 && end > start) {
                    return body.substring(start + 7, end - start - 7);
                }
                warning("Last.fm auth.getToken: unexpected response: %s", body);
            } catch (Error e) {
                warning("Last.fm auth.getToken failed: %s", e.message);
            }
            return null;
        }

        /**
         * Get the URL to open in the browser for user authorization.
         */
        public string get_auth_url(string token) {
            return LASTFM_AUTH_URL + token;
        }

        /**
         * Step 3: Exchange token for a session key after user authorizes.
         * Returns "username:session_key" or null on failure.
         */
        public async string? auth_get_session(string token) {
            var params = new HashTable<string, string>(str_hash, str_equal);
            params["method"] = "auth.getSession";
            params["api_key"] = LASTFM_API_KEY;
            params["token"] = token;

            var sig = sign(params);
            var url = "%s?method=auth.getSession&api_key=%s&token=%s&api_sig=%s".printf(
                LASTFM_API_URL, LASTFM_API_KEY, token, sig);

            try {
                var msg = new Soup.Message("GET", url);
                var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, null);
                var body = (string) bytes.get_data();

                // Check for error
                if (body.contains("<error")) {
                    // Error 14 = token not authorized yet (expected during polling)
                    if (!body.contains("code=\"14\"")) {
                        warning("Last.fm auth.getSession error: %s", body);
                    }
                    return null;
                }

                // Parse <session><key>xxx</key></session>
                string? key = extract_xml_value(body, "key");
                if (key != null) {
                    return key;
                }
                warning("Last.fm auth.getSession: unexpected response: %s", body);
            } catch (Error e) {
                warning("Last.fm auth.getSession failed: %s", e.message);
            }
            return null;
        }

        /**
         * Send track.updateNowPlaying — fire and forget.
         */
        public async void update_now_playing(string artist, string track, string session_key) {
            var params = new HashTable<string, string>(str_hash, str_equal);
            params["method"] = "track.updateNowPlaying";
            params["api_key"] = LASTFM_API_KEY;
            params["sk"] = session_key;
            params["artist"] = artist;
            params["track"] = track;

            var sig = sign(params);
            params["api_sig"] = sig;

            yield post_request(params, "updateNowPlaying");
        }

        /**
         * Send track.scrobble for a single track.
         */
        public async LastfmResponse scrobble(string artist, string track, int64 timestamp, string session_key) {
            var params = new HashTable<string, string>(str_hash, str_equal);
            params["method"] = "track.scrobble";
            params["api_key"] = LASTFM_API_KEY;
            params["sk"] = session_key;
            params["artist[0]"] = artist;
            params["track[0]"] = track;
            params["timestamp[0]"] = timestamp.to_string();
            params["chosenByUser[0]"] = "0";  // Radio stream

            var sig = sign(params);
            params["api_sig"] = sig;

            return yield post_request(params, "scrobble");
        }

        private async LastfmResponse post_request(HashTable<string, string> params, string label) {
            LastfmResponse result = { false, 0, null, null };

            try {
                var msg = new Soup.Message("POST", LASTFM_API_URL);

                // Build form data
                var sb = new StringBuilder();
                bool first = true;
                params.foreach((k, v) => {
                    if (!first) sb.append("&");
                    sb.append(Uri.escape_string(k, null, true));
                    sb.append("=");
                    sb.append(Uri.escape_string(v, null, true));
                    first = false;
                });

                msg.set_request_body_from_bytes(
                    "application/x-www-form-urlencoded",
                    new Bytes.take(sb.str.data));

                var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, null);
                result.body = (string) bytes.get_data();

                if (result.body.contains("status=\"ok\"")) {
                    result.ok = true;
                    message("Last.fm %s: ok", label);
                } else {
                    // Parse error code
                    var code_str = extract_xml_attr(result.body, "error", "code");
                    if (code_str != null) {
                        result.error_code = int.parse(code_str);
                    }
                    result.error_message = extract_xml_value(result.body, "error");
                    warning("Last.fm %s failed (code %d): %s", label, result.error_code,
                            result.error_message ?? "unknown");
                }
            } catch (Error e) {
                result.error_message = e.message;
                warning("Last.fm %s error: %s", label, e.message);
            }
            return result;
        }

        private string? extract_xml_value(string xml, string tag) {
            var open = "<%s>".printf(tag);
            var close = "</%s>".printf(tag);
            var start = xml.index_of(open);
            var end = xml.index_of(close);
            if (start >= 0 && end > start) {
                return xml.substring(start + open.length, end - start - open.length);
            }
            return null;
        }

        private string? extract_xml_attr(string xml, string tag, string attr) {
            // Find e.g. <error code="6">
            var pattern = "<%s %s=\"".printf(tag, attr);
            var start = xml.index_of(pattern);
            if (start >= 0) {
                start += pattern.length;
                var end = xml.index_of("\"", start);
                if (end > start) {
                    return xml.substring(start, end - start);
                }
            }
            return null;
        }
    }
}
