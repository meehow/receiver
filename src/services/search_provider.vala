// GNOME Shell search provider: search stations from the Activities overview.
//
// Registered on the session bus by Application.dbus_register at
// /io/github/meehow/Receiver/SearchProvider. The Shell discovers it through
// data/io.github.meehow.Receiver.search-provider.ini and calls these methods
// over D-Bus, activating the app in the background if it is not running (the
// heavy lifting lives in Application, which owns the store and player).
namespace Receiver {

    [DBus (name = "org.gnome.Shell.SearchProvider2")]
    public class SearchProvider : Object {
        private unowned Application app;

        public SearchProvider(Application app) {
            this.app = app;
        }

        [DBus (name = "GetInitialResultSet")]
        public string[] get_initial_result_set(string[] terms) throws DBusError, IOError {
            return app.search_station_ids(string.joinv(" ", terms));
        }

        [DBus (name = "GetSubsearchResultSet")]
        public string[] get_subsearch_result_set(string[] previous_results, string[] terms)
                throws DBusError, IOError {
            return app.search_station_ids(string.joinv(" ", terms));
        }

        [DBus (name = "GetResultMetas")]
        public HashTable<string, Variant>[] get_result_metas(string[] identifiers)
                throws DBusError, IOError {
            return app.search_result_metas(identifiers);
        }

        [DBus (name = "ActivateResult")]
        public void activate_result(string identifier, string[] terms, uint timestamp)
                throws DBusError, IOError {
            app.play_station_id(identifier);
        }

        [DBus (name = "LaunchSearch")]
        public void launch_search(string[] terms, uint timestamp) throws DBusError, IOError {
            app.open_with_search(string.joinv(" ", terms));
        }
    }
}
