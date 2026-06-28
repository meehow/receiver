/*
 * Receiver TUI — ncurses frontend over libreceiver-core.
 *
 * This skeleton establishes the runtime: curses runs as a guest of the GLib
 * main loop (so the core's GStreamer/Soup work keeps ticking), stdin is read
 * non-blocking via a GLib fd watch, repaints are coalesced, and the terminal
 * is always restored on exit. The actual station/player UI is layered on top
 * of this in the next step.
 */
namespace Receiver {

    public class Tui : Object {
        // Signal numbers (GLib profile has no Posix.Signal binding).
        private const int SIGNAL_INT = 2;
        private const int SIGNAL_TERM = 15;

        // Colour pair ids.
        private const int PAIR_HEADER = 1;
        private const int PAIR_STATUS = 2;

        private MainLoop loop = new MainLoop ();
        private unowned Curses.Window scr;
        private IOChannel stdin_channel;
        private bool needs_redraw = true;

        public int run () {
            Intl.setlocale (LocaleCategory.ALL, "");

            if (PosixExtras.isatty (0) == 0 || PosixExtras.isatty (1) == 0) {
                stderr.printf ("receiver-tui requires an interactive terminal.\n");
                return 1;
            }

            init_screen ();

            // Restore the terminal no matter how we are asked to stop.
            Unix.signal_add (SIGNAL_INT, () => { loop.quit (); return Source.REMOVE; });
            Unix.signal_add (SIGNAL_TERM, () => { loop.quit (); return Source.REMOVE; });

            // Non-blocking stdin driven by the main loop, so async core work runs.
            stdin_channel = new IOChannel.unix_new (0);
            stdin_channel.add_watch (IOCondition.IN, on_input);

            // Paint once up front, then coalesce later repaints (~30 fps cap).
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

            Curses.endwin ();
            return 0;
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

        private bool on_input (IOChannel source, IOCondition condition) {
            int ch;
            while ((ch = scr.getch ()) != Curses.ERR) {
                dispatch (ch);
            }
            return Source.CONTINUE;
        }

        private void dispatch (int ch) {
            switch (ch) {
                case 'q':
                case 'Q':
                    loop.quit ();
                    break;
                case Curses.KEY_RESIZE:
                    needs_redraw = true;
                    break;
                default:
                    break;
            }
        }

        private void render () {
            int h = Curses.LINES;
            int w = Curses.COLS;
            scr.erase ();

            draw_bar (0, w, PAIR_HEADER, " Receiver — TUI (skeleton)");

            if (h > 4) {
                scr.mvaddstr (2, 2, "libreceiver-core is linked; station UI comes next.");
                scr.mvaddstr (3, 2, "Press 'q' to quit.");
            }

            draw_bar (h - 1, w, PAIR_STATUS, " q: quit");

            scr.noutrefresh ();
            Curses.doupdate ();
        }

        // Draw a full-width coloured bar with left-aligned text.
        private void draw_bar (int row, int width, int pair, string text) {
            if (row < 0 || width <= 0) {
                return;
            }
            int attr = Curses.has_colors () ? Curses.color_pair (pair) : Curses.A_REVERSE;
            scr.attron (attr);
            scr.mvaddstr (row, 0, fit (text, width));
            scr.attroff (attr);
        }

        // Pad or truncate to exactly `width` display columns (1 column per
        // character; good enough for the ASCII chrome drawn here).
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
    }

    public static int main (string[] args) {
        return new Tui ().run ();
    }
}
