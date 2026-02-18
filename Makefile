APP_ID = io.github.meehow.Receiver
MANIFEST = $(APP_ID).yml

.PHONY: build install clean deb run \
        flatpak-build flatpak-run flatpak-lint-manifest flatpak-lint-repo flatpak-submit \
        translations-check translations-update

builddir:
	meson setup builddir --prefix=/usr --buildtype=release

build: builddir
	meson compile -C builddir

install: build
	meson install -C builddir

clean:
	rm -rf builddir

run: build
	GSETTINGS_SCHEMA_DIR=$(CURDIR)/data \
	XDG_DATA_DIRS=$(CURDIR)/data:/usr/share \
	LOCALEDIR=$(CURDIR)/builddir/po \
	./builddir/receiver

deb:
	dpkg-buildpackage -us -uc -b

translations-check:
	@for file in po/*.po; do \
		echo -n "$$file: "; \
		msgfmt --statistics -o /dev/null $$file; \
	done

translations-update: builddir
	meson compile -C builddir receiver-pot
	meson compile -C builddir receiver-update-po

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
