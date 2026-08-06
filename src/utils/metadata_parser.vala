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
        // characters (e.g. ³ instead of ł, ąÚą®żµ instead of Korean Hangul).
        // Detect and fix both cases.
        private string fix_encoding(string text) {
            if (!text.validate()) {
                // Raw non-UTF-8 bytes: try East Asian charsets first (they're
                // more distinctive), then Cyrillic and Western European ones.
                // Among the conversions that succeed, keep the most plausible.
                string[] charsets = {
                    "EUC-KR", "CP949", "EUC-JP", "SHIFT_JIS", "GB18030",
                    "WINDOWS-1251",
                    "WINDOWS-1250", "ISO-8859-2", "WINDOWS-1252", "ISO-8859-1"
                };
                string? best = null;
                double best_score = 0;
                foreach (var charset in charsets) {
                    try {
                        var candidate = GLib.convert(text, (ssize_t) text.length,
                                                     "UTF-8", charset);
                        if (!candidate.validate()) continue;
                        var score = script_plausibility(candidate);
                        if (best == null || score > best_score) {
                            best = candidate;
                            best_score = score;
                        }
                    } catch {}
                }
                return best ?? text;
            }

            // Valid UTF-8 but possibly Latin-1 mis-interpretation of a legacy
            // encoding. Check: does the string have chars in U+0080–U+00FF?
            if (!has_high_run(text, 1)) return text;

            // Round-trip: UTF-8 → Latin-1 raw bytes → re-decode as candidate charsets.
            try {
                var raw = GLib.convert(text, (ssize_t) text.length,
                                       "ISO-8859-1", "UTF-8");

                // East Asian charsets: EUC-KR/CP949 (Korean), EUC-JP/Shift-JIS (Japanese),
                // GB18030 (Chinese). Accept if result contains CJK/Hangul characters
                // from one dominant script. Real East Asian mojibake is a run of
                // high bytes; a couple of adjacent accented letters ("SÄÄ") is not.
                if (has_high_run(text, 4)) {
                    string[] ea_charsets = { "EUC-KR", "CP949", "EUC-JP", "SHIFT_JIS", "GB18030" };
                    foreach (var charset in ea_charsets) {
                        try {
                            var fixed = GLib.convert(raw, (ssize_t) raw.length,
                                                     "UTF-8", charset);
                            if (fixed.validate() && has_cjk(fixed)
                                && script_plausibility(fixed) >= MIN_SCRIPT_DOMINANCE) {
                                return fixed;
                            }
                        } catch {}
                    }
                }

                // Central/Eastern European: Windows-1250 is a superset of ISO-8859-2
                // that also defines the 0x80–0x9F range (e.g. 0x9C = ś).
                // Accept if result contains Latin Extended chars (U+0100–U+024F).
                string[] ce_charsets = { "WINDOWS-1250", "ISO-8859-2" };
                foreach (var charset in ce_charsets) {
                    try {
                        var fixed = GLib.convert(raw, (ssize_t) raw.length,
                                                 "UTF-8", charset);
                        if (fixed.validate() && has_extended_latin(fixed)
                            && script_plausibility(fixed) >= MIN_SCRIPT_DOMINANCE) {
                            return fixed;
                        }
                    } catch {}
                }
            } catch {}

            return text;
        }

        // Minimum fraction of non-ASCII letters that must belong to a single
        // script for a converted candidate to be considered plausible.
        private const double MIN_SCRIPT_DOMINANCE = 0.8;

        // Fraction (0-1) of non-ASCII letters belonging to the dominant
        // script. Real text is dominated by one script; a mixed-script
        // salad signals a wrong charset guess.
        private double script_plausibility(string text) {
            // Han, Hiragana/Katakana, Hangul, Cyrillic, Latin-1/Extended.
            int[] counts = new int[5];
            int total = 0;
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (c < 0x80 || !c.isalpha()) continue;
                total++;
                if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF)) {
                    counts[0]++;
                } else if (c >= 0x3040 && c <= 0x30FF) {
                    counts[1]++;
                } else if ((c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x1100 && c <= 0x11FF)) {
                    counts[2]++;
                } else if (c >= 0x0400 && c <= 0x04FF) {
                    counts[3]++;
                } else if (c >= 0x00C0 && c <= 0x024F) {
                    counts[4]++;
                }
            }
            if (total == 0) return 1.0;
            int best = 0;
            foreach (var n in counts) {
                best = int.max(best, n);
            }
            return (double) best / total;
        }

        // True if text contains `n` or more consecutive chars in U+0080–U+00FF.
        private bool has_high_run(string text, int n) {
            int run = 0;
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                if (c >= 0x80 && c <= 0xFF) {
                    run++;
                    if (run >= n) return true;
                } else {
                    run = 0;
                }
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

        // Returns true if text contains CJK Unified Ideographs, Hangul, or
        // Hiragana/Katakana — strong signal for East Asian encoding.
        private bool has_cjk(string text) {
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                // Hangul syllables (AC00–D7A3), Hangul Jamo (1100–11FF)
                if (c >= 0xAC00 && c <= 0xD7A3) return true;
                if (c >= 0x1100 && c <= 0x11FF) return true;
                // CJK Unified Ideographs (4E00–9FFF) + Extension A (3400–4DBF)
                if (c >= 0x3400 && c <= 0x9FFF) return true;
                // Hiragana (3040–309F) + Katakana (30A0–30FF)
                if (c >= 0x3040 && c <= 0x30FF) return true;
            }
            return false;
        }

        // When raw stream bytes coincidentally form valid UTF-8, they can
        // decode to characters from unrelated scripts (e.g. Arabic U+076F
        // from Windows-1250 bytes 0xDD 0xAF). Strip such artifacts when
        // the text is predominantly Latin.
        private string strip_script_artifacts(string text) {
            unichar[] chars = {};
            unichar c;
            for (int i = 0; text.get_next_char(ref i, out c);) {
                chars += c;
            }

            int latin = 0;
            bool[] foreign = new bool[chars.length];
            for (int i = 0; i < chars.length; i++) {
                if (is_latin_letter(chars[i])) {
                    latin++;
                } else if (chars[i] > 0x024F && chars[i].isalpha()) {
                    foreign[i] = true;
                }
            }

            // Runs of 2+ foreign chars are real text (e.g. a kana span in a
            // Latin title); only isolated single stray chars are artifacts.
            int isolated = 0;
            bool[] strip = new bool[chars.length];
            for (int i = 0; i < chars.length; i++) {
                if (foreign[i]
                    && !(i > 0 && foreign[i - 1])
                    && !(i + 1 < chars.length && foreign[i + 1])) {
                    strip[i] = true;
                    isolated++;
                }
            }

            // Only strip when text is clearly Latin with a few stray chars
            if (latin < 3 || isolated == 0 || isolated * 4 > latin) {
                return text;
            }

            var sb = new StringBuilder.sized(text.length);
            for (int i = 0; i < chars.length; i++) {
                if (!strip[i]) {
                    sb.append_unichar(chars[i]);
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

            // Decode named HTML entities; &amp; last so double-escaped
            // input ("&amp;quot;") doesn't double-unescape.
            var result = text.replace("&apos;", "'")
                             .replace("&quot;", "\"")
                             .replace("&lt;", "<")
                             .replace("&gt;", ">")
                             .replace("&amp;", "&");

            // Decode numeric entities
            if (result.contains("&#") && decimal_regex != null) {
                try {
                    result = decimal_regex.replace_eval(result, -1, 0, 0, (m, b) => {
                        var code = int.parse(m.fetch(1));
                        if (code > 0 && code <= 0x10FFFF
                            && !(code >= 0xD800 && code <= 0xDFFF)) {
                            b.append(((unichar)code).to_string());
                        } else {
                            b.append(m.fetch(0));
                        }
                        return false;
                    });

                    if (hex_regex != null) {
                        result = hex_regex.replace_eval(result, -1, 0, 0, (m, b) => {
                            uint64 code;
                            if (uint64.try_parse("0x" + m.fetch(1), out code) && code <= 0x10FFFF
                                && !(code >= 0xD800 && code <= 0xDFFF)) {
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
