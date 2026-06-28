/*
 * Receiver TUI — ncurses frontend over libreceiver-core.
 *
 * Three views (Browse / Favourites / History) over the shared StationStore,
 * AppState favourites and HistoryStore, driving the shared Player. Curses runs
 * as a guest of the GLib main loop so the core's async GStreamer/Soup work keeps
 * ticking; stdin is read non-blocking, repaints are coalesced, and the terminal
 * is always restored on exit.
 */
namespace Receiver {

    public enum View {
        BROWSE, FAVOURITES, HISTORY;

        public const int COUNT = 3;

        public string label () {
            switch (this) {
                case BROWSE: return "Browse";
                case FAVOURITES: return "Favourites";
                case HISTORY: return "History";
                default: return "";
            }
        }
    }

    public enum PickerMode {
        NONE, COUNTRY, LANGUAGE
    }

    public class Tui : Object, MprisHost {
        // Signal numbers (the GLib profile has no Posix.Signal binding).
        private const int SIGNAL_INT = 2;
        private const int SIGNAL_TERM = 15;

        // Colour pair ids.
        private const int PAIR_HEADER = 1;
        private const int PAIR_STATUS = 2;

        private const double VOLUME_STEP = 0.05;

        // Keeps core log messages from corrupting the curses screen.
        private static FileStream? log_stream;

        private MainLoop loop = new MainLoop ();
        private unowned Curses.Window scr;
        private IOChannel stdin_channel;
        private bool needs_redraw = true;

        private StationStore store = new StationStore ();
        private Player player = new Player ();
        private MprisService mpris;

        private View view = View.BROWSE;
        // Cursor and scroll position, remembered per view.
        private int selected = 0;
        private int scroll = 0;
        private int[] saved_sel = { 0, 0, 0 };
        private int[] saved_off = { 0, 0, 0 };

        private bool search_active = false;
        private string search_text = "";

        // Country/language filter (Browse only). Labels are shown in the header;
        // the empty string means "all" (no filter).
        private string country_label = "";
        private string language_label = "";

        // Popup picker state for choosing a country/language.
        private PickerMode picker = PickerMode.NONE;
        private string[] picker_labels = {};
        private string[] picker_values = {};
        private string picker_query = "";
        private int picker_sel = 0;
        private int picker_off = 0;

        public int run () {
            Intl.setlocale (LocaleCategory.ALL, "");

            if (PosixExtras.isatty (0) == 0 || PosixExtras.isatty (1) == 0) {
                stderr.printf ("receiver-tui requires an interactive terminal.\n");
                return 1;
            }

            wire_core ();

            // Persist player + filter state via GSettings, shared with the GTK app.
            var settings = AppState.get_default ().settings;
            settings.bind ("volume", player, "volume", SettingsBindFlags.DEFAULT);
            settings.bind ("language-filter", store, "language-filter", SettingsBindFlags.DEFAULT);
            settings.bind ("country-filter", store, "country-filter", SettingsBindFlags.DEFAULT);

            load_database ();
            sync_filter_labels ();
            restore_last_station ();

            // Register MPRIS so desktop media keys control playback.
            mpris = new MprisService (this, player);

            init_screen ();

            Unix.signal_add (SIGNAL_INT, () => { loop.quit (); return Source.REMOVE; });
            Unix.signal_add (SIGNAL_TERM, () => { loop.quit (); return Source.REMOVE; });

            stdin_channel = new IOChannel.unix_new (0);
            stdin_channel.add_watch (IOCondition.IN, on_input);

            render ();
            needs_redraw = false;
            Timeout.add (33, () => {
                if (needs_redraw) {
                    render ();
                    needs_redraw = false;
                }
                return Source.CONTINUE;
            });

            loop.run ();

            AppState.get_default ().flush ();
            Curses.endwin ();
            return 0;
        }

        private void wire_core () {
            store.items_changed.connect (() => {
                clamp_selection ();
                needs_redraw = true;
            });
            AppState.get_default ().favourites_changed.connect (() => {
                clamp_selection ();
                needs_redraw = true;
            });
            HistoryStore.get_default ().items_changed.connect (() => {
                clamp_selection ();
                needs_redraw = true;
            });
            player.state_changed.connect (() => { needs_redraw = true; });
            player.stream_info_changed.connect (() => { needs_redraw = true; });
            player.metadata_changed.connect ((title) => {
                // Record songs to history (same guard as the GTK frontend).
                if (player.current_station != null && player.state == PlayerState.PLAYING) {
                    HistoryStore.get_default ().add (player.current_station, title);
                }
                needs_redraw = true;
            });
        }

        // Mirror the GTK app: look through XDG data dirs, then fall back to the
        // in-tree data dir so the binary runs straight from the build tree.
        private void load_database () {
            foreach (var dir in Environment.get_system_data_dirs ()) {
                if (try_open_db (Path.build_filename (dir, "receiver", "receiver.db"))) {
                    return;
                }
            }
            try_open_db (Path.build_filename (Environment.get_current_dir (),
                                              "data", "receiver", "receiver.db"));
        }

        private bool try_open_db (string path) {
            if (FileUtils.test (path, FileTest.EXISTS)) {
                store.open (path);
                return true;
            }
            return false;
        }

        private void init_screen () {
            scr = Curses.Window.initscr ();
            Curses.cbreak ();
            Curses.noecho ();
            Curses.curs_set (0);
            scr.keypad (true);
            scr.nodelay (true);

            if (Curses.has_colors ()) {
                Curses.start_color ();
                Curses.use_default_colors ();
                Curses.init_pair (PAIR_HEADER, Curses.COLOR_BLACK, Curses.COLOR_CYAN);
                Curses.init_pair (PAIR_STATUS, Curses.COLOR_WHITE, Curses.COLOR_BLUE);
            }
        }

        // --- View-aware data access -----------------------------------------

        private int item_count () {
            switch (view) {
                case View.BROWSE:
                    return (int) store.get_n_items ();
                case View.FAVOURITES:
                    return (int) AppState.get_default ().get_favourite_stations ().length;
                case View.HISTORY:
                    return (int) HistoryStore.get_default ().get_n_items ();
                default:
                    return 0;
            }
        }

        // The station shown at a list row (Browse/Favourites only).
        private Station? station_at (int idx) {
            if (idx < 0) {
                return null;
            }
            if (view == View.BROWSE) {
                return idx < (int) store.get_n_items () ? store.get_item (idx) as Station : null;
            }
            if (view == View.FAVOURITES) {
                var favs = AppState.get_default ().get_favourite_stations ();
                return idx < (int) favs.length ? favs[idx] : null;
            }
            return null;
        }

        private HistoryEntry? history_at (int idx) {
            var h = HistoryStore.get_default ();
            return idx >= 0 && idx < (int) h.get_n_items ()
                ? h.get_item (idx) as HistoryEntry : null;
        }

        // The playable station for the current selection, resolving history
        // entries back to a full station (with a stream URL) via the database.
        private Station? selected_station () {
            if (view == View.HISTORY) {
                var e = history_at (selected);
                return e != null ? store.get_station_by_id (e.station_id) : null;
            }
            return station_at (selected);
        }

        // MprisHost: a terminal app can't raise a window, so this is a no-op.
        public void raise () {
        }

        public void quit () {
            loop.quit ();
        }

        // --- Input -----------------------------------------------------------

        private bool on_input (IOChannel source, IOCondition condition) {
            int ch;
            while ((ch = scr.getch ()) != Curses.ERR) {
                if (picker != PickerMode.NONE) {
                    handle_picker_key (ch);
                } else if (search_active) {
                    handle_search_key (ch);
                } else {
                    handle_key (ch);
                }
            }
            return Source.CONTINUE;
        }

        private void handle_key (int ch) {
            switch (ch) {
                case 'q':
                case 'Q':
                    loop.quit ();
                    break;
                case '\t':
                    cycle_view (1);
                    break;
                case Curses.KEY_BTAB:
                    cycle_view (-1);
                    break;
                case Curses.KEY_UP:
                case 'k':
                    move_selection (-1);
                    break;
                case Curses.KEY_DOWN:
                case 'j':
                    move_selection (1);
                    break;
                case Curses.KEY_PPAGE:
                    move_selection (-list_height ());
                    break;
                case Curses.KEY_NPAGE:
                    move_selection (list_height ());
                    break;
                case Curses.KEY_HOME:
                case 'g':
                    selected = 0;
                    clamp_selection ();
                    needs_redraw = true;
                    break;
                case Curses.KEY_END:
                case 'G':
                    selected = item_count () - 1;
                    clamp_selection ();
                    needs_redraw = true;
                    break;
                case '\n':
                case '\r':
                case Curses.KEY_ENTER:
                    play_selected ();
                    break;
                case ' ':
                    player.toggle_pause ();
                    break;
                case '+':
                case '=':
                    player.volume = player.volume + VOLUME_STEP;
                    needs_redraw = true;
                    break;
                case '-':
                case '_':
                    player.volume = player.volume - VOLUME_STEP;
                    needs_redraw = true;
                    break;
                case 'f':
                    toggle_favourite_selected ();
                    break;
                case '/':
                    if (view == View.BROWSE) {
                        search_active = true;
                        needs_redraw = true;
                    }
                    break;
                case 'c':
                    if (view == View.BROWSE) {
                        open_country_picker ();
                    }
                    break;
                case 'l':
                    if (view == View.BROWSE) {
                        open_language_picker ();
                    }
                    break;
                case Curses.KEY_RESIZE:
                    needs_redraw = true;
                    break;
                default:
                    break;
            }
        }

        private void handle_search_key (int ch) {
            switch (ch) {
                case '\n':
                case '\r':
                case Curses.KEY_ENTER:
                case 27: // Esc — confirm and leave search mode, keeping results
                    search_active = false;
                    needs_redraw = true;
                    break;
                case Curses.KEY_BACKSPACE:
                case 127:
                case 8:
                    if (search_text.length > 0) {
                        search_text = search_text[0 : search_text.index_of_nth_char (
                            search_text.char_count () - 1)];
                        store.search_query = search_text;
                    }
                    needs_redraw = true;
                    break;
                case Curses.KEY_RESIZE:
                    needs_redraw = true;
                    break;
                default:
                    if (ch >= 32 && ch < 127) {
                        search_text += ((char) ch).to_string ();
                        store.search_query = search_text;
                        needs_redraw = true;
                    }
                    break;
            }
        }

        // --- Country/language picker ----------------------------------------

        private void open_country_picker () {
            var codes = store.get_available_country_codes ();
            var names = store.get_available_country_names ();
            string[] labels = { "All countries" };
            string[] values = { "all" };
            for (int i = 0; i < names.length; i++) {
                labels += names[i];
                values += codes[i];
            }
            start_picker (PickerMode.COUNTRY, labels, values);
        }

        private void open_language_picker () {
            var sorted = new GenericArray<string> ();
            foreach (var code in store.get_available_languages ()) {
                sorted.add (code);
            }
            sorted.sort ((a, b) => Languages.translate (a).collate (Languages.translate (b)));

            string[] labels = { "All languages" };
            string[] values = { "all" };
            for (int i = 0; i < sorted.length; i++) {
                labels += Languages.translate (sorted[i]);
                values += sorted[i];
            }
            start_picker (PickerMode.LANGUAGE, labels, values);
        }

        private void start_picker (PickerMode mode, string[] labels, string[] values) {
            picker = mode;
            picker_labels = labels;
            picker_values = values;
            picker_query = "";
            picker_sel = 0;
            picker_off = 0;
            needs_redraw = true;
        }

        // Indices of options matching the query. With an empty query the "All"
        // entry sits at the top so clearing the filter is always one keypress.
        private int[] picker_matches () {
            var q = picker_query.down ();
            int[] res = {};
            for (int i = 0; i < picker_labels.length; i++) {
                if (q == "" || picker_labels[i].down ().contains (q)) {
                    res += i;
                }
            }
            return res;
        }

        private void handle_picker_key (int ch) {
            switch (ch) {
                case 27: // Esc — cancel
                    close_picker ();
                    break;
                case '\n':
                case '\r':
                case Curses.KEY_ENTER:
                    picker_select ();
                    break;
                case Curses.KEY_UP:
                    picker_move (-1);
                    break;
                case Curses.KEY_DOWN:
                    picker_move (1);
                    break;
                case Curses.KEY_PPAGE:
                    picker_move (-list_height ());
                    break;
                case Curses.KEY_NPAGE:
                    picker_move (list_height ());
                    break;
                case Curses.KEY_BACKSPACE:
                case 127:
                case 8:
                    if (picker_query.length > 0) {
                        picker_query = picker_query[0 : picker_query.index_of_nth_char (
                            picker_query.char_count () - 1)];
                        picker_sel = 0;
                        picker_off = 0;
                    }
                    needs_redraw = true;
                    break;
                case Curses.KEY_RESIZE:
                    needs_redraw = true;
                    break;
                default:
                    if (ch >= 32 && ch < 127) {
                        picker_query += ((char) ch).to_string ();
                        picker_sel = 0;
                        picker_off = 0;
                        needs_redraw = true;
                    }
                    break;
            }
        }

        private void picker_move (int delta) {
            int n = picker_matches ().length;
            if (n == 0) {
                picker_sel = 0;
                picker_off = 0;
                return;
            }
            picker_sel = (picker_sel + delta).clamp (0, n - 1);
            int lh = list_height ();
            if (picker_sel < picker_off) {
                picker_off = picker_sel;
            } else if (picker_sel >= picker_off + lh) {
                picker_off = picker_sel - lh + 1;
            }
            needs_redraw = true;
        }

        private void picker_select () {
            var idx = picker_matches ();
            if (picker_sel < 0 || picker_sel >= idx.length) {
                close_picker ();
                return;
            }
            int real = idx[picker_sel];
            string value = picker_values[real];
            string label = (value == "all") ? "" : picker_labels[real];

            if (picker == PickerMode.COUNTRY) {
                store.country_filter = value;
                country_label = label;
            } else if (picker == PickerMode.LANGUAGE) {
                store.language_filter = value;
                language_label = label;
            }
            close_picker ();
            // The list changed underfoot — reset the Browse cursor to the top.
            selected = 0;
            scroll = 0;
            clamp_selection ();
        }

        private void close_picker () {
            picker = PickerMode.NONE;
            needs_redraw = true;
        }

        // Rebuild the header filter labels from filter codes restored via GSettings.
        private void sync_filter_labels () {
            country_label = "";
            var cf = store.country_filter;
            if (cf != "all" && cf != "") {
                var codes = store.get_available_country_codes ();
                var names = store.get_available_country_names ();
                for (int i = 0; i < codes.length; i++) {
                    if (codes[i] == cf) {
                        country_label = names[i];
                        break;
                    }
                }
            }
            language_label = "";
            var lf = store.language_filter;
            if (lf != "all" && lf != "") {
                language_label = Languages.translate (lf);
            }
        }

        private void cycle_view (int dir) {
            saved_sel[(int) view] = selected;
            saved_off[(int) view] = scroll;
            view = (View) (((int) view + dir + View.COUNT) % View.COUNT);
            selected = saved_sel[(int) view];
            scroll = saved_off[(int) view];
            search_active = false;
            clamp_selection ();
            needs_redraw = true;
        }

        private void move_selection (int delta) {
            selected += delta;
            clamp_selection ();
            needs_redraw = true;
        }

        private void play_selected () {
            var station = selected_station ();
            if (station != null) {
                player.play (station);
                AppState.get_default ().settings.set_int64 ("last-station-id", station.id);
            }
        }

        // Resume the last played station on startup, like the GTK app.
        private void restore_last_station () {
            var id = AppState.get_default ().settings.get_int64 ("last-station-id");
            if (id == 0) {
                return;
            }
            var station = store.get_station_by_id (id);
            if (station != null) {
                player.play (station);
            }
        }

        private void toggle_favourite_selected () {
            // Only meaningful for station rows; a no-op in History.
            var station = station_at (selected);
            if (station != null) {
                store.toggle_favourite (station);
                needs_redraw = true;
            }
        }

        private void clamp_selection () {
            int n = item_count ();
            if (n == 0) {
                selected = 0;
                scroll = 0;
                return;
            }
            selected = selected.clamp (0, n - 1);

            int lh = list_height ();
            if (selected < scroll) {
                scroll = selected;
            } else if (selected >= scroll + lh) {
                scroll = selected - lh + 1;
            }
            scroll = scroll.clamp (0, int.max (0, n - 1));
        }

        private int list_height () {
            return int.max (1, Curses.LINES - 2);
        }

        // --- Rendering -------------------------------------------------------

        private void render () {
            int h = Curses.LINES;
            int w = Curses.COLS;
            scr.erase ();

            if (picker != PickerMode.NONE) {
                draw_picker (h, w);
            } else {
                draw_header (w);
                draw_list (h, w);
                draw_player_bar (h, w);
            }

            scr.noutrefresh ();
            Curses.doupdate ();
        }

        private void draw_picker (int h, int width) {
            string title = (picker == PickerMode.COUNTRY) ? "Select country" : "Select language";
            draw_bar (0, width, PAIR_HEADER, " %s — type to filter: %s".printf (title, picker_query));

            var idx = picker_matches ();
            int lh = list_height ();
            if (idx.length == 0) {
                scr.mvaddstr (1, 2, "No matches.");
            } else {
                for (int i = 0; i < lh; i++) {
                    int p = picker_off + i;
                    if (p >= idx.length) {
                        break;
                    }
                    draw_line (1 + i, width, " " + picker_labels[idx[p]], p == picker_sel);
                }
            }
            draw_bar (h - 1, width, PAIR_STATUS, " [↵] select   [Esc] cancel");
        }

        private void draw_header (int width) {
            string text;
            if (search_active) {
                text = " Search: %s▏".printf (search_text);
            } else if (view == View.BROWSE) {
                var sb = new StringBuilder ();
                sb.append (" Receiver · Browse (%d)".printf (item_count ()));
                if (search_text != "") {
                    sb.append ("  search:\"%s\"".printf (search_text));
                }
                if (country_label != "") {
                    sb.append ("  country:" + country_label);
                }
                if (language_label != "") {
                    sb.append ("  lang:" + language_label);
                }
                sb.append ("   [c]/[l] filter  [/] search  [Tab] view  [q] quit");
                text = sb.str;
            } else {
                text = " Receiver · %s (%d)   [Tab] view  [↵] play  [space] pause  [f] fav  [q] quit"
                    .printf (view.label (), item_count ());
            }
            draw_bar (0, width, PAIR_HEADER, text);
        }

        private void draw_list (int h, int width) {
            int lh = list_height ();
            int n = item_count ();
            if (n == 0) {
                scr.mvaddstr (1, 2, empty_message ());
                return;
            }
            for (int i = 0; i < lh; i++) {
                int idx = scroll + i;
                if (idx >= n) {
                    break;
                }
                int row = 1 + i;
                bool is_selected = (idx == selected);
                if (view == View.HISTORY) {
                    var e = history_at (idx);
                    if (e != null) {
                        draw_history_row (row, width, e, is_selected);
                    }
                } else {
                    var station = station_at (idx);
                    if (station != null) {
                        draw_station_row (row, width, station, is_selected);
                    }
                }
            }
        }

        private string empty_message () {
            switch (view) {
                case View.FAVOURITES:
                    return "No favourites yet — press 'f' on a station in Browse.";
                case View.HISTORY:
                    return "No song history yet — play a station for a while.";
                default:
                    return "No stations match your search.";
            }
        }

        private void draw_station_row (int row, int width, Station station, bool is_selected) {
            bool playing = player.current_station != null
                && player.current_station.id == station.id;
            string marker = playing ? "▶" : " ";
            string star = store.is_favourite (station.id) ? "★" : " ";
            string subtitle = station.get_subtitle ();
            string line = "%s %s %s".printf (marker, star, station.name);
            if (subtitle != "") {
                line += "   —   " + subtitle;
            }
            draw_line (row, width, line, is_selected);
        }

        private void draw_history_row (int row, int width, HistoryEntry entry, bool is_selected) {
            string time = format_time (entry.played_at);
            string line = "%s   %s   —   %s".printf (time, entry.song_title, entry.station_name);
            draw_line (row, width, line, is_selected);
        }

        private void draw_line (int row, int width, string line, bool is_selected) {
            int attr = is_selected ? Curses.A_REVERSE : Curses.A_NORMAL;
            scr.attron (attr);
            scr.mvaddstr (row, 0, fit (line, width));
            scr.attroff (attr);
        }

        private void draw_player_bar (int h, int width) {
            string left;
            var station = player.current_station;
            if (station == null) {
                left = " Stopped";
            } else {
                string icon;
                if (player.state == PlayerState.PLAYING) {
                    icon = player.is_buffering ? "…" : "▶";
                } else if (player.state == PlayerState.PAUSED) {
                    icon = "⏸";
                } else {
                    icon = "■";
                }
                left = " %s %s".printf (icon, station.name);
                if (player.now_playing != "") {
                    left += " — " + player.now_playing;
                }
            }
            string right = "vol %d%% ".printf ((int) (player.volume * 100 + 0.5));
            draw_bar (h - 1, width, PAIR_STATUS, compose (left, right, width));
        }

        // --- Drawing helpers -------------------------------------------------

        private void draw_bar (int row, int width, int pair, string text) {
            if (row < 0 || width <= 0) {
                return;
            }
            int attr = Curses.has_colors () ? Curses.color_pair (pair) : Curses.A_REVERSE;
            scr.attron (attr);
            scr.mvaddstr (row, 0, fit (text, width));
            scr.attroff (attr);
        }

        // Left-aligned text with right-aligned suffix, padded to width.
        private string compose (string left, string right, int width) {
            int lw = left.char_count ();
            int rw = right.char_count ();
            if (lw + rw >= width) {
                return fit (left, width);
            }
            var sb = new StringBuilder (left);
            for (int i = lw; i < width - rw; i++) {
                sb.append_c (' ');
            }
            sb.append (right);
            return sb.str;
        }

        // Pad or truncate to exactly `width` display columns (assumes one
        // column per character; adequate for the Latin chrome drawn here).
        private string fit (string text, int width) {
            int len = text.char_count ();
            if (len > width) {
                return text[0 : (int) text.index_of_nth_char (width)];
            }
            var sb = new StringBuilder (text);
            for (int i = len; i < width; i++) {
                sb.append_c (' ');
            }
            return sb.str;
        }

        private string format_time (string iso) {
            if (iso == "") {
                return "--:--";
            }
            var dt = new DateTime.from_iso8601 (iso, null);
            return dt != null ? dt.format ("%H:%M") : iso;
        }

        // Redirect GLib log messages (from the core services) to a file so they
        // don't print over the curses screen.
        private static void redirect_logs () {
            var dir = Path.build_filename (Environment.get_user_cache_dir (), "receiver");
            DirUtils.create_with_parents (dir, 0755);
            log_stream = FileStream.open (Path.build_filename (dir, "tui.log"), "w");
            Log.set_writer_func ((level, fields) => {
                // Drop verbose DEBUG/INFO chatter (GIO, dconf, …); keep
                // messages, warnings and errors.
                if ((level & (LogLevelFlags.LEVEL_DEBUG | LogLevelFlags.LEVEL_INFO)) != 0) {
                    return LogWriterOutput.HANDLED;
                }
                if (log_stream != null) {
                    log_stream.puts (Log.writer_format_fields (level, fields, false));
                    log_stream.putc ('\n');
                    log_stream.flush ();
                }
                return LogWriterOutput.HANDLED;
            });
        }

        public static int main (string[] args) {
            redirect_logs ();
            Gst.init (ref args);
            return new Tui ().run ();
        }
    }
}
