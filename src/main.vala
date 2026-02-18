// Entry point
const string GETTEXT_PACKAGE = "receiver";

int main(string[] args) {
    // Set locale — if not installed, fall back so gettext still works
    if (Intl.setlocale(LocaleCategory.ALL, "") == null) {
        if (Environment.get_variable("LANGUAGE") == null) {
            var lang = Environment.get_variable("LANG");
            if (lang != null) {
                Environment.set_variable("LANGUAGE", lang.split(".")[0], true);
            }
        }
        Environment.set_variable("LC_ALL", "en_US.UTF-8", true);
        Intl.setlocale(LocaleCategory.ALL, "en_US.UTF-8");
    }

    var localedir = Environment.get_variable("LOCALEDIR") ?? "/usr/share/locale";
    Intl.bindtextdomain(GETTEXT_PACKAGE, localedir);
    Intl.bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain(GETTEXT_PACKAGE);

    Gst.init(ref args);

    // Disable AV1 video parser — it crashes on AAC audio data during auto-detection
    var registry = Gst.Registry.get();
    var av1parse = registry.find_feature("av1parse", typeof(Gst.ElementFactory));
    if (av1parse != null) av1parse.set_rank(Gst.Rank.NONE);

    var app = new Receiver.Application();
    return app.run(args);
}
