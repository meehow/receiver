/**
 * ytdl — YouTube format extraction library
 *
 * Extracts a playable URL for itag 18 (360p muxed mp4) or itag 140
 * (m4a audio) from YouTube via non-web innertube clients, which return
 * direct URLs without sig/n JS challenges or PO tokens.
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
        // the clients are rejected with a "confirm you're not a bot" check.
        string? visitor_data = null;
        var re_vd = new Regex ("\"visitorData\"\\s*:\\s*\"([^\"]+)\"");
        if (re_vd.match (page, 0, out mi))
            visitor_data = mi.fetch (1).replace ("\\u003d", "=");

        // 2. Try API clients in order until one yields a usable format.
        //    Only non-web clients: they return direct URLs without sig/n JS
        //    challenges (web clients now return SABR-only responses anyway).
        //    ANDROID_VR — no PO-token requirement, still serves muxed itag 18
        //    IOS — direct adaptive URLs (downloads may be range-restricted)
        ApiClient[] clients = {
            { "ANDROID_VR", "1.65.10", "28", ANDROID_VR_UA,
              ",\"deviceMake\": \"Oculus\",\"deviceModel\": \"Quest 3\",\"androidSdkVersion\": 32,\"userAgent\": \"" + ANDROID_VR_UA + "\",\"osName\": \"Android\",\"osVersion\": \"12L\"" },
            { "IOS", "21.02.3", "5", IOS_UA,
              ",\"deviceMake\": \"Apple\",\"deviceModel\": \"iPhone16,2\",\"userAgent\": \"" + IOS_UA + "\",\"osName\": \"iPhone\",\"osVersion\": \"18.3.2.22D82\"" },
        };

        string title = "video";
        string? url = null;
        string ext = "mp4";
        Error? last_err = null;

        foreach (var client in clients) {
            Json.Object root;
            try {
                root = call_player_api (session, video_id, visitor_data, client);
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
                && (url = pick_itag (sd.get_array_member ("formats"), 18)) != null) {
                ext = "mp4";
            } else if (sd.has_member ("adaptiveFormats")
                && (url = pick_itag (sd.get_array_member ("adaptiveFormats"), 140)) != null) {
                ext = "m4a";
            } else {
                continue;  // response has no usable direct URLs
            }

            if (root.has_member ("videoDetails")) {
                title = root.get_object_member ("videoDetails")
                    .get_string_member_with_default ("title", "video");
            }
            break;
        }

        if (url == null)
            throw last_err ?? new IOError.FAILED ("No playable format found (itag 18 or 140)");

        return VideoInfo () { title = title, url = url, video_id = video_id, ext = ext };
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
        string user_agent;
        string device_json;  // extra fields inside context.client
    }

    private string? pick_itag (Json.Array formats, int itag) {
        for (uint i = 0; i < formats.get_length (); i++) {
            var f = formats.get_object_element (i);
            if ((int) f.get_int_member_with_default ("itag", 0) == itag)
                return f.has_member ("url") ? f.get_string_member ("url") : null;
        }
        return null;
    }

    private const string IOS_UA = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    private const string ANDROID_VR_UA = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

    private Json.Object call_player_api (Soup.Session session, string video_id,
                                          string? visitor_data,
                                          ApiClient client) throws Error {
        var client_obj = new StringBuilder ();
        client_obj.append_printf ("\"clientName\": \"%s\",\"clientVersion\": \"%s\"",
                                  client.name, client.version);
        client_obj.append (client.device_json);
        if (visitor_data != null)
            client_obj.append_printf (",\"visitorData\": \"%s\"", visitor_data);

        string api_body = "{\"context\": {\"client\": {%s}},\"videoId\": \"%s\"}".printf (
            client_obj.str, video_id);

        var msg = new Soup.Message ("POST",
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false");
        msg.request_headers.append ("User-Agent", client.user_agent);
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
}
