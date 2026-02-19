project('ytdl', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.56',
)

gnome = import('gnome')

deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('javascriptcoregtk-6.0'),
]

# Embed JS solver files into the binary
resources = gnome.compile_resources('ytdl-resources',
  'data/ytdl.gresource.xml',
  source_dir: 'data',
)

libytdl = static_library('ytdl',
  'src/ytdl.vala',
  resources,
  dependencies: deps,
  install: false,
)

ytdl_dep = declare_dependency(
  link_whole: libytdl,
  dependencies: deps,
  include_directories: include_directories('.'),
)

executable('ytdl',
  'src/main.vala',
  dependencies: deps,
  link_with: libytdl,
  install: false,
)
