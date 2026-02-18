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

        // 1. Fetch watch page → player JS URL
        string? page = http_get (session, "https://www.youtube.com/watch?v=" + video_id);
        if (page == null) throw new IOError.FAILED ("Could not fetch watch page");

        string? player_url = null;
        var re = new Regex ("/s/player/[a-f0-9]+/[^\"]+base\\.js");
        MatchInfo mi;
        if (re.match (page, 0, out mi)) {
            player_url = "https://www.youtube.com" + mi.fetch (0);
        }
        if (player_url == null) throw new IOError.FAILED ("Could not find player JS URL");

        // 2. Download player JS → extract STS
        string? base_js = http_get (session, player_url);
        if (base_js == null) throw new IOError.FAILED ("Could not download player JS");

        string sts = "0";
        var re_sts = new Regex ("signatureTimestamp[=:]\\s*(\\d+)");
        if (re_sts.match (base_js, 0, out mi)) sts = mi.fetch (1);

        // 3. Call web_embedded API
        string api_body = """
        {
            "context": {
                "client": {
                    "clientName": "WEB_EMBEDDED_PLAYER",
                    "clientVersion": "1.20260115.01.00"
                },
                "thirdParty": { "embedUrl": "https://www.youtube.com/" }
            },
            "videoId": "%s",
            "playbackContext": {
                "contentPlaybackContext": { "signatureTimestamp": %s }
            }
        }
        """.printf (video_id, sts);

        var msg = new Soup.Message ("POST",
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false");
        msg.request_headers.append ("User-Agent", UA);
        msg.request_headers.append ("X-Youtube-Client-Name", "56");
        msg.request_headers.append ("X-Youtube-Client-Version", "1.20260115.01.00");
        msg.request_headers.append ("Origin", "https://www.youtube.com");
        msg.set_request_body_from_bytes ("application/json", new Bytes (api_body.data));

        var resp_bytes = session.send_and_read (msg, null);
        if (msg.status_code != 200)
            throw new IOError.FAILED ("API returned HTTP %u", msg.status_code);

        var parser = new Json.Parser ();
        parser.load_from_data ((string) resp_bytes.get_data ());
        var root = parser.get_root ().get_object ();

        // 4. Check playability
        if (root.has_member ("playabilityStatus")) {
            string status = root.get_object_member ("playabilityStatus")
                .get_string_member_with_default ("status", "");
            if (status != "OK") {
                string reason = root.get_object_member ("playabilityStatus")
                    .get_string_member_with_default ("reason", "unknown");
                throw new IOError.FAILED ("%s: %s", status, reason);
            }
        }

        // 5. Extract title
        string title = "video";
        if (root.has_member ("videoDetails")) {
            title = root.get_object_member ("videoDetails")
                .get_string_member_with_default ("title", "video");
        }

        // 6. Find itag 18
        string? raw_url = null;
        string? sig_cipher = null;

        if (root.has_member ("streamingData")) {
            var sd = root.get_object_member ("streamingData");
            if (sd.has_member ("formats")) {
                var formats = sd.get_array_member ("formats");
                for (uint i = 0; i < formats.get_length (); i++) {
                    var f = formats.get_object_element (i);
                    if ((int) f.get_int_member_with_default ("itag", 0) == 18) {
                        if (f.has_member ("url"))
                            raw_url = f.get_string_member ("url");
                        else if (f.has_member ("signatureCipher"))
                            sig_cipher = f.get_string_member ("signatureCipher");
                        break;
                    }
                }
            }
        }

        if (raw_url == null && sig_cipher == null)
            throw new IOError.FAILED ("itag 18 not found");

        // 7. Build download URL (decipher if needed)
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

        // Extract n-param
        string? n_param = null;
        try {
            var uri = GLib.Uri.parse (download_url, GLib.UriFlags.NONE);
            var q = uri.get_query ();
            if (q != null) {
                var qp = GLib.Uri.parse_params (q, -1, "&", GLib.UriParamsFlags.NONE);
                string? nv;
                if (qp.lookup_extended ("n", null, out nv)) n_param = nv;
            }
        } catch {}

        // 8. Solve JS challenges
        if (enc_sig != null || n_param != null) {
            string? solved_sig, solved_n;
            solve_challenges (base_js, enc_sig, n_param, out solved_sig, out solved_n);

            if (solved_sig != null)
                download_url += "&" + sp + "=" + GLib.Uri.escape_string (solved_sig, null, true);
            if (solved_n != null)
                download_url = replace_param (download_url, "n", solved_n);
        }

        return VideoInfo () { title = title, url = download_url, video_id = video_id };
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
