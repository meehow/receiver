// Async image loader with file-based disk cache
namespace Receiver {

    public class ImageLoader : Object {
        // Wraps a SourceFunc so pending callbacks can be stored in a container
        private class Waiter {
            public SourceFunc callback;
            public Waiter(owned SourceFunc cb) {
                callback = (owned) cb;
            }
        }

        private HashTable<int64?, bool> loading;
        private HashTable<int64?, GenericArray<Waiter>> waiters;
        private static ImageLoader? _instance;
        private Soup.Session session;
        private string cache_dir;

        public static ImageLoader get_default() {
            if (_instance == null) {
                _instance = new ImageLoader();
            }
            return _instance;
        }

        private ImageLoader() {
            loading = new HashTable<int64?, bool>(int64_hash, int64_equal);
            waiters = new HashTable<int64?, GenericArray<Waiter>>(int64_hash, int64_equal);

            cache_dir = Path.build_filename(
                Environment.get_user_cache_dir(), "receiver", "images"
            );
            DirUtils.create_with_parents(cache_dir, 0755);

            session = new Soup.Session () { timeout = 10 };
        }

        public string get_cache_path(int64 image_hash) {
            return Path.build_filename(cache_dir, image_hash.to_string());
        }

        private Gdk.Texture? load_from_disk(string path, int64 image_hash) {
            if (!FileUtils.test(path, FileTest.EXISTS)) return null;
            try {
                var pixbuf = new Gdk.Pixbuf.from_file(path);
                if (pixbuf != null) {
                    return Gdk.Texture.for_pixbuf(pixbuf);
                }
            } catch (Error e) {
                debug("Disk cache read failed for %lld: %s", image_hash, e.message);
            }
            return null;
        }

        // Resume everyone who yielded while this hash was downloading
        private void release_waiters(int64 image_hash) {
            loading.remove(image_hash);
            var list = waiters.get(image_hash);
            if (list == null) return;
            waiters.remove(image_hash);
            for (int i = 0; i < list.length; i++) {
                var w = list[i];
                Idle.add((owned) w.callback);
            }
        }

        // Load image by content hash - checks disk cache, then network
        public async Gdk.Texture? load(int64 image_hash) {
            if (image_hash == 0) return null;

            // Try disk cache
            var path = get_cache_path(image_hash);
            var cached = load_from_disk(path, image_hash);
            if (cached != null) return cached;

            if (loading.contains(image_hash)) {
                // Wait for the in-flight download, then re-check the disk cache
                var list = waiters.get(image_hash);
                if (list == null) {
                    list = new GenericArray<Waiter>();
                    waiters.set(image_hash, list);
                }
                list.add(new Waiter(load.callback));
                yield;
                return load_from_disk(path, image_hash);
            }

            loading.set(image_hash, true);

            try {
                var url = Station.IMAGE_BASE_URL + image_hash.to_string();
                var msg = new Soup.Message("GET", url);
                var stream = yield session.send_async(msg, Priority.DEFAULT, null);

                if (msg.status_code != 200) {
                    try { stream.close(); } catch (Error ce) {}
                    throw new IOError.FAILED("HTTP %u", msg.status_code);
                }

                // Read response into bytes
                var mem = new MemoryOutputStream.resizable();
                yield mem.splice_async(stream,
                    OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET,
                    Priority.DEFAULT, null);
                var bytes = mem.steal_as_bytes();

                // Decode before caching so invalid data never reaches the disk
                var pixbuf = new Gdk.Pixbuf.from_stream(
                    new MemoryInputStream.from_bytes(bytes));

                if (pixbuf != null) {
                    try {
                        FileUtils.set_data(path, bytes.get_data());
                    } catch (Error we) {
                        debug("Disk cache write failed for %lld: %s", image_hash, we.message);
                    }
                    release_waiters(image_hash);
                    return Gdk.Texture.for_pixbuf(pixbuf);
                }
            } catch (Error e) {
                debug("Image load failed for hash %lld: %s", image_hash, e.message);
            }

            release_waiters(image_hash);
            return null;
        }
    }
}
