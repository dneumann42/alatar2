#!/usr/bin/env python3
"""Keep the GTK 3 theme aligned with the desktop color scheme."""

from gi.repository import Gio, GLib


def sync_gtk_theme(settings, _key=None):
    scheme = settings.get_string("color-scheme")
    theme = "Adwaita-dark" if scheme == "prefer-dark" else "Adwaita"
    if settings.get_string("gtk-theme") != theme:
        settings.set_string("gtk-theme", theme)


settings = Gio.Settings.new("org.gnome.desktop.interface")
settings.connect("changed::color-scheme", sync_gtk_theme)
sync_gtk_theme(settings)
GLib.MainLoop().run()
