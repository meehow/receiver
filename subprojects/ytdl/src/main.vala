int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");

    var session = new Soup.Session ();
    session.timeout = 30;

    if (args.length < 2) {
        printerr ("Usage: %s <video-id-or-url>\n", args[0]);
        printerr ("       %s --search <query>\n", args[0]);
        return 1;
    }

    try {
        // Search mode
        if (args[1] == "--search" || args[1] == "-s") {
            if (args.length < 3) {
                printerr ("Usage: %s --search <query>\n", args[0]);
                return 1;
            }
            // Join remaining args as query
            string query = string.joinv (" ", args[2:args.length]);
            var results = Ytdl.search (session, query);

            if (results.length == 0) {
                printerr ("No results found.\n");
                return 1;
            }

            for (int i = 0; i < results.length; i++) {
                print ("%d. %s — %s [%s]\n",
                    i + 1, results[i].title, results[i].channel, results[i].video_id);
            }
            return 0;
        }

        // Download mode
        var info = Ytdl.extract (session, args[1]);

        string filename = sanitize (info.title) + ".mp4";
        print ("Downloading: %s\n", info.title);
        print ("File: %s\n\n", filename);

        var msg = new Soup.Message ("GET", info.url);
        msg.request_headers.append ("User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");

        var input = session.send (msg, null);
        if (msg.status_code != 200) {
            printerr ("HTTP %u\n", msg.status_code);
            return 1;
        }

        int64 total = msg.response_headers.get_content_length ();
        var fos = File.new_for_path (filename)
            .replace (null, false, FileCreateFlags.REPLACE_DESTINATION, null);

        uint8[] buf = new uint8[65536];
        int64 done = 0;
        ssize_t n;
        while ((n = input.read (buf, null)) > 0) {
            fos.write (buf[0:n], null);
            done += n;
            if (total > 0)
                print ("\r  %.0f%%  %.1f / %.1f MB",
                    (double) done / total * 100, done / 1048576.0, total / 1048576.0);
        }
        fos.close (null);

        print ("\n✓ %s\n", filename);
        return 0;

    } catch (Error e) {
        printerr ("Error: %s\n", e.message);
        return 1;
    }
}

string sanitize (string name) {
    var sb = new StringBuilder ();
    unichar c; int i = 0;
    while (name.get_next_char (ref i, out c)) {
        if (c == '/' || c == '\\' || c == ':' || c == '"' ||
            c == '<' || c == '>' || c == '|' || c == '?' || c == '*')
            sb.append_unichar ('_');
        else
            sb.append_unichar (c);
    }
    return sb.str.strip ();
}
