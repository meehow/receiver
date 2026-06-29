APP_ID = io.github.meehow.Receiver
MANIFEST = $(APP_ID).yml
LINUXDEPLOY = linuxdeploy-x86_64.AppImage
LINUXDEPLOY_URL = https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/$(LINUXDEPLOY)
LINUXDEPLOY_GTK = linuxdeploy-plugin-gtk.sh
LINUXDEPLOY_GTK_URL = https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/$(LINUXDEPLOY_GTK)
APPDIR = AppDir
GST_LIBDIR = /usr/lib/x86_64-linux-gnu/gstreamer-1.0
GST_SCANNER = /usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner
VERSION = $(shell grep "version:" meson.build | head -1 | sed "s/.*'\(.*\)'.*/\1/")

.PHONY: build install clean deb run run-tui appimage \
        flatpak-build flatpak-run flatpak-lint-manifest flatpak-lint-repo flatpak-submit \
        translations-check translations-update

_build:
	meson setup _build --prefix=/usr --buildtype=release

build: _build
	meson compile -C _build

install: build
	meson install -C _build

clean:
	rm -rf _build

run: build
	glib-compile-schemas data/
	GSETTINGS_SCHEMA_DIR=$(CURDIR)/data \
	XDG_DATA_DIRS=$(CURDIR)/data:/usr/share \
	LOCALEDIR=$(CURDIR)/_build/po \
	./_build/receiver

run-tui: build
	glib-compile-schemas data/
	GSETTINGS_SCHEMA_DIR=$(CURDIR)/data \
	XDG_DATA_DIRS=$(CURDIR)/data:/usr/share \
	LOCALEDIR=$(CURDIR)/_build/po \
	./_build/receiver-tui

deb:
	dpkg-buildpackage -us -uc -b

translations-check:
	@for file in po/*.po; do \
		echo -n "$$file: "; \
		msgfmt --statistics -o /dev/null $$file; \
	done

translations-update: _build
	meson compile -C _build receiver-pot
	meson compile -C _build receiver-update-po

translations-prune:
	@for file in po/*.po; do \
		echo -n "Pruning $$file... "; \
		msgattrib --no-obsolete -o $$file.tmp $$file && mv $$file.tmp $$file; \
		echo "Done"; \
	done

flatpak-build:
	flatpak run --command=flathub-build org.flatpak.Builder --install $(MANIFEST)

flatpak-run:
	flatpak run $(APP_ID)

flatpak-lint:
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest $(MANIFEST)
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo

$(LINUXDEPLOY):
	wget -c $(LINUXDEPLOY_URL)
	chmod +x $(LINUXDEPLOY)

$(LINUXDEPLOY_GTK):
	wget -c $(LINUXDEPLOY_GTK_URL)
	chmod +x $(LINUXDEPLOY_GTK)

appimage: build $(LINUXDEPLOY) $(LINUXDEPLOY_GTK)
	rm -rf $(APPDIR)
	DESTDIR=$(CURDIR)/$(APPDIR) meson install -C _build
	@# Bundle GStreamer plugins
	mkdir -p $(APPDIR)/usr/lib/x86_64-linux-gnu/gstreamer-1.0
	cp $(GST_LIBDIR)/libgstcoreelements.so \
	   $(GST_LIBDIR)/libgstplayback.so \
	   $(GST_LIBDIR)/libgstaudioparsers.so \
	   $(GST_LIBDIR)/libgstaudioconvert.so \
	   $(GST_LIBDIR)/libgstaudioresample.so \
	   $(GST_LIBDIR)/libgstogg.so \
	   $(GST_LIBDIR)/libgstvorbis.so \
	   $(GST_LIBDIR)/libgstopus.so \
	   $(GST_LIBDIR)/libgstmpg123.so \
	   $(GST_LIBDIR)/libgstfaad.so \
	   $(GST_LIBDIR)/libgsthls.so \
	   $(GST_LIBDIR)/libgstmpegtsdemux.so \
	   $(GST_LIBDIR)/libgstadaptivedemux2.so \
	   $(GST_LIBDIR)/libgsticydemux.so \
	   $(GST_LIBDIR)/libgstid3demux.so \
	   $(GST_LIBDIR)/libgstautodetect.so \
	   $(GST_LIBDIR)/libgsttypefindfunctions.so \
	   $(GST_LIBDIR)/libgstalsa.so \
	   $(GST_LIBDIR)/libgstpulseaudio.so \
	   $(GST_LIBDIR)/libgstsoup.so \
	   $(APPDIR)/usr/lib/x86_64-linux-gnu/gstreamer-1.0/
	@# Copy GStreamer scanner and core libraries
	mkdir -p $(APPDIR)/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0
	cp $(GST_SCANNER) $(APPDIR)/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/
	-cp /usr/lib/x86_64-linux-gnu/libgst*.so* $(APPDIR)/usr/lib/x86_64-linux-gnu/
	@# Create AppRun hook for GStreamer environment
	mkdir -p $(APPDIR)/apprun-hooks
	cp data/appimage/receiver-env.sh $(APPDIR)/apprun-hooks/
	@# Bundle GIO modules (TLS via glib-networking, proxy)
	mkdir -p $(APPDIR)/usr/lib/x86_64-linux-gnu/gio/modules
	cp /usr/lib/x86_64-linux-gnu/gio/modules/libgiognutls.so \
	   $(APPDIR)/usr/lib/x86_64-linux-gnu/gio/modules/
	-cp /usr/lib/x86_64-linux-gnu/gio/modules/libgiognomeproxy.so \
	    /usr/lib/x86_64-linux-gnu/gio/modules/libgiolibproxy.so \
	    $(APPDIR)/usr/lib/x86_64-linux-gnu/gio/modules/
	gio-querymodules $(APPDIR)/usr/lib/x86_64-linux-gnu/gio/modules
	@# Bundle Adwaita symbolic icons (needed by GTK4/Libadwaita)
	mkdir -p $(APPDIR)/usr/share/icons/Adwaita
	cp /usr/share/icons/Adwaita/index.theme $(APPDIR)/usr/share/icons/Adwaita/
	cp -r /usr/share/icons/Adwaita/symbolic $(APPDIR)/usr/share/icons/Adwaita/
	-cp -r /usr/share/icons/Adwaita/symbolic-up-to-32 $(APPDIR)/usr/share/icons/Adwaita/
	@# hicolor is the base theme Adwaita inherits from; without its index.theme
	@# GTK fails to build the theme chain and shows only its built-in icons
	mkdir -p $(APPDIR)/usr/share/icons/hicolor
	cp /usr/share/icons/hicolor/index.theme $(APPDIR)/usr/share/icons/hicolor/
	@# Regenerate icon caches so GTK reliably resolves the bundled themes
	-gtk4-update-icon-cache -ft $(APPDIR)/usr/share/icons/Adwaita
	-gtk4-update-icon-cache -ft $(APPDIR)/usr/share/icons/hicolor
	VERSION=$(VERSION) DEPLOY_GTK_VERSION=4 ./$(LINUXDEPLOY) \
		--appdir $(APPDIR) \
		--plugin gtk \
		--desktop-file $(APPDIR)/usr/share/applications/$(APP_ID).desktop \
		--icon-file $(APPDIR)/usr/share/icons/hicolor/512x512/apps/$(APP_ID).png \
		--output appimage
