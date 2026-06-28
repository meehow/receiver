/*
 * Minimal Vala binding for ncursesw.
 *
 * Hand-written to cover only the surface the Receiver TUI uses: lifecycle,
 * non-blocking input, windowed drawing, colour pairs and key/attribute
 * constants. Link against the `ncursesw` pkg-config dependency.
 */
[CCode (cheader_filename = "curses.h", lower_case_cprefix = "")]
namespace Curses {

    [Compact]
    [CCode (cname = "WINDOW", free_function = "delwin", has_type_id = false)]
    public class Window {
        // Initialise curses; returns the standard screen (owned by curses,
        // never freed by us — hence unowned).
        [CCode (cname = "initscr")]
        public static unowned Window initscr ();

        // Create a sub-window; freed with delwin via the compact free_function.
        [CCode (cname = "newwin")]
        public Window (int nlines, int ncols, int begin_y, int begin_x);

        [CCode (cname = "keypad")]
        public int keypad (bool enable);
        [CCode (cname = "nodelay")]
        public int nodelay (bool enable);
        [CCode (cname = "wtimeout")]
        public void set_timeout (int delay);

        [CCode (cname = "wgetch")]
        public int getch ();

        [CCode (cname = "wrefresh")]
        public int refresh ();
        [CCode (cname = "wnoutrefresh")]
        public int noutrefresh ();
        [CCode (cname = "werase")]
        public int erase ();
        [CCode (cname = "wclear")]
        public int clear ();
        [CCode (cname = "wmove")]
        public int move (int y, int x);

        [CCode (cname = "waddstr")]
        public int addstr (string str);
        [CCode (cname = "mvwaddstr")]
        public int mvaddstr (int y, int x, string str);

        [CCode (cname = "wattron")]
        public int attron (int attrs);
        [CCode (cname = "wattroff")]
        public int attroff (int attrs);

        [CCode (cname = "mvwhline")]
        public int hline (int y, int x, ulong ch, int n);

        [CCode (cname = "getmaxx")]
        public int getmaxx ();
        [CCode (cname = "getmaxy")]
        public int getmaxy ();
    }

    // Mouse
    [CCode (cname = "MEVENT", has_type_id = false)]
    public struct MEvent {
        public short id;
        public int x;
        public int y;
        public int z;
        public uint bstate;
    }

    [CCode (cname = "mousemask")]
    public uint mousemask (uint newmask, out uint oldmask = null);
    [CCode (cname = "getmouse")]
    public int getmouse (out MEvent ev);

    [CCode (cname = "KEY_MOUSE")]
    public const int KEY_MOUSE;
    [CCode (cname = "ALL_MOUSE_EVENTS")]
    public const uint ALL_MOUSE_EVENTS;
    [CCode (cname = "BUTTON1_PRESSED")]
    public const uint BUTTON1_PRESSED;
    [CCode (cname = "BUTTON1_CLICKED")]
    public const uint BUTTON1_CLICKED;
    [CCode (cname = "BUTTON4_PRESSED")]
    public const uint BUTTON4_PRESSED;
    [CCode (cname = "BUTTON5_PRESSED")]
    public const uint BUTTON5_PRESSED;

    // Lifecycle
    [CCode (cname = "endwin")]
    public int endwin ();
    [CCode (cname = "cbreak")]
    public int cbreak ();
    [CCode (cname = "noecho")]
    public int noecho ();
    [CCode (cname = "curs_set")]
    public int curs_set (int visibility);
    [CCode (cname = "doupdate")]
    public int doupdate ();

    // Colour
    [CCode (cname = "has_colors")]
    public bool has_colors ();
    [CCode (cname = "start_color")]
    public int start_color ();
    [CCode (cname = "use_default_colors")]
    public int use_default_colors ();
    [CCode (cname = "init_pair")]
    public int init_pair (int pair, int fg, int bg);
    [CCode (cname = "COLOR_PAIR")]
    public int color_pair (int pair);

    // Globals (updated by curses, e.g. on resize)
    [CCode (cname = "COLS")]
    public int COLS;
    [CCode (cname = "LINES")]
    public int LINES;

    // Return / colour constants
    [CCode (cname = "ERR")]
    public const int ERR;
    [CCode (cname = "COLOR_BLACK")]
    public const int COLOR_BLACK;
    [CCode (cname = "COLOR_RED")]
    public const int COLOR_RED;
    [CCode (cname = "COLOR_GREEN")]
    public const int COLOR_GREEN;
    [CCode (cname = "COLOR_YELLOW")]
    public const int COLOR_YELLOW;
    [CCode (cname = "COLOR_BLUE")]
    public const int COLOR_BLUE;
    [CCode (cname = "COLOR_MAGENTA")]
    public const int COLOR_MAGENTA;
    [CCode (cname = "COLOR_CYAN")]
    public const int COLOR_CYAN;
    [CCode (cname = "COLOR_WHITE")]
    public const int COLOR_WHITE;

    // Attributes
    [CCode (cname = "A_NORMAL")]
    public const int A_NORMAL;
    [CCode (cname = "A_REVERSE")]
    public const int A_REVERSE;
    [CCode (cname = "A_BOLD")]
    public const int A_BOLD;
    [CCode (cname = "A_DIM")]
    public const int A_DIM;
    [CCode (cname = "A_UNDERLINE")]
    public const int A_UNDERLINE;

    // Special keys (returned by getch when keypad is enabled)
    [CCode (cname = "KEY_UP")]
    public const int KEY_UP;
    [CCode (cname = "KEY_DOWN")]
    public const int KEY_DOWN;
    [CCode (cname = "KEY_LEFT")]
    public const int KEY_LEFT;
    [CCode (cname = "KEY_RIGHT")]
    public const int KEY_RIGHT;
    [CCode (cname = "KEY_HOME")]
    public const int KEY_HOME;
    [CCode (cname = "KEY_END")]
    public const int KEY_END;
    [CCode (cname = "KEY_NPAGE")]
    public const int KEY_NPAGE;
    [CCode (cname = "KEY_PPAGE")]
    public const int KEY_PPAGE;
    [CCode (cname = "KEY_BACKSPACE")]
    public const int KEY_BACKSPACE;
    [CCode (cname = "KEY_ENTER")]
    public const int KEY_ENTER;
    [CCode (cname = "KEY_BTAB")]
    public const int KEY_BTAB;
    [CCode (cname = "KEY_RESIZE")]
    public const int KEY_RESIZE;
}
