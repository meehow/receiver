project('receiver', 'vala', 'c',
  version: '0.3.2',
  meson_version: '>= 0.59.0',
  default_options: ['warning_level=2']
)

# Import modules
i18n = import('i18n')
gnome = import('gnome')

# Dependencies (with Vala bindings)
gtk4_dep = dependency('gtk4', version: '>= 4.10')
adw_dep = dependency('libadwaita-1', version: '>= 1.4')
gst_dep = dependency('gstreamer-1.0')
soup_dep = dependency('libsoup-3.0')
json_dep = dependency('json-glib-1.0')
sqlite_dep = dependency('sqlite3')

# ytdl subproject
ytdl_subproject = subproject('ytdl')
ytdl_dep = ytdl_subproject.get_variable('ytdl_dep')

# i18n configuration - define GETTEXT_PACKAGE for all C files
add_project_arguments('-DGETTEXT_PACKAGE="' + meson.project_name() + '"', language: 'c')
add_project_arguments('-DG_LOG_DOMAIN="receiver"', language: 'c')

# Source files
sources = files(
  'src/main.vala',
  'src/application.vala',
  'src/models/station.vala',
  'src/utils/metadata_parser.vala',
  'src/utils/languages.vala',
  'src/services/app_state.vala',
  'src/services/station_store.vala',
  'src/services/player.vala',
  'src/services/mpris.vala',
  'src/services/image_loader.vala',
  'src/services/song_downloader.vala',
  'src/widgets/window.vala',
  'src/widgets/home_screen.vala',
  'src/widgets/station_list.vala',
  'src/widgets/player_bar.vala',
)

# Vala compiler arguments
add_project_arguments([
  '--target-glib=2.76',
], language: 'vala')

# Build executable
executable('receiver',
  sources,
  dependencies: [
    gtk4_dep,
    adw_dep,
    gst_dep,
    soup_dep,
    json_dep,
    sqlite_dep,
    ytdl_dep,
  ],
  install: true
)

# GSettings schema
gnome.compile_schemas(
  depend_files: 'data/io.github.meehow.Receiver.gschema.xml'
)
install_data('data/io.github.meehow.Receiver.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0/schemas'
)

gnome.post_install(
  glib_compile_schemas: true,
)

# Translations
subdir('po')

install_data('data/io.github.meehow.Receiver.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/io.github.meehow.Receiver.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo'
)

install_data('data/icons/hicolor/512x512/apps/io.github.meehow.Receiver.png',
  install_dir: get_option('datadir') / 'icons/hicolor/512x512/apps'
)

install_data('data/icons/hicolor/scalable/apps/io.github.meehow.Receiver.svg',
  install_dir: get_option('datadir') / 'icons/hicolor/scalable/apps'
)

install_data('data/receiver/receiver.db',
  install_dir: get_option('datadir') / 'receiver'
)
