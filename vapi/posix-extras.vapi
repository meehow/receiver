/* Small libc bindings needed by the TUI that aren't in the GLib profile. */
[CCode (cheader_filename = "unistd.h")]
namespace PosixExtras {
    [CCode (cname = "isatty")]
    public int isatty (int fd);
}
