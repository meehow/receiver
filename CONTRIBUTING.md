# Contributing to Receiver

Thanks for your interest in contributing! Receiver is built with **Vala**, **GTK 4**, and **Libadwaita**.

## Building from source

### Dependencies (Debian/Ubuntu)

```sh
sudo apt install \
    meson \
    valac \
    libgtk-4-dev \
    libadwaita-1-dev \
    libgstreamer1.0-dev \
    libsoup-3.0-dev \
    libjson-glib-dev \
    libjavascriptcoregtk-6.0-dev \
    libsqlite3-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad
```

### Build & install

```sh
meson setup builddir
meson compile -C builddir
sudo meson install -C builddir
```

### Run without installing

```sh
meson setup builddir
meson compile -C builddir
./builddir/src/receiver
```

## Reporting bugs

Please open an issue on [GitHub](https://github.com/meehow/receiver/issues) with:

- Steps to reproduce the problem
- Expected vs. actual behaviour
- Your distribution and desktop environment

## License

Receiver is licensed under the [GPL-3.0-or-later](LICENSE).
