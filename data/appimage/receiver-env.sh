#!/bin/bash
# This hook runs AFTER linuxdeploy-plugin-gtk.sh (alphabetical order)
# to override settings that break GTK4/Libadwaita apps.

# GStreamer: use bundled plugins and scanner
export GST_PLUGIN_SYSTEM_PATH="${APPDIR}/usr/lib/x86_64-linux-gnu/gstreamer-1.0"
export GST_PLUGIN_SCANNER="${APPDIR}/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner"
export GST_REGISTRY="${HOME}/.cache/receiver-gst-registry"

# Override linuxdeploy-plugin-gtk's forced GDK_BACKEND=x11
# GTK 4.14+ handles Wayland natively; x11 causes visual differences
unset GDK_BACKEND

# Unset GTK_THEME — Libadwaita manages its own stylesheet
# Setting GTK_THEME conflicts with AdwStyleManager
unset GTK_THEME
