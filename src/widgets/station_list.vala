// Browse tab — station list with inline search, filters, and genre pills
namespace Receiver {

    public class StationList : Gtk.Box {
        private StationStore store;
        private Gtk.SearchEntry search_entry;
        private Gtk.DropDown language_dropdown;
        private Gtk.DropDown country_dropdown;
        private Gtk.ListView list_view;
        private Gtk.Spinner spinner;
        private Gtk.Label status_label;
        private Adw.StatusPage empty_page;
        private Gtk.Stack stack;
        private string[] languages;
        private string[] country_codes;
        private Gtk.Box genre_box_ref;

        private bool restoring = false;

        public signal void station_activated(Station station);

        private const string[] GENRES = {
            "pop", "kpop", "rock", "jazz", "classical", "electronic", "dance",
            "hits", "70s", "80s", "90s", "oldies", "chill",
            "news", "talk", "sports",
            "alternative", "indie", "metal", "punk",
            "house", "hiphop", "latin", "soul", "blues", "folk",
            "country", "reggae", "disco"
        };

        public StationList(StationStore station_store) {
            Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            this.store = station_store;
            build_ui();
            connect_signals();
        }




        private void build_ui() {
            // Search entry
            search_entry = new Gtk.SearchEntry();
            search_entry.placeholder_text = _("Search stations…");
            search_entry.hexpand = true;
            search_entry.margin_start = search_entry.margin_end = 12;
            search_entry.margin_top = 8;
            this.append(search_entry);

            // Filter row: language + country dropdowns
            var filter_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            filter_row.margin_start = filter_row.margin_end = 12;
            filter_row.margin_top = 8;
            filter_row.homogeneous = true;

            language_dropdown = new Gtk.DropDown(new Gtk.StringList({_("All Languages")}), null);
            language_dropdown.tooltip_text = _("Filter by language");
            filter_row.append(language_dropdown);

            country_dropdown = new Gtk.DropDown(new Gtk.StringList({_("All Countries")}), null);
            country_dropdown.tooltip_text = _("Filter by country");
            filter_row.append(country_dropdown);

            this.append(filter_row);

            // Genre pills — horizontal scrollable strip (1 row)
            var genre_scroll = new Gtk.ScrolledWindow();
            genre_scroll.hscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            //  genre_scroll.overlay_scrolling = false; // Scrollbar below pills, not on top
            genre_scroll.vscrollbar_policy = Gtk.PolicyType.NEVER;
            genre_scroll.margin_start = genre_scroll.margin_end = 12;
            genre_scroll.margin_top = 8;
            
            // Map vertical scroll wheel to horizontal scrolling since GTK4 doesn't natively cross-scroll
            var scroll_ctrl = new Gtk.EventControllerScroll(Gtk.EventControllerScrollFlags.VERTICAL);
            scroll_ctrl.scroll.connect((dx, dy) => {
                var adj = genre_scroll.hadjustment;
                adj.value += dy * 40.0;
                return true;
            });
            genre_scroll.add_controller(scroll_ctrl);

            var genre_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            genre_box.margin_bottom = 6; // Space between pills and scrollbar
            genre_box_ref = genre_box;

            foreach (var g in GENRES) {
                var tile = new Gtk.Button();
                tile.add_css_class("pill");
                tile.add_css_class("suggested-action");
                tile.add_css_class("compact"); // Reduces internal padding significantly without custom CSS
                tile.child = new Gtk.Label(g.substring(0, 1).up() + g.substring(1));
                tile.clicked.connect(() => {
                    search_entry.text = g;
                });
                genre_box.append(tile);
            }

            genre_scroll.child = genre_box;
            this.append(genre_scroll);

            // Status row
            var status_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            status_row.halign = Gtk.Align.CENTER;
            status_row.margin_top = status_row.margin_bottom = 6;
            spinner = new Gtk.Spinner();
            status_row.append(spinner);
            status_label = new Gtk.Label("");
            status_label.add_css_class("dim-label");
            status_row.append(status_label);
            this.append(status_row);

            // Empty state
            empty_page = new Adw.StatusPage();
            empty_page.icon_name = "audio-x-generic-symbolic";
            empty_page.title = _("No Stations");

            // Station list
            var factory = new Gtk.SignalListItemFactory();
            factory.setup.connect((f, o) => {
                ((Gtk.ListItem)o).child = new StationRow();
            });
            factory.bind.connect((f, o) => {
                var li = (Gtk.ListItem)o;
                ((StationRow)li.child).bind((Station)li.item);
            });
            factory.unbind.connect((f, o) => {
                ((StationRow)((Gtk.ListItem)o).child).unbind();
            });

            var sel = new Gtk.SingleSelection(store);
            sel.autoselect = false;
            sel.can_unselect = true;
            list_view = new Gtk.ListView(sel, factory);
            list_view.single_click_activate = true;
            list_view.add_css_class("navigation-sidebar");
            list_view.margin_start = list_view.margin_end = 12;
            list_view.margin_bottom = 12;

            var scrolled = new Gtk.ScrolledWindow();
            scrolled.vexpand = true;
            scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scrolled.child = list_view;

            stack = new Gtk.Stack();
            stack.add_named(empty_page, "empty");
            stack.add_named(scrolled, "list");
            stack.visible_child_name = "empty";
            this.append(stack);

            store.items_changed.connect(() => {
                update_empty();
            });
        }


        private void connect_signals() {
            var settings = AppState.get_default().settings;
            settings.bind("language-filter", store, "language-filter", SettingsBindFlags.DEFAULT);
            settings.bind("country-filter", store, "country-filter", SettingsBindFlags.DEFAULT);

            uint timeout = 0;
            search_entry.search_changed.connect(() => {
                if (timeout > 0) Source.remove(timeout);
                timeout = Timeout.add(300, () => {
                    store.search_query = search_entry.text;
                    scroll_to_top();
                    timeout = 0;
                    return false;
                });
            });

            language_dropdown.notify["selected"].connect(() => {
                if (restoring) return;
                uint sel = language_dropdown.selected;
                store.language_filter = (sel == 0 || languages == null) ? "all" : languages[sel - 1];
                scroll_to_top();
            });

            country_dropdown.notify["selected"].connect(() => {
                if (restoring) return;
                uint sel = country_dropdown.selected;
                store.country_filter = (sel == 0 || country_codes == null) ? "all" : country_codes[sel - 1];
                scroll_to_top();
            });

            store.loading_started.connect(() => {
                spinner.spinning = true;
                status_label.label = _("Loading…");
            });

            store.loading_finished.connect((c) => {
                spinner.spinning = false;
                populate_langs();
                populate_countries();
                add_local_pill();
                restore_state();
                update_status();
            });

            store.items_changed.connect(() => {
                update_status();
            });

            list_view.activate.connect((p) => {
                var s = store.get_item(p) as Station;
                if (s != null) {
                    station_activated(s);
                }
            });
        }

        private void populate_langs() {
            restoring = true;
            var codes = store.get_available_languages();

            // Sort by translated name alphabetically
            var sorted = new GenericArray<string>();
            for (int i = 0; i < codes.length; i++) {
                sorted.add(codes[i]);
            }
            sorted.sort_with_data((a, b) => {
                return Languages.translate(a).collate(Languages.translate(b));
            });

            languages = sorted.data;
            var labels = new string[languages.length + 1];
            labels[0] = _("All Languages");
            for (int i = 0; i < languages.length; i++) {
                labels[i + 1] = Languages.translate(languages[i]);
            }
            language_dropdown.model = new Gtk.StringList(labels);
            restoring = false;
        }

        private void populate_countries() {
            restoring = true;
            country_codes = store.get_available_country_codes();
            var names = store.get_available_country_names();
            var labels = new string[country_codes.length + 1];
            labels[0] = _("All Countries");
            for (int i = 0; i < country_codes.length; i++) {
                labels[i + 1] = names[i];
            }
            country_dropdown.model = new Gtk.StringList(labels);
            restoring = false;
        }

        private void add_local_pill() {
            if (genre_box_ref == null) return;
            var country_name = store.get_locale_country_name();
            if (country_name == null) return;
            var local_tile = new Gtk.Button();
            local_tile.add_css_class("pill");
            local_tile.add_css_class("suggested-action");
            local_tile.add_css_class("compact"); // Reduces internal padding significantly without custom CSS
            local_tile.child = new Gtk.Label(country_name);
            local_tile.clicked.connect(() => {
                search_entry.text = country_name;
            });
            genre_box_ref.prepend(local_tile);
        }

        private void restore_state() {
            restoring = true;
            // Restore dropdown selections from persisted GSettings
            if (store.language_filter != "all" && languages != null) {
                for (int i = 0; i < languages.length; i++) {
                    if (languages[i] == store.language_filter) {
                        language_dropdown.selected = (uint)(i + 1);
                        break;
                    }
                }
            }
            if (store.country_filter != "all" && country_codes != null) {
                for (int i = 0; i < country_codes.length; i++) {
                    if (country_codes[i] == store.country_filter) {
                        country_dropdown.selected = (uint)(i + 1);
                        break;
                    }
                }
            }
            restoring = false;
        }

        private void update_status() {
            uint filtered = store.get_n_items();
            int total = store.total_count;
            bool has_filter = search_entry.text != ""
                || store.language_filter != "all"
                || store.country_filter != "all";
            status_label.label = has_filter && filtered < total
                ? _("%u of %d stations").printf(filtered, total)
                : _("Stations: %d").printf(total);
        }

        private void scroll_to_top() {
            if (store.get_n_items() > 0) {
                list_view.scroll_to(0, Gtk.ListScrollFlags.NONE, null);
            }
        }

        private void update_empty() {
            if (store.get_n_items() == 0) {
                empty_page.title = store.is_loading
                    ? _("Loading Stations")
                    : (search_entry.text != "" ? _("No Results") : _("No Stations"));
                empty_page.description = store.is_loading
                    ? _("Please wait…")
                    : (search_entry.text != "" ? _("No stations match your search") : _("Could not load stations"));
                stack.visible_child_name = "empty";
            } else {
                stack.visible_child_name = "list";
            }
        }
    }

    public class StationRow : Gtk.Box {
        private Gtk.Picture artwork;
        private Gtk.Stack image_stack;
        private Gtk.Label title_label;
        private Gtk.Label subtitle_label;
        private Gtk.Image status_icon;
        private Gtk.Button fav_button;
        private Station? station;
        private ulong failed_id;
        private ulong cleared_id;
        private ulong fav_id;
        private ulong scroll_id;
        private uint load_timeout;

        public StationRow() {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 12);
            margin_top = margin_bottom = 8;
            margin_start = margin_end = 4;
            build_ui();
        }

        private void build_ui() {
            image_stack = new Gtk.Stack();
            image_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            var ph = new Gtk.Image.from_icon_name("audio-x-generic-symbolic");
            ph.set_size_request(48, 48);
            ph.pixel_size = 32;
            ph.add_css_class("dim-label");
            image_stack.add_named(ph, "placeholder");
            artwork = new Gtk.Picture();
            artwork.set_size_request(48, 48);
            artwork.content_fit = Gtk.ContentFit.COVER;
            var frame = new Gtk.Frame(null);
            frame.child = artwork;
            frame.add_css_class("circular");
            frame.overflow = Gtk.Overflow.HIDDEN;
            frame.set_size_request(48, 48);
            image_stack.add_named(frame, "artwork");
            this.append(image_stack);

            var text = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text.valign = Gtk.Align.CENTER;
            text.hexpand = true;
            title_label = new Gtk.Label("");
            title_label.xalign = 0;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.lines = 1;
            title_label.add_css_class("heading");
            text.append(title_label);
            subtitle_label = new Gtk.Label("");
            subtitle_label.xalign = 0;
            subtitle_label.ellipsize = Pango.EllipsizeMode.END;
            subtitle_label.lines = 1;
            subtitle_label.add_css_class("dim-label");
            subtitle_label.add_css_class("caption");
            text.append(subtitle_label);
            this.append(text);

            fav_button = new Gtk.Button();
            fav_button.add_css_class("flat");
            fav_button.add_css_class("circular");
            fav_button.valign = Gtk.Align.CENTER;
            fav_button.icon_name = "non-starred-symbolic";
            fav_button.clicked.connect(() => {
                if (station != null) {
                    var a = GLib.Application.get_default() as Application;
                    if (a != null) {
                        a.store.toggle_favourite(station);
                    }
                }
            });
            this.append(fav_button);

            status_icon = new Gtk.Image.from_icon_name("media-playback-start-symbolic");
            status_icon.add_css_class("dim-label");
            status_icon.valign = Gtk.Align.CENTER;
            this.append(status_icon);
        }

        public void bind(Station s) {
            station = s;
            title_label.label = s.name;
            subtitle_label.label = s.get_subtitle();

            var app = GLib.Application.get_default() as Application;
            if (app != null) {
                var failed = app.store.is_station_failed(s.id);
                status_icon.icon_name = failed ? "action-unavailable-symbolic" : "media-playback-start-symbolic";
                if (failed) {
                    status_icon.remove_css_class("dim-label");
                    status_icon.add_css_class("warning");
                } else {
                    status_icon.remove_css_class("warning");
                    status_icon.add_css_class("dim-label");
                }

                failed_id = app.store.station_failed.connect((id) => {
                    if (station != null && station.id == id) {
                        status_icon.icon_name = "action-unavailable-symbolic";
                        status_icon.remove_css_class("dim-label");
                        status_icon.add_css_class("warning");
                    }
                });

                cleared_id = app.store.station_cleared.connect((id) => {
                    if (station != null && station.id == id) {
                        status_icon.icon_name = "media-playback-start-symbolic";
                        status_icon.remove_css_class("warning");
                        status_icon.add_css_class("dim-label");
                    }
                });

                update_fav(app.store.is_favourite(s.id));
                fav_id = app.store.favourites_changed.connect(() => {
                    if (station != null) {
                        update_fav(app.store.is_favourite(station.id));
                    }
                });
            }

            if (s.image_hash != 0) {
                // Try sync disk cache first to avoid placeholder flash on rebind
                var cached_path = ImageLoader.get_default().get_cache_path(s.image_hash);
                if (FileUtils.test(cached_path, FileTest.EXISTS)) {
                    try {
                        artwork.paintable = Gdk.Texture.for_pixbuf(new Gdk.Pixbuf.from_file(cached_path));
                        image_stack.visible_child_name = "artwork";
                    } catch {
                        image_stack.visible_child_name = "placeholder";
                    }
                } else {
                    image_stack.visible_child_name = "placeholder";
                    if (load_timeout > 0) Source.remove(load_timeout);
                    load_timeout = Timeout.add(150, () => {
                        load_timeout = 0;
                        if (station == s) maybe_load_artwork(s);
                        return false;
                    });
                }
            } else {
                image_stack.visible_child_name = "placeholder";
            }
        }

        public void unbind() {
            if (load_timeout > 0) {
                Source.remove(load_timeout);
                load_timeout = 0;
            }
            disconnect_scroll();
            var app = GLib.Application.get_default() as Application;
            if (app != null) {
                if (failed_id > 0) {
                    app.store.disconnect(failed_id);
                    failed_id = 0;
                }
                if (cleared_id > 0) {
                    app.store.disconnect(cleared_id);
                    cleared_id = 0;
                }
                if (fav_id > 0) {
                    app.store.disconnect(fav_id);
                    fav_id = 0;
                }
            }
            station = null;
            artwork.paintable = null;
        }

        private void update_fav(bool is_fav) {
            fav_button.icon_name = is_fav ? "starred-symbolic" : "non-starred-symbolic";
        }

        private void maybe_load_artwork(Station s) {
            if (station != s) return;

            if (get_height() > 0) {
                load_artwork.begin(s);
                return;
            }

            // Not yet laid out: wait for scroll to trigger layout
            var sw = get_ancestor(typeof(Gtk.ScrolledWindow)) as Gtk.ScrolledWindow;
            if (sw != null && scroll_id == 0 && sw.vadjustment != null) {
                scroll_id = sw.vadjustment.value_changed.connect(() => {
                    if (station != s) {
                        disconnect_scroll();
                        return;
                    }
                    if (get_height() > 0) {
                        disconnect_scroll();
                        load_artwork.begin(s);
                    }
                });
            }
        }

        private void disconnect_scroll() {
            if (scroll_id > 0) {
                var sw = get_ancestor(typeof(Gtk.ScrolledWindow)) as Gtk.ScrolledWindow;
                if (sw != null && sw.vadjustment != null) {
                    sw.vadjustment.disconnect(scroll_id);
                }
                scroll_id = 0;
            }
        }

        private async void load_artwork(Station s) {
            var tex = yield ImageLoader.get_default().load(s.image_hash);
            if (station == s && tex != null) {
                artwork.paintable = tex;
                image_stack.visible_child_name = "artwork";
            }
        }
    }
}
