/**
 * ytdl — YouTube format extraction library
 *
 * Extracts a playable URL for itag 18 (360p muxed mp4) from YouTube.
 * Uses web_embedded API and JavaScriptCore for signatureCipher solving.
 */

namespace Ytdl {

    public struct VideoInfo {
        public string title;
        public string url;
        public string video_id;
        public string ext;
    }

    public struct SearchResult {
        public string video_id;
        public string title;
        public string channel;
    }

    /**
     * Search YouTube for videos matching a query.
     * Returns up to max_results results.
     */
    public SearchResult[] search (Soup.Session session, string query, int max_results = 5) throws Error {

        string url = "https://www.youtube.com/results?search_query="
            + GLib.Uri.escape_string (query, null, true);

        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("User-Agent", UA);
        msg.request_headers.append ("Accept-Language", "en-US,en;q=0.9");

        var bytes = session.send_and_read (msg, null);
        if (msg.status_code != 200)
            throw new IOError.FAILED ("Search returned HTTP %u", msg.status_code);

        string html = (string) bytes.get_data ();

        // Extract ytInitialData JSON
        string? json_str = null;
        try {
            var re = new Regex ("ytInitialData\\s*=\\s*");
            MatchInfo mi;
            if (re.match (html, 0, out mi)) {
                int start, end;
                mi.fetch_pos (0, out start, out end);
                json_str = extract_json_object (html, end);
            }
        } catch {}

        if (json_str == null)
            throw new IOError.FAILED ("Could not find ytInitialData");

        var parser = new Json.Parser ();
        parser.load_from_data (json_str);
        var root = parser.get_root ().get_object ();

        // Navigate: contents → twoColumnSearchResultsRenderer → primaryContents
        //   → sectionListRenderer → contents[] → itemSectionRenderer → contents[]
        var results = new GenericArray<SearchResult?> ();

        if (!root.has_member ("contents")) return new SearchResult[0];
        var c1 = root.get_object_member ("contents");
        if (!c1.has_member ("twoColumnSearchResultsRenderer")) return new SearchResult[0];
        var c2 = c1.get_object_member ("twoColumnSearchResultsRenderer");
        if (!c2.has_member ("primaryContents")) return new SearchResult[0];
        var c3 = c2.get_object_member ("primaryContents");
        if (!c3.has_member ("sectionListRenderer")) return new SearchResult[0];
        var sections = c3.get_object_member ("sectionListRenderer").get_array_member ("contents");

        for (uint si = 0; si < sections.get_length () && results.length < max_results; si++) {
            var section = sections.get_object_element (si);
            if (!section.has_member ("itemSectionRenderer")) continue;
            var items = section.get_object_member ("itemSectionRenderer").get_array_member ("contents");

            for (uint ii = 0; ii < items.get_length () && results.length < max_results; ii++) {
                var item = items.get_object_element (ii);
                if (!item.has_member ("videoRenderer")) continue;
                var vr = item.get_object_member ("videoRenderer");

                var r = SearchResult ();
                r.video_id = vr.get_string_member_with_default ("videoId", "");
                if (r.video_id == "") continue;

                // Title from title.runs[0].text
                if (vr.has_member ("title")) {
                    var runs = vr.get_object_member ("title").get_array_member ("runs");
                    if (runs.get_length () > 0)
                        r.title = runs.get_object_element (0).get_string_member_with_default ("text", "");
                }

                // Channel from ownerText.runs[0].text
                if (vr.has_member ("ownerText")) {
                    var runs = vr.get_object_member ("ownerText").get_array_member ("runs");
                    if (runs.get_length () > 0)
                        r.channel = runs.get_object_element (0).get_string_member_with_default ("text", "");
                }

                results.add (r);
            }
        }

        var arr = new SearchResult[results.length];
        for (int i = 0; i < results.length; i++) arr[i] = results[i];
        return arr;
    }

    /**
     * Extract a balanced JSON object starting at pos in text.
     */
    private string? extract_json_object (string text, int start) {
        if (start >= text.length || text[start] != '{') return null;
        int depth = 0;
        bool in_str = false, escaped = false;

        for (int i = start; i < text.length; i++) {
            char c = text[i];
            if (escaped) { escaped = false; continue; }
            if (c == '\\' && in_str) { escaped = true; continue; }
            if (c == '"') { in_str = !in_str; continue; }
            if (!in_str) {
                if (c == '{') depth++;
                else if (c == '}') { depth--; if (depth == 0) return text.substring (start, i - start + 1); }
            }
        }
        return null;
    }

    private const string UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

    /**
     * Extract a playable download URL for a YouTube video.
     * Returns a VideoInfo with title and direct download URL.
     * Throws on any failure.
     */
    public VideoInfo extract (Soup.Session session, string video_id_or_url) throws Error {
        string video_id = parse_video_id (video_id_or_url);

        // 1. Fetch watch page
        string? page = http_get (session, "https://www.youtube.com/watch?v=" + video_id);
        if (page == null) throw new IOError.FAILED ("Could not fetch watch page");

        MatchInfo mi;

        // Visitor data ties API calls to a browsing session; without it
        // non-web clients are rejected with a "confirm you're not a bot" check.
        string? visitor_data = null;
        var re_vd = new Regex ("\"visitorData\"\\s*:\\s*\"([^\"]+)\"");
        if (re_vd.match (page, 0, out mi))
            visitor_data = mi.fetch (1).replace ("\\u003d", "=");

        // 2. Locate the player JS. It is only downloaded if a web client is
        //    actually attempted (signatureTimestamp + sig/n challenge solving);
        //    non-web clients return ready-to-use URLs.
        string? player_js_path = null;
        var re_js = new Regex ("/s/player/[a-f0-9]+/[^\"]+(?:base|tv-player-ias)\\.js");
        if (re_js.match (page, 0, out mi))
            player_js_path = mi.fetch (0);
        string? base_js = null;
        string sts = "0";

        // 3. Try API clients in order until one yields a usable format:
        //    ANDROID_VR — no PO-token requirement, still serves muxed itag 18
        //    WEB_EMBEDDED_PLAYER — muxed itag 18 for embeddable videos
        //    IOS — direct adaptive URLs (downloads may be range-restricted)
        //    WEB — last resort; usually returns SABR-only responses with no URLs
        ApiClient[] clients = {
            { "ANDROID_VR", "1.65.10", "28", ANDROID_VR_UA,
              ",\"deviceMake\": \"Oculus\",\"deviceModel\": \"Quest 3\",\"androidSdkVersion\": 32,\"userAgent\": \"" + ANDROID_VR_UA + "\",\"osName\": \"Android\",\"osVersion\": \"12L\"",
              null, false },
            { "WEB_EMBEDDED_PLAYER", "1.20260115.01.00", "56", null, null,
              ",\"thirdParty\": { \"embedUrl\": \"https://www.youtube.com/\" }", true },
            { "IOS", "21.02.3", "5", IOS_UA,
              ",\"deviceMake\": \"Apple\",\"deviceModel\": \"iPhone16,2\",\"userAgent\": \"" + IOS_UA + "\",\"osName\": \"iPhone\",\"osVersion\": \"18.3.2.22D82\"",
              null, false },
            { "WEB", "2.20260115.01.00", "1", null, null, null, true },
        };

        string title = "video";
        string? raw_url = null;
        string? sig_cipher = null;
        string ext = "mp4";
        bool web_client = true;
        Error? last_err = null;

        foreach (var client in clients) {
            if (client.is_web && base_js == null) {
                if (player_js_path == null) continue;
                base_js = http_get (session, "https://www.youtube.com" + player_js_path);
                if (base_js == null) {
                    player_js_path = null;  // don't retry for later web clients
                    continue;
                }
                var re_sts = new Regex ("signatureTimestamp[=:]\\s*(\\d+)");
                if (re_sts.match (base_js, 0, out mi)) sts = mi.fetch (1);
            }

            Json.Object root;
            try {
                root = call_player_api (session, video_id, sts, visitor_data, client);
            } catch (Error e) {
                last_err = e;
                continue;
            }

            // Pick a format: itag 18 (360p muxed mp4) if still available,
            // else itag 140 (m4a audio) — YouTube dropped muxed formats
            // from most videos, leaving only separate audio/video streams.
            if (!root.has_member ("streamingData")) continue;
            var sd = root.get_object_member ("streamingData");
            if (sd.has_member ("formats")
                && pick_itag (sd.get_array_member ("formats"), 18, out raw_url, out sig_cipher)) {
                ext = "mp4";
            } else if (sd.has_member ("adaptiveFormats")
                && pick_itag (sd.get_array_member ("adaptiveFormats"), 140, out raw_url, out sig_cipher)) {
                ext = "m4a";
            } else {
                continue;  // response has no usable URLs (e.g. SABR-only)
            }

            web_client = client.is_web;
            if (root.has_member ("videoDetails")) {
                title = root.get_object_member ("videoDetails")
                    .get_string_member_with_default ("title", "video");
            }
            break;
        }

        if (raw_url == null && sig_cipher == null)
            throw last_err ?? new IOError.FAILED ("No playable format found (itag 18 or 140)");

        // 4. Build download URL (decipher if needed)
        string download_url;
        string? enc_sig = null;
        string sp = "signature";

        if (raw_url != null) {
            download_url = raw_url;
        } else {
            var sc = GLib.Uri.parse_params (sig_cipher, -1, "&", GLib.UriParamsFlags.NONE);
            string? v;
            if (sc.lookup_extended ("s", null, out v))   enc_sig = GLib.Uri.unescape_string (v);
            if (sc.lookup_extended ("sp", null, out v))  sp = v;
            if (sc.lookup_extended ("url", null, out v)) download_url = GLib.Uri.unescape_string (v);
            else throw new IOError.FAILED ("No URL in signatureCipher");
        }

        // Extract n-param (throttling challenge — only applies to web clients)
        string? n_param = null;
        if (web_client) try {
            var uri = GLib.Uri.parse (download_url, GLib.UriFlags.NONE);
            var q = uri.get_query ();
            if (q != null) {
                var qp = GLib.Uri.parse_params (q, -1, "&", GLib.UriParamsFlags.NONE);
                string? nv;
                if (qp.lookup_extended ("n", null, out nv)) n_param = nv;
            }
        } catch {}

        // 5. Solve JS challenges (web-client URLs only; base_js is set
        //    whenever a web client produced the chosen format)
        if (base_js != null && (enc_sig != null || n_param != null)) {
            string? solved_sig, solved_n;
            solve_challenges (base_js, enc_sig, n_param, out solved_sig, out solved_n);

            if (solved_sig != null)
                download_url += "&" + sp + "=" + GLib.Uri.escape_string (solved_sig, null, true);
            if (solved_n != null)
                download_url = replace_param (download_url, "n", solved_n);
        }

        return VideoInfo () { title = title, url = download_url, video_id = video_id, ext = ext };
    }

    public delegate void ProgressFunc (int64 received, int64 total);

    /**
     * Download a media URL to out_stream in ranged chunks.
     * googlevideo rejects unranged full-file GETs and Range requests larger
     * than ~1 MiB (HTTP 403), so the file is requested as a sequence of
     * 1 MiB Range requests.
     */
    public void download (Soup.Session session, string url, OutputStream out_stream,
                          Cancellable? cancellable = null,
                          ProgressFunc? progress = null) throws Error {
        const int64 CHUNK = 1024 * 1024;
        int64 total = -1;
        int64 received = 0;
        uint8[] buffer = new uint8[65536];

        while (total < 0 || received < total) {
            var msg = new Soup.Message ("GET", url);
            msg.request_headers.append ("User-Agent", UA);
            msg.request_headers.set_range (received, received + CHUNK - 1);

            var stream = session.send (msg, cancellable);
            if (msg.status_code != 206 && msg.status_code != 200)
                throw new IOError.FAILED ("HTTP %u", msg.status_code);

            if (total < 0) {
                int64 rs, re;
                if (msg.status_code == 206
                    && msg.response_headers.get_content_range (out rs, out re, out total)) {
                    // total set from Content-Range
                } else {
                    total = msg.response_headers.get_content_length ();
                }
            }

            int64 chunk_got = 0;
            ssize_t n;
            while ((n = stream.read (buffer, cancellable)) > 0) {
                out_stream.write (buffer[0:n], cancellable);
                received += n;
                chunk_got += n;
                if (progress != null) progress (received, total);
            }
            stream.close (cancellable);

            // 200 means the server sent the whole file; empty chunk means
            // the size was unknown and we've read past the end.
            if (msg.status_code == 200 || chunk_got == 0) break;
        }
    }

    /**
     * Parse a video ID from a URL or plain ID string.
     */
    public string parse_video_id (string input) throws Error {
        if (/^[A-Za-z0-9_-]{11}$/.match (input)) return input;

        MatchInfo mi;
        var re1 = new Regex ("(?:v=|/(?:embed|shorts|v)/)([A-Za-z0-9_-]{11})");
        if (re1.match (input, 0, out mi)) return mi.fetch (1);

        var re2 = new Regex ("youtu\\.be/([A-Za-z0-9_-]{11})");
        if (re2.match (input, 0, out mi)) return mi.fetch (1);

        throw new IOError.FAILED ("Could not parse video ID from '%s'", input);
    }

    // ── Private helpers ──

    private struct ApiClient {
        string name;
        string version;
        string id;
        string? user_agent;   // null → desktop browser UA
        string? device_json;  // extra fields inside context.client
        string? extra_json;   // extra fields inside context
        bool is_web;          // needs signatureTimestamp + sig/n solving
    }

    private bool pick_itag (Json.Array formats, int itag,
                            out string? raw_url, out string? sig_cipher) {
        raw_url = null;
        sig_cipher = null;
        for (uint i = 0; i < formats.get_length (); i++) {
            var f = formats.get_object_element (i);
            if ((int) f.get_int_member_with_default ("itag", 0) == itag) {
                if (f.has_member ("url"))
                    raw_url = f.get_string_member ("url");
                else if (f.has_member ("signatureCipher"))
                    sig_cipher = f.get_string_member ("signatureCipher");
                return raw_url != null || sig_cipher != null;
            }
        }
        return false;
    }

    private const string IOS_UA = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    private const string ANDROID_VR_UA = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

    private Json.Object call_player_api (Soup.Session session, string video_id,
                                          string sts, string? visitor_data,
                                          ApiClient client) throws Error {
        var client_obj = new StringBuilder ();
        client_obj.append_printf ("\"clientName\": \"%s\",\"clientVersion\": \"%s\"",
                                  client.name, client.version);
        if (client.device_json != null) client_obj.append (client.device_json);
        if (visitor_data != null)
            client_obj.append_printf (",\"visitorData\": \"%s\"", visitor_data);

        // Web clients need the player's signatureTimestamp to get valid ciphers
        string playback_part = client.is_web
            ? ",\"playbackContext\": { \"contentPlaybackContext\": { \"signatureTimestamp\": %s } }".printf (sts)
            : "";

        string api_body = "{\"context\": {\"client\": {%s}%s},\"videoId\": \"%s\"%s}".printf (
            client_obj.str, client.extra_json ?? "", video_id, playback_part);

        var msg = new Soup.Message ("POST",
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false");
        msg.request_headers.append ("User-Agent", client.user_agent ?? UA);
        msg.request_headers.append ("X-Youtube-Client-Name", client.id);
        msg.request_headers.append ("X-Youtube-Client-Version", client.version);
        msg.request_headers.append ("Origin", "https://www.youtube.com");
        if (visitor_data != null)
            msg.request_headers.append ("X-Goog-Visitor-Id", visitor_data);
        msg.set_request_body_from_bytes ("application/json", new Bytes (api_body.data));

        var resp_bytes = session.send_and_read (msg, null);
        if (msg.status_code != 200)
            throw new IOError.FAILED ("%s: HTTP %u", client.name, msg.status_code);

        var parser = new Json.Parser ();
        parser.load_from_data ((string) resp_bytes.get_data ());
        var root = parser.get_root ().get_object ();

        if (root.has_member ("playabilityStatus")) {
            string status = root.get_object_member ("playabilityStatus")
                .get_string_member_with_default ("status", "");
            if (status != "OK") {
                string reason = root.get_object_member ("playabilityStatus")
                    .get_string_member_with_default ("reason", "unknown");
                throw new IOError.FAILED ("%s: %s", status, reason);
            }
        }

        return root;
    }

    private string? http_get (Soup.Session session, string url) {
        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("User-Agent", UA);
        try {
            var bytes = session.send_and_read (msg, null);
            if (msg.status_code == 200) return (string) bytes.get_data ();
        } catch {}
        return null;
    }

    private void solve_challenges (string base_js, string? enc_sig, string? n_param,
                                   out string? solved_sig, out string? solved_n) throws Error {
        solved_sig = null;
        solved_n = null;
        if (enc_sig == null && n_param == null) return;

        // Load solver JS from embedded GResource
        var lib_bytes = resources_lookup_data ("/org/ytdl/yt.solver.lib.js", ResourceLookupFlags.NONE);
        var core_bytes = resources_lookup_data ("/org/ytdl/yt.solver.core.js", ResourceLookupFlags.NONE);
        string lib_js = (string) lib_bytes.get_data ();
        string core_js = (string) core_bytes.get_data ();

        // Build solver input JSON
        var b = new Json.Builder ();
        b.begin_object ();
        b.set_member_name ("type"); b.add_string_value ("player");
        b.set_member_name ("player"); b.add_string_value (base_js);
        b.set_member_name ("requests"); b.begin_array ();
        if (enc_sig != null) {
            b.begin_object ();
            b.set_member_name ("type"); b.add_string_value ("sig");
            b.set_member_name ("challenges");
            b.begin_array (); b.add_string_value (enc_sig); b.end_array ();
            b.end_object ();
        }
        if (n_param != null) {
            b.begin_object ();
            b.set_member_name ("type"); b.add_string_value ("n");
            b.set_member_name ("challenges");
            b.begin_array (); b.add_string_value (n_param); b.end_array ();
            b.end_object ();
        }
        b.end_array (); b.end_object ();
        var gen = new Json.Generator ();
        gen.set_root (b.get_root ());
        string input_json = gen.to_data (null);

        // Execute in JavaScriptCore (single concatenated script)
        var js = new StringBuilder ();
        js.append (lib_js);
        js.append ("\nObject.assign(globalThis, lib);\n");
        js.append (core_js);
        js.append ("\nvar _r = JSON.stringify(jsc(");
        js.append (input_json);
        js.append ("));\n_r;\n");

        var ctx = new JSC.Context ();
        var result = ctx.evaluate (js.str, js.len);

        var ex = ctx.get_exception ();
        if (ex != null) throw new IOError.FAILED ("JS error: %s", ex.get_message ());
        if (result.is_undefined () || result.is_null ())
            throw new IOError.FAILED ("JS solver returned null");

        // Parse result
        var p = new Json.Parser ();
        p.load_from_data (result.to_string ());
        var robj = p.get_root ().get_object ();
        if (robj.get_string_member_with_default ("type", "") != "result")
            throw new IOError.FAILED ("JS solver error");

        var responses = robj.get_array_member ("responses");
        int idx = 0;

        if (enc_sig != null && idx < responses.get_length ()) {
            var r = responses.get_object_element (idx);
            if (r.get_string_member_with_default ("type", "") == "result")
                solved_sig = r.get_object_member ("data").get_string_member (enc_sig);
            idx++;
        }
        if (n_param != null && idx < responses.get_length ()) {
            var r = responses.get_object_element (idx);
            if (r.get_string_member_with_default ("type", "") == "result")
                solved_n = r.get_object_member ("data").get_string_member (n_param);
        }
    }

    private string replace_param (string url, string param, string val) {
        foreach (string pfx in new string[] { "&" + param + "=", "?" + param + "=" }) {
            int i = url.index_of (pfx);
            if (i >= 0) {
                int vs = i + pfx.length;
                int ve = url.index_of ("&", vs);
                if (ve < 0) return url.substring (0, vs) + val;
                return url.substring (0, vs) + val + url.substring (ve);
            }
        }
        return url + "&" + param + "=" + val;
    }
}
