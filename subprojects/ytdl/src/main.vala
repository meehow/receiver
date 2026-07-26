int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");

    var session = new Soup.Session ();
    session.timeout = 30;

    // Pull out the --audio/-a flag; keep the rest as positional args.
    // With it, downloads use the itag 140 (m4a) audio-only stream.
    bool audio_only = false;
    string[] pos = {};
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--audio" || args[i] == "-a")
            audio_only = true;
        else
            pos += args[i];
    }

    if (pos.length < 1) {
        printerr ("Usage: %s [--audio] <video-id-or-url>\n", args[0]);
        printerr ("       %s --search <query>\n", args[0]);
        return 1;
    }

    try {
        // Search mode
        if (pos[0] == "--search" || pos[0] == "-s") {
            if (pos.length < 2) {
                printerr ("Usage: %s --search <query>\n", args[0]);
                return 1;
            }
            // Join remaining args as query
            string query = string.joinv (" ", pos[1:pos.length]);
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
        var info = Ytdl.extract (session, pos[0], audio_only);

        string filename = sanitize (info.title) + "." + info.ext;
        print ("Downloading: %s\n", info.title);
        print ("File: %s\n\n", filename);

        var fos = File.new_for_path (filename)
            .replace (null, false, FileCreateFlags.REPLACE_DESTINATION, null);

        Ytdl.download (session, info.url, fos, null, (done, total) => {
            if (total > 0)
                print ("\r  %.0f%%  %.1f / %.1f MB",
                    (double) done / total * 100, done / 1048576.0, total / 1048576.0);
        });
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
