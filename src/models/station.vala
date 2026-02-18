// Station data model
namespace Receiver {

    public const int SOURCE_RADIO_BROWSER = 1;
    public const int SOURCE_SOMAFM = 2;

    public class Station : Object {
        public int64 id { get; set; }
        public int source { get; set; }
        public string name { get; set; }
        public string homepage { get; set; }
        public int image_width { get; set; }
        public int64 image_hash { get; set; }
        public string tags_raw { get; set; }
        public string country { get; set; }

        // Raw stream data (format: "url|quality|bitrate|codec;...")
        // Parsed on demand in get_stream_url() — not eagerly deserialized
        public string streams_raw { get; set; }

        public Station() {}

        // Get best stream URL (prioritize highest quality)
        // Parses streams_raw on demand — only called when actually playing
        public string? get_stream_url() {
            if (streams_raw == null) {
                return null;
            }

            string? best_url = null;
            string? best_quality = null;

            foreach (var part in streams_raw.split(";")) {
                var fields = part.split("|");
                if (fields.length < 1 || fields[0] == "") continue;

                var url = fields[0];
                var quality = fields.length > 1 ? fields[1] : "medium";

                if (quality == "highest") return url;

                if (best_url == null || quality == "high") {
                    best_url = url;
                    best_quality = quality;
                }
            }
            return best_url;
        }

        // Get subtitle string (country • tag1 • tag2 • ...)
        public string get_subtitle() {
            var parts = new GenericArray<string>();
            if (country != null) parts.add(country);
            if (tags_raw != null) {
                foreach (var tag in tags_raw.split(" ")) {
                    parts.add(tag);
                }
            }
            return string.joinv(" • ", parts.data);
        }
    }
}

