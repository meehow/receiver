// Metadata parsing for ICY stream metadata
namespace Receiver {

    public class MetadataParser : Object {
        private Regex? decimal_regex;
        private Regex? hex_regex;
        private Regex? xml_artist_regex;
        private Regex? xml_title_regex;
        private static MetadataParser? _instance;

        public static MetadataParser get_default() {
            if (_instance == null) {
                _instance = new MetadataParser();
            }
            return _instance;
        }

        private MetadataParser() {
            try {
                decimal_regex = new Regex("&#(\\d+);");
                hex_regex = new Regex("&#[xX]([0-9a-fA-F]+);");
                xml_artist_regex = new Regex("<DB_(?:DALET_|LEAD_)?ARTIST_NAME>(.*?)</DB_(?:DALET_|LEAD_)?ARTIST_NAME>");
                xml_title_regex = new Regex("<DB_(?:DALET_|LEAD_)?TITLE_NAME>(.*?)</DB_(?:DALET_|LEAD_)?TITLE_NAME>");
            } catch (RegexError e) {}
        }

        public string clean_metadata(string raw_title, string? raw_artist = null) {
            var title = fix_encoding(strip_bom(raw_title));
            title = parse_xml(title);

            if (raw_artist != null && raw_artist != "") {
                var artist = fix_encoding(strip_bom(raw_artist));
                if (!title.down().contains(artist.down()) && !title.contains(" - ")) {
                    title = "%s - %s".printf(artist, title);
                }
            }

            return strip_script_artifacts(decode_entities(title));
        }

        // ICY metadata often arrives in legacy encodings. GStreamer tends to
        // interpret raw bytes as Latin-1 and emit valid UTF-8 — but with wrong
        // characters (e.g. ³ instead of ł). Detect and fix both cases.
        private string fix_encoding(string text) {
            if (!text.validate()) {
                // Raw non-UTF-8 bytes: try common charsets directly
                string[] charsets = { "WINDOWS-1250", "ISO-8859-2", "WINDOWS-1252", "ISO-8859-1" };
                foreach (var charset in charsets) {
                    try {
                        return GLib.convert(text, (ssize_t) text.length,
                                            "UTF-8", charset);
                    } catch {}
                }
                return text;
            }

            // Valid UTF-8 but possibly Latin-1 mis-interpretation of a legacy
            // Central/Eastern European encoding. Check: does the string have
            // chars in U+0080–U+00FF?
            if (!has_latin1_supplement(text)) return text;

            // Round-trip: UTF-8 → Latin-1 raw bytes → re-decode.
            // Try Windows-1250 first: it's a superset of ISO-8859-2 that also
            // defines the 0x80–0x9F range (e.g. 0x9C = ś) which ISO-8859-2
            // leaves as C1 control characters.
            string[] round_trip_charsets = { "WINDOWS-1250", "ISO-8859-2" };
            try {
                var raw = GLib.convert(text, (ssize_t) text.length,
                                       "ISO-8859-1", "UTF-8");
                foreach (var charset in round_trip_charsets) {
                    try {
                        var fixed = GLib.convert(raw, (ssize_t) raw.length,
                                                 "UTF-8", charset);
                        // Accept only if re-interpretation produced Latin Extended
                        // chars (ł ę ś ź ň etc. are U+0100–U+024F) — strong
                        // signal it was Central/Eastern European text
                        if (fixed.validate() && has_extended_latin(fixed)) {
                            return fixed;
                        }
                    } catch {}
                }
            } catch {}

            return text;
        }

        private bool has_latin1_supplement(string text) {
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (c >= 0x80 && c <= 0xFF) return true;
            }
            return false;
        }

        private bool has_extended_latin(string text) {
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (c >= 0x100 && c <= 0x024F) return true;
            }
            return false;
        }

        // When raw stream bytes coincidentally form valid UTF-8, they can
        // decode to characters from unrelated scripts (e.g. Arabic U+076F
        // from Windows-1250 bytes 0xDD 0xAF). Strip such artifacts when
        // the text is predominantly Latin.
        private string strip_script_artifacts(string text) {
            int latin = 0;
            int foreign = 0;
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (is_latin_letter(c)) {
                    latin++;
                } else if (c > 0x024F && c.isalpha()) {
                    foreign++;
                }
            }

            // Only strip when text is clearly Latin with a few stray chars
            if (latin < 3 || foreign == 0 || foreign * 4 > latin) {
                return text;
            }

            var sb = new StringBuilder.sized(text.length);
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (!(c > 0x024F && c.isalpha())) {
                    sb.append_unichar(c);
                }
            }
            return sb.str;
        }

        private bool is_latin_letter(unichar c) {
            return (c >= 'A' && c <= 'Z') ||
                   (c >= 'a' && c <= 'z') ||
                   (c >= 0x00C0 && c <= 0x00FF && c != 0x00D7 && c != 0x00F7) ||
                   (c >= 0x0100 && c <= 0x024F) ||
                   (c >= 0x1E00 && c <= 0x1EFF);
        }

        private string strip_bom(string text) {
            if (text.has_prefix("\xEF\xBB\xBF")) {
                return text.substring(3);
            }
            if (text.has_prefix("\xFE\xFF") || text.has_prefix("\xFF\xFE")) {
                return text.substring(2);
            }
            return text;
        }

        private string parse_xml(string text) {
            if (!text.has_prefix("<?xml") || xml_artist_regex == null) {
                return text;
            }

            string? artist = null, title = null;
            MatchInfo m;
            if (xml_artist_regex.match(text, 0, out m)) {
                artist = m.fetch(1);
            }
            if (xml_title_regex.match(text, 0, out m)) {
                title = m.fetch(1);
            }

            if (artist != null && title != null) {
                return "%s - %s".printf(artist, title);
            }
            return title ?? artist ?? text;
        }

        private string decode_entities(string text) {
            if (!text.contains("&")) {
                return text;
            }

            // Decode named HTML entities
            var result = text.replace("&amp;", "&")
                             .replace("&apos;", "'")
                             .replace("&quot;", "\"")
                             .replace("&lt;", "<")
                             .replace("&gt;", ">");

            // Decode numeric entities
            if (result.contains("&#") && decimal_regex != null) {
                try {
                    result = decimal_regex.replace_eval(result, -1, 0, 0, (m, b) => {
                        var code = int.parse(m.fetch(1));
                        if (code > 0 && code <= 0x10FFFF) {
                            b.append(((unichar)code).to_string());
                        } else {
                            b.append(m.fetch(0));
                        }
                        return false;
                    });

                    if (hex_regex != null) {
                        result = hex_regex.replace_eval(result, -1, 0, 0, (m, b) => {
                            uint64 code;
                            if (uint64.try_parse("0x" + m.fetch(1), out code) && code <= 0x10FFFF) {
                                b.append(((unichar)code).to_string());
                            } else {
                                b.append(m.fetch(0));
                            }
                            return false;
                        });
                    }
                } catch {
                    // Fall through with named-entity-decoded result
                }
            }
            return result;
        }
    }
}
