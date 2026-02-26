// Artist/title extraction from ICY stream metadata
// Ported from receiver-collect-data/icy_clean.py
namespace Receiver {

    // Result of artist/title extraction
    public struct TrackInfo {
        public string? artist;
        public string? title;

        public bool is_song() {
            return title != null;
        }
    }

    public class MetadataExtractor : Object {
        // Non-song detection patterns
        private Regex[] non_song_patterns;
        // Prefix patterns to strip
        private Regex[] strip_prefixes;
        // Trailing junk patterns
        private Regex trailing_station_re;
        private Regex trailing_url_re;
        private Regex trailing_pipe_url_re;
        private Regex next_re;
        private Regex trailing_junk_re;
        private Regex trailing_dashes_re;
        private Regex track_num_re;
        private Regex freq_prefix_re;
        private Regex multi_spaces_re;
        // Artist/title splitting
        private Regex semicolon_re;
        private Regex slash_re;
        private Regex tight_dash_re;
        private Regex von_re;
        private Regex by_re;
        private Regex tilde_re;
        // Station name detection
        private Regex[] station_artist_patterns;
        private Regex[] non_song_title_patterns;
        private Regex[] non_song_title_only_patterns;
        private Regex url_in_title_re;
        // Artist cleanup
        private Regex featuring_re;
        // Title cleanup
        private Regex title_suffix_re;

        private static MetadataExtractor? _instance;

        public static MetadataExtractor get_default() {
            if (_instance == null) {
                _instance = new MetadataExtractor();
            }
            return _instance;
        }

        private MetadataExtractor() {
            try {
                init_patterns();
            } catch (RegexError e) {
                warning("MetadataExtractor: failed to compile regex: %s", e.message);
            }
        }

        private void init_patterns() throws RegexError {
            // Non-song patterns
            non_song_patterns = {
                // Station IDs and promos
                new Regex("^\\d+\\.\\d+\\s*(?:FM|MHz)\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:live\\s*!?|live broadcast|live on air)$", RegexCompileFlags.CASELESS),
                new Regex("^now\\s+playing\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:song|unknown|\\.\\.|-)$", RegexCompileFlags.CASELESS),
                new Regex("^https?://", RegexCompileFlags.CASELESS),
                new Regex("^mms?://", RegexCompileFlags.CASELESS),
                new Regex("\\bvisit\\b.*\\.(com|net|org)", RegexCompileFlags.CASELESS),
                new Regex("^(?:jingle|commercial|ads)\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:this station|hi-fi internet)\\b", RegexCompileFlags.CASELESS),
                new Regex("^now\\s+on\\s+(?:air|classics)\\b", RegexCompileFlags.CASELESS),
                new Regex("^powered\\s+by\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:streaming|use http|download)\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:no names|now playing info|recording\\s*tone)$", RegexCompileFlags.CASELESS),
                new Regex("^(?:en vivo|en directo|24hs?\\s+en\\s+vivo)$", RegexCompileFlags.CASELESS),
                // Station self-references
                new Regex("^(?:radio\\s+\\w+(?:\\s+\\w+)?(?:\\s+\\d+(?:\\.\\d+)?(?:\\s*(?:FM|AM|MHz))?)?)$", RegexCompileFlags.CASELESS),
                new Regex("^\\w+\\s*(?:FM|AM)\\s*(?:\\d+(?:\\.\\d+)?)?$", RegexCompileFlags.CASELESS),
                new Regex("^\\w+\\s+radio$", RegexCompileFlags.CASELESS),
                new Regex("^www\\.\\w+\\.\\w+", RegexCompileFlags.CASELESS),
                // Technical / placeholder
                new Regex("^[\\da-f]{8}-[\\da-f]{4}-[\\da-f]{4}-[\\da-f]{4}-[\\da-f]{12}$", RegexCompileFlags.CASELESS),
                new Regex("^\\d+$"),
                new Regex("^\\w{1,3}$"),
                new Regex("^AutoDJ\\b", RegexCompileFlags.CASELESS),
                new Regex("^\\d{1,2}:\\d{2}\\s*\\|", RegexCompileFlags.CASELESS),
                new Regex("^(?:ad\\|main|LIVE PRESENTER)\\b", RegexCompileFlags.CASELESS),
            };

            // Prefixes to strip
            strip_prefixes = {
                new Regex("^now\\s+on\\s+air:\\d*\\s*", RegexCompileFlags.CASELESS),
                new Regex("^now\\s+playing\\\\?:\\s*", RegexCompileFlags.CASELESS),
                new Regex("^NOW:\\s*"),
                new Regex("^track:\\s*", RegexCompileFlags.CASELESS),
                new Regex("^TERAZ:\\s*", RegexCompileFlags.CASELESS),
                new Regex("^Jetzt\\s+l[aä]uft:\\s*", RegexCompileFlags.CASELESS),
                new Regex("^AutoDJ:\\s*", RegexCompileFlags.CASELESS),
                new Regex("^LUGARADIO\\\\\\\\\\s*", RegexCompileFlags.CASELESS),
                new Regex("^\\|\\d{2,3}:\\d{2}\\|\\s*", RegexCompileFlags.CASELESS),
                new Regex("^\\d{1,2}:\\d{2}\\s*(?:am|pm)?\\s*-\\s*", RegexCompileFlags.CASELESS),
            };

            // Trailing patterns
            trailing_station_re = new Regex(
                "\\s*\\*{2,}\\s*(?:NEXT:|www\\.).*$" +
                "|\\s*\\|\\s*\\d+\\.\\d+\\s*(?:MHz|FM)\\b.*$" +
                "|\\s*-\\s*(?:GRAFHIT|www\\.)\\S+\\s*(?:-.*)?$" +
                "|\\s*-?\\s*www\\.\\S+\\s*(?:\\(\\d+:\\d+\\))?\\s*$",
                RegexCompileFlags.CASELESS);
            trailing_url_re = new Regex("\\s*\\(?\\s*www\\.\\S+\\)?\\s*$", RegexCompileFlags.CASELESS);
            trailing_pipe_url_re = new Regex("\\s*\\|\\s*https?://\\S+.*$", RegexCompileFlags.CASELESS);
            next_re = new Regex("\\s*[-*]*\\s*NEXT:.*$", RegexCompileFlags.CASELESS);
            trailing_junk_re = new Regex("[\\s*~]+$");
            trailing_dashes_re = new Regex("(?:\\s+-)+\\s*$");
            track_num_re = new Regex("^\\d{1,3}\\s*[-\\.]\\s*");
            freq_prefix_re = new Regex("^\\d+\\.\\d+\\s*(?:FM|MHz)\\s*\\|\\s*", RegexCompileFlags.CASELESS);
            multi_spaces_re = new Regex("\\s{2,}");

            // Tilde-delimited metadata
            tilde_re = new Regex("^(.+?)~(.+?)~~");

            // Artist/title splitting
            semicolon_re = new Regex("^(.+?)\\s*;\\s*(.+)$");
            slash_re = new Regex("^(.+?)\\s*/\\s*(.+)$");
            tight_dash_re = new Regex("^([A-Za-z\\x{00C0}-\\x{024F}].{1,}?)-([A-Za-z\\x{00C0}-\\x{024F}].{1,})$");
            von_re = new Regex("^(.+?)\\s+von\\s+(.+)$", RegexCompileFlags.CASELESS);
            by_re = new Regex("^(.+?)\\s+by\\s+(.+)$", RegexCompileFlags.CASELESS);

            // Station name detection (artist side)
            station_artist_patterns = {
                new Regex("\\bradio\\b", RegexCompileFlags.CASELESS),
                new Regex("\\bFM\\b"),
                new Regex("\\.(?:com|net|org|fm|am|today)\\b", RegexCompileFlags.CASELESS),
                new Regex("\\bstation\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:Airtime|LibreTime)$", RegexCompileFlags.CASELESS),
            };

            // Non-song title patterns (when artist looks like a station)
            non_song_title_patterns = {
                new Regex("^(?:offline|on\\s*air|en\\s+vivo|nonstop|non.stop|tune!?|live)$", RegexCompileFlags.CASELESS),
                new Regex("^\\d+(?:\\.\\d+)?\\s*(?:FM|MHz|AM|khz)\\b", RegexCompileFlags.CASELESS),
                new Regex("^(?:we play hits|sounds like you|upgrade to premium)$", RegexCompileFlags.CASELESS),
                new Regex("^\\d+(?:\\.\\d+)?$"),
            };

            url_in_title_re = new Regex("(?:www\\.|https?://)", RegexCompileFlags.CASELESS);

            // Artist cleanup: strip [+] VOCALIST, feat., ft., (feat ...) etc.
            featuring_re = new Regex(
                "\\s*(?:" +
                    "\\[\\+\\]\\s*.*" +
                    "|\\s+feat\\.?\\s+.*" +
                    "|\\s+ft\\.?\\s+.*" +
                    "|\\s*\\(feat\\.?[^)]*\\)" +
                    "|\\s*\\(ft\\.?[^)]*\\)" +
                ")\\s*$",
                RegexCompileFlags.CASELESS);

            // Title suffixes to strip for cleaner scrobbles
            title_suffix_re = new Regex(
                "\\s*\\((?:Live|Remaster(?:ed)?|Bonus Track|Radio Edit|Single Version|Album Version|Acoustic)[^)]*\\)\\s*$",
                RegexCompileFlags.CASELESS);

            // Title-only non-song patterns
            non_song_title_only_patterns = {
                new Regex("\\bradio\\b", RegexCompileFlags.CASELESS),
                new Regex("\\b\\d+\\.\\d+\\s*(?:FM|MHz|AM)\\b", RegexCompileFlags.CASELESS),
                new Regex("\\bFM\\b"),
                new Regex("\\.com\\b", RegexCompileFlags.CASELESS),
                new Regex("^[A-Z\\s\\d]{4,}$"),
                new Regex("\\d{4}-\\d{2}-\\d{2}", RegexCompileFlags.CASELESS),
                new Regex("^\\w+FM$", RegexCompileFlags.CASELESS),
                new Regex("^(?:Commercial|Reklama|PUBBLICITA)\\b", RegexCompileFlags.CASELESS),
                new Regex("^No Names", RegexCompileFlags.CASELESS),
            };
        }

        /**
         * Clean ICY metadata — strip prefixes, trailing junk, etc.
         * Already-cleaned by MetadataParser (encoding, HTML entities, XML).
         */
        public string clean(string raw) {
            if (raw == null || raw.strip() == "") return "";

            var text = raw.strip();

            // Handle tilde-delimited: "Title~Artist~~Year~~BPM~..."
            MatchInfo m;
            if (tilde_re.match(text, 0, out m)) {
                var rest = text.substring(m.fetch(0).length);
                if (rest.contains("~")) {
                    var title_part = m.fetch(1).strip();
                    var artist_part = m.fetch(2).strip();
                    if (artist_part != "" && title_part != "") {
                        return "%s - %s".printf(artist_part, title_part);
                    }
                    return title_part != "" ? title_part : artist_part;
                }
            }

            // Handle tab-separated: "artist\ttitle"
            if (text.contains("\t") && !text.contains(" - ")) {
                text = text.replace("\t", " - ");
            }

            // Strip known prefixes
            foreach (var prefix_re in strip_prefixes) {
                try {
                    text = prefix_re.replace(text, -1, 0, "");
                } catch {}
            }

            // Strip frequency prefix like "94.5 FM | "
            try { text = freq_prefix_re.replace(text, -1, 0, ""); } catch {}

            // Strip trailing decorators (*, ~, whitespace)
            try { text = trailing_junk_re.replace(text, -1, 0, ""); } catch {}

            // Strip trailing lone dashes
            try { text = trailing_dashes_re.replace(text, -1, 0, ""); } catch {}

            // Strip trailing station info/URLs
            try { text = trailing_station_re.replace(text, -1, 0, ""); } catch {}
            try { text = trailing_url_re.replace(text, -1, 0, ""); } catch {}
            try { text = trailing_pipe_url_re.replace(text, -1, 0, ""); } catch {}
            try { text = next_re.replace(text, -1, 0, ""); } catch {}

            // Strip leading ". - " or "- "
            if (text.has_prefix(". - ")) {
                text = text.substring(4);
            } else if (text.has_prefix("- ")) {
                text = text.substring(2);
            }

            // Remove leading track numbers
            try { text = track_num_re.replace(text, -1, 0, ""); } catch {}

            // Collapse multiple spaces
            try { text = multi_spaces_re.replace(text, -1, 0, " "); } catch {}

            return text.strip();
        }

        /**
         * Extract artist and title from cleaned ICY metadata.
         * Returns TrackInfo with artist=null, title=null for non-song content.
         */
        public TrackInfo extract_artist_title(string cleaned) {
            TrackInfo result = { null, null };

            if (cleaned == "" || cleaned == "-" || cleaned == "..") {
                return result;
            }

            // Detect non-song content
            foreach (var pat in non_song_patterns) {
                if (pat.match(cleaned, 0, null)) {
                    return result;
                }
            }

            MatchInfo m;

            // Primary: split on " - " (most common separator)
            if (cleaned.contains(" - ")) {
                var parts = cleaned.split(" - ", 2);
                var artist = parts[0].strip();
                var title = parts[1].strip();
                if (artist != "" && title != "") {
                    // Strip repeated artist: "ACDC - ACDC - Squealer"
                    var prefix = artist + " - ";
                    var prefix_lower = prefix.down();
                    if (title.down().has_prefix(prefix_lower)) {
                        title = title.substring(prefix.length).strip();
                    }
                    // Station prefix: re-split title for real artist/title
                    if (looks_like_station_name(artist) && title.contains(" - ")) {
                        return extract_artist_title(title);
                    }
                    if (looks_like_station(artist, title)) {
                        return result;
                    }
                    result.artist = clean_artist(artist);
                    result.title = clean_title(title);
                    return result;
                }
            }

            // " -- " separator
            if (cleaned.contains(" -- ")) {
                var parts = cleaned.split(" -- ", 2);
                var artist = parts[0].strip();
                var title = parts[1].strip();
                if (artist != "" && title != "") {
                    result.artist = clean_artist(artist);
                    result.title = clean_title(title);
                    return result;
                }
            }

            // Semicolon separator: "TITLE;ARTIST"
            if (semicolon_re.match(cleaned, 0, out m)) {
                var title_part = m.fetch(1).strip();
                var artist_part = m.fetch(2).strip();
                if (artist_part != "" && title_part != "") {
                    result.artist = clean_artist(artist_part);
                    result.title = clean_title(title_part);
                    return result;
                }
            }

            // Slash separator: "ARTIST / TITLE"
            if (slash_re.match(cleaned, 0, out m)) {
                var left = m.fetch(1).strip();
                var right = m.fetch(2).strip();
                if (left != "" && right != "") {
                    result.artist = clean_artist(left);
                    result.title = clean_title(right);
                    return result;
                }
            }

            // German "von" separator: "TITLE von ARTIST"
            if (von_re.match(cleaned, 0, out m)) {
                var title_part = m.fetch(1).strip();
                var artist_part = m.fetch(2).strip();
                if (artist_part != "" && title_part != "") {
                    result.artist = clean_artist(artist_part);
                    result.title = clean_title(title_part);
                    return result;
                }
            }

            // "by" separator: "Title by Artist"
            if (by_re.match(cleaned, 0, out m)) {
                var title_part = m.fetch(1).strip();
                var artist_part = m.fetch(2).strip();
                // Only use if artist is multi-word
                if (artist_part != "" && artist_part.split(" ").length >= 2) {
                    result.artist = clean_artist(artist_part);
                    result.title = clean_title(title_part);
                    return result;
                }
            }

            // Tight dash: "Danny Romero-Peligrosa"
            if (tight_dash_re.match(cleaned, 0, out m)) {
                var left = m.fetch(1).strip();
                var right = m.fetch(2).strip();
                if (left.length >= 2 && right.length >= 2) {
                    result.artist = clean_artist(left);
                    result.title = clean_title(right);
                    return result;
                }
            }

            // No separator found — check if it looks like a song at all
            if (looks_like_non_song_title(cleaned)) {
                return result;
            }

            // Title only, no artist
            result.title = cleaned;
            return result;
        }

        private bool looks_like_station_name(string artist) {
            foreach (var pat in station_artist_patterns) {
                if (pat.match(artist, 0, null)) return true;
            }
            return false;
        }

        private bool looks_like_station(string artist, string title) {
            if (!looks_like_station_name(artist)) return false;

            foreach (var pat in non_song_title_patterns) {
                if (pat.match(title, 0, null)) return true;
            }

            if (url_in_title_re.match(title, 0, null)) return true;
            if (artist.down().strip() == title.down().strip()) return true;

            return false;
        }

        private bool looks_like_non_song_title(string text) {
            foreach (var pat in non_song_title_only_patterns) {
                if (pat.match(text, 0, null)) return true;
            }
            return false;
        }

        /**
         * Strip featuring tags from artist: [+] VOCALIST, feat., ft., etc.
         */
        private string clean_artist(string artist) {
            try {
                var cleaned = featuring_re.replace(artist, -1, 0, "").strip();
                return cleaned != "" ? cleaned : artist;
            } catch {
                return artist;
            }
        }

        /**
         * Strip (Live), (Remastered) etc. from title.
         */
        private string clean_title(string title) {
            try {
                var cleaned = title_suffix_re.replace(title, -1, 0, "").strip();
                return cleaned != "" ? cleaned : title;
            } catch {
                return title;
            }
        }
    }
}
