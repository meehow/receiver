// Async image loader with file-based disk cache
namespace Receiver {

    public class ImageLoader : Object {
        private HashTable<int64?, bool> loading;
        private static ImageLoader? _instance;
        private Soup.Session session;
        private string cache_dir;
        public const string IMAGE_BASE_URL = "https://receiver.808bits.com/images/";

        public static ImageLoader get_default() {
            if (_instance == null) {
                _instance = new ImageLoader();
            }
            return _instance;
        }

        private ImageLoader() {
            loading = new HashTable<int64?, bool>(int64_hash, int64_equal);

            cache_dir = Path.build_filename(
                Environment.get_user_cache_dir(), "receiver", "images"
            );
            DirUtils.create_with_parents(cache_dir, 0755);

            session = new Soup.Session () { timeout = 10 };
        }

        public string get_cache_path(int64 image_hash) {
            return Path.build_filename(cache_dir, image_hash.to_string());
        }

        // Load image by content hash - checks disk cache, then network
        public async Gdk.Texture? load(int64 image_hash) {
            if (image_hash == 0) return null;

            // Try disk cache
            var path = get_cache_path(image_hash);
            if (FileUtils.test(path, FileTest.EXISTS)) {
                try {
                    var pixbuf = new Gdk.Pixbuf.from_file(path);
                    if (pixbuf != null) {
                        return Gdk.Texture.for_pixbuf(pixbuf);
                    }
                } catch (Error e) {
                    debug("Disk cache read failed for %lld: %s", image_hash, e.message);
                }
            }

            if (loading.contains(image_hash)) {
                return null;
            }

            loading.set(image_hash, true);

            try {
                var url = IMAGE_BASE_URL + image_hash.to_string();
                var msg = new Soup.Message("GET", url);
                var stream = yield session.send_async(msg, Priority.DEFAULT, null);

                if (msg.status_code != 200) {
                    throw new IOError.FAILED("HTTP %u", msg.status_code);
                }

                // Read response into bytes
                var mem = new MemoryOutputStream.resizable();
                yield mem.splice_async(stream,
                    OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET,
                    Priority.DEFAULT, null);
                var bytes = mem.steal_as_bytes();

                // Save to disk cache immediately
                FileUtils.set_data(path, bytes.get_data());

                var pixbuf = new Gdk.Pixbuf.from_stream(
                    new MemoryInputStream.from_bytes(bytes));

                if (pixbuf != null) {
                    loading.remove(image_hash);
                    return Gdk.Texture.for_pixbuf(pixbuf);
                }
            } catch (Error e) {
                debug("Image load failed for hash %lld: %s", image_hash, e.message);
            }

            loading.remove(image_hash);
            return null;
        }
    }
}
