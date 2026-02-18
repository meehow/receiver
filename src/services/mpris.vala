// MPRIS2 D-Bus integration for desktop media controls
namespace Receiver {

    [DBus(name = "org.mpris.MediaPlayer2")]
    public class MprisRoot : Object {
        private Gtk.Application app;

        public MprisRoot(Gtk.Application app) {
            this.app = app;
        }

        public bool can_quit { get { return true; } }
        public bool can_raise { get { return true; } }
        public bool has_track_list { get { return false; } }
        public string identity { owned get { return "Receiver"; } }
        public string desktop_entry { owned get { return "io.github.meehow.Receiver"; } }
        public string[] supported_uri_schemes { owned get { return {}; } }
        public string[] supported_mime_types { owned get { return {}; } }

        public void raise() throws GLib.Error {
            var win = app.active_window;
            if (win != null) {
                win.present();
            }
        }

        public void quit() throws GLib.Error {
            app.quit();
        }
    }

    [DBus(name = "org.mpris.MediaPlayer2.Player")]
    public class MprisPlayer : Object {
        private Player player;
        private DBusConnection conn;
        private string? last_status = null;
        private string? last_title = null;
        private double last_volume = -1;

        public MprisPlayer(Player player, DBusConnection conn) {
            this.player = player;
            this.conn = conn;

            player.state_changed.connect(on_state_changed);
            player.metadata_changed.connect(on_metadata_changed);
            player.notify["volume"].connect(on_volume_changed);
        }

        // Properties
        public string playback_status {
            owned get {
                switch (player.state) {
                    case PlayerState.PLAYING: return "Playing";
                    case PlayerState.PAUSED: return "Paused";
                    default: return "Stopped";
                }
            }
        }

        public double rate { get { return 1.0; } set {} }
        public double minimum_rate { get { return 1.0; } }
        public double maximum_rate { get { return 1.0; } }

        public double volume {
            get { return player.volume; }
            set { player.volume = value; }
        }

        public int64 position { get { return 0; } }
        public bool can_go_next { get { return false; } }
        public bool can_go_previous { get { return false; } }
        public bool can_play { get { return player.current_station != null; } }
        public bool can_pause { get { return player.state == PlayerState.PLAYING; } }
        public bool can_seek { get { return false; } }
        public bool can_control { get { return true; } }

        public HashTable<string, Variant> metadata {
            owned get {
                var meta = new HashTable<string, Variant>(str_hash, str_equal);
                var station = player.current_station;

                if (station != null) {
                    meta.insert("mpris:trackid", new Variant.object_path(
                        "/org/mpris/MediaPlayer2/Track/%s".printf(
                            station.id.to_string()
                        )
                    ));
                    meta.insert("xesam:title", player.now_playing != "" ? player.now_playing : station.name);
                    meta.insert("xesam:artist", new Variant.strv({station.name}));

                    if (station.image_hash != 0) {
                        meta.insert("mpris:artUrl", ImageLoader.IMAGE_BASE_URL + station.image_hash.to_string());
                    }
                }

                return meta;
            }
        }

        // Methods
        public void play() throws GLib.Error {
            if (player.current_station != null) {
                player.play(player.current_station);
            }
        }

        public void pause() throws GLib.Error {
            player.toggle_pause();
        }

        public void play_pause() throws GLib.Error {
            player.toggle_pause();
        }

        public void stop() throws GLib.Error {
            player.stop();
        }

        public void next() throws GLib.Error {}
        public void previous() throws GLib.Error {}
        public void seek(int64 offset) throws GLib.Error {}
        public void set_position(ObjectPath track_id, int64 position) throws GLib.Error {}
        public void open_uri(string uri) throws GLib.Error {}

        // Property change notifications
        private void on_state_changed(PlayerState state) {
            var status = playback_status;
            if (status == last_status) return;
            last_status = status;
            if (state == PlayerState.STOPPED) last_title = null;

            var changed = new HashTable<string, Variant>(str_hash, str_equal);
            changed.insert("PlaybackStatus", status);
            changed.insert("CanPlay", can_play);
            changed.insert("CanPause", can_pause);
            emit_properties_changed(changed);
        }

        private void on_metadata_changed(string title) {
            if (title == last_title) return;
            last_title = title;

            var changed = new HashTable<string, Variant>(str_hash, str_equal);
            changed.insert("Metadata", metadata);
            emit_properties_changed(changed);
        }

        private void on_volume_changed() {
            if (player.volume == last_volume) return;
            last_volume = player.volume;

            var changed = new HashTable<string, Variant>(str_hash, str_equal);
            changed.insert("Volume", player.volume);
            emit_properties_changed(changed);
        }

        private void emit_properties_changed(HashTable<string, Variant> changed) {
            try {
                var builder = new VariantBuilder(VariantType.ARRAY);
                changed.foreach((key, val) => {
                    builder.add("{sv}", key, val);
                });

                conn.emit_signal(
                    null,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                    new Variant(
                        "(sa{sv}as)",
                        "org.mpris.MediaPlayer2.Player",
                        builder,
                        new VariantBuilder(VariantType.STRING_ARRAY)
                    )
                );
            } catch (Error e) {
                warning("MPRIS signal error: %s", e.message);
            }
        }
    }

    // Service that owns the bus name and registers both interfaces
    public class MprisService : Object {
        private uint owner_id;

        public MprisService(Gtk.Application app, Player player) {
            owner_id = Bus.own_name(
                BusType.SESSION,
                "org.mpris.MediaPlayer2.receiver",
                BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object("/org/mpris/MediaPlayer2", new MprisRoot(app));
                        conn.register_object("/org/mpris/MediaPlayer2", new MprisPlayer(player, conn));
                        message("MPRIS D-Bus registered");
                    } catch (IOError e) {
                        warning("MPRIS registration failed: %s", e.message);
                    }
                },
                () => {},
                () => { warning("Could not acquire MPRIS bus name"); }
            );
        }

        ~MprisService() {
            if (owner_id != 0) {
                Bus.unown_name(owner_id);
            }
        }
    }
}
