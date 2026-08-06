// Debounced file persistence — coalesces rapid save requests into one write
namespace Receiver {

    public delegate string SerializeFunc();

    public class DebouncedSaver : Object {
        private string path;
        private uint interval_ms;
        private SerializeFunc serialize;
        private string name;
        private uint save_timeout = 0;

        public DebouncedSaver(string path, uint interval_ms, owned SerializeFunc serialize, string name) {
            this.path = path;
            this.interval_ms = interval_ms;
            this.serialize = (owned) serialize;
            this.name = name;
        }

        public void schedule() {
            if (save_timeout != 0) return;
            save_timeout = Timeout.add(interval_ms, () => {
                save_timeout = 0;
                do_save.begin();
                return false;
            });
        }

        // Synchronous write for shutdown, when the main loop may not run again
        public void flush() {
            if (save_timeout != 0) {
                Source.remove(save_timeout);
                save_timeout = 0;
                try {
                    File.new_for_path(path).replace_contents(
                        serialize().data, null, false,
                        FileCreateFlags.REPLACE_DESTINATION, null, null);
                } catch (Error e) {
                    warning("Failed to save %s: %s", name, e.message);
                }
            }
        }

        private async void do_save() {
            try {
                // replace_contents_async does not copy the buffer, so keep it
                // alive in a Bytes for the duration of the call
                yield File.new_for_path(path).replace_contents_bytes_async(
                    new Bytes(serialize().data), null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                warning("Failed to save %s: %s", name, e.message);
            }
        }
    }
}
