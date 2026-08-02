// Station data model
namespace Receiver {

    public const int SOURCE_RADIO_BROWSER = 1;
    public const int SOURCE_SOMAFM = 2;

    public class Station : Object {
        public const string IMAGE_BASE_URL = "https://receiver.808bits.com/images/";

        public int64 id { get; set; }
        public int source { get; set; }
        public string name { get; set; }
        public string homepage { get; set; }

        public int64 image_hash { get; set; }
        public string tags_raw { get; set; }
        public string country { get; set; }

        // Raw stream data (format: "url|quality|bitrate|codec;...")
        // Parsed on demand in get_stream_url() — not eagerly deserialized
        public string streams_raw { get; set; }

        public Station() {}

        private static int quality_rank(string quality) {
            switch (quality) {
                case "highest": return 4;
                case "high": return 3;
                case "medium": return 2;
                case "low": return 1;
                default: return 0;
            }
        }

        // Get best stream URL (prioritize highest quality)
        // Parses streams_raw on demand — only called when actually playing
        public string? get_stream_url() {
            if (streams_raw == null) {
                return null;
            }

            string? best_url = null;
            int best_rank = -1;

            foreach (var part in streams_raw.split(";")) {
                var fields = part.split("|");
                if (fields.length < 1 || fields[0] == "") continue;

                var url = fields[0];
                var quality = fields.length > 1 ? fields[1] : "medium";

                if (quality == "highest") return url;

                var rank = quality_rank(quality);
                if (rank > best_rank) {
                    best_url = url;
                    best_rank = rank;
                }
            }
            return best_url;
        }

        // Get subtitle string (country • tag1 • tag2 • ...)
        public string get_subtitle() {
            var parts = new GenericArray<string>();
            if (country != null && country != "") parts.add(country);
            if (tags_raw != null) {
                foreach (var tag in tags_raw.split(" ")) {
                    if (tag != "") parts.add(tag);
                }
            }
            return string.joinv(" • ", parts.data);
        }
    }
}

