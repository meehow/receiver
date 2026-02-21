// Entry point
const string GETTEXT_PACKAGE = "receiver";

int main(string[] args) {
    // Set locale — if not installed, fall back to C.UTF-8 so gettext still works
    if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
        if (Environment.get_variable("LANGUAGE") == null) {
            var lang = Environment.get_variable("LANG");
            if (lang != null) {
                Environment.set_variable("LANGUAGE", lang.split(".")[0], true);
            }
        }
        Intl.setlocale(LocaleCategory.ALL, "C.UTF-8");
    }

    var localedir = Environment.get_variable("LOCALEDIR") ?? "/usr/share/locale";
    Intl.bindtextdomain(GETTEXT_PACKAGE, localedir);
    Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain(GETTEXT_PACKAGE);

    // Use GNOME gsettings proxy resolver (avoids portal denial in sandboxes)
    Environment.set_variable("GIO_USE_PROXY_RESOLVER", "gnome", false);

    Gst.init(ref args);

    // Disable AV1 video parser — it crashes on AAC audio data during auto-detection
    var registry = Gst.Registry.get();
    var av1parse = registry.find_feature("av1parse", typeof(Gst.ElementFactory));
    if (av1parse != null) av1parse.set_rank(Gst.Rank.NONE);

    var app = new Receiver.Application();
    return app.run(args);
}
