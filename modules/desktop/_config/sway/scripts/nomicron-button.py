#!/usr/bin/env python3
"""
Clickable buttons pinned to the far left of the swaybar.

swaybar can only render text, so these are tiny gtk4-layer-shell surfaces
anchored to each monitor's top-left corner, sitting exactly in the bar's
left gap (see `gaps left` in bar.conf). The nomicron icon is leftmost; a
gear button sits directly to its right. Clicking either fires a
notification — edit NOTIFY_CMD / GEAR_NOTIFY_CMD below to change them.
"""

import os
import subprocess
import sys

# gtk4-layer-shell must be loaded before libwayland or layer surfaces fail
# to initialize; see https://github.com/wmww/gtk4-layer-shell/blob/main/linking.md
_PRELOAD = "/usr/lib/libgtk4-layer-shell.so"
if os.path.exists(_PRELOAD) and _PRELOAD not in os.environ.get("LD_PRELOAD", ""):
    os.execvpe(
        sys.executable,
        [sys.executable, *sys.argv],
        dict(os.environ, LD_PRELOAD=_PRELOAD),
    )

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Gtk4LayerShell

ICON = GLib.build_filenamev(
    [GLib.get_home_dir(), ".config", "sway", "scripts", "nomicron-small.png"]
)
BAR_HEIGHT = 20      # keep in sync with bar.conf's `height`
BUTTON_WIDTH = 24    # keep in sync with bar.conf's `gaps left` (per button)
ICON_HEIGHT = 16     # rendered icon height (image keeps its aspect ratio)
NOTIFY_CMD = ["notify-send", "Nomicron", "The nomicron calls to you."]

# Gear button, placed directly to the right of the nomicron icon.
GEAR_GLYPH = "\uf013"                       # fa-cog, from the Nerd Font
GEAR_FONT = "AtkynsonMono Nerd Font"        # same font the bar uses
GEAR_NOTIFY_CMD = ["notify-send", "Settings", "You clicked the gear."]

CSS = f"""
button.nomicron {{
    background-image: none;
    background-color: #000000;  /* matches $bar_bg so it blends into the bar */
    border: none;
    border-radius: 0;
    box-shadow: none;
    outline: none;
    margin: 0;
    padding: 0;
    min-width: 0;
    min-height: 0;
}}
button.nomicron:hover {{ background-color: #1c1f26; }}

button.gear {{
    background-image: none;
    background-color: #000000;
    border: none;
    border-radius: 0;
    box-shadow: none;
    outline: none;
    margin: 0;
    padding: 0;
    min-width: 0;
    min-height: 0;
    color: #9aa4b2;              /* $muted */
    font-family: {GEAR_FONT};
    font-size: 11pt;
}}
button.gear:hover {{ background-color: #1c1f26; color: #e6eaf2; }}
""".encode()

app = Gtk.Application(application_id="dev.dneumann.sway-nomicron-button")
_built = False  # a second launch forwards 'activate' to us; don't double up


def clicked(cmd):
    subprocess.Popen(cmd)


def make_button_window(monitor, child, css_class, notify_cmd, left_margin):
    btn = Gtk.Button(css_classes=[css_class])
    btn.set_child(child)
    btn.set_can_focus(False)
    btn.set_size_request(BUTTON_WIDTH, BAR_HEIGHT)
    btn.set_cursor_from_name("pointer")
    btn.connect("clicked", lambda *_: clicked(notify_cmd))

    win = Gtk.ApplicationWindow(application=app)
    win.set_child(btn)

    Gtk4LayerShell.init_for_window(win)
    Gtk4LayerShell.set_monitor(win, monitor)
    Gtk4LayerShell.set_layer(win, Gtk4LayerShell.Layer.OVERLAY)
    Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.TOP, True)
    Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.LEFT, True)
    Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.TOP, 0)
    Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.LEFT, left_margin)
    Gtk4LayerShell.set_exclusive_zone(win, -1)  # overlay the gap, reserve nothing
    Gtk4LayerShell.set_keyboard_mode(win, Gtk4LayerShell.KeyboardMode.NONE)
    win.present()


def on_activate(_app):
    global _built
    if _built:
        return
    _built = True

    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
    display = Gdk.Display.get_default()
    for monitor in display.get_monitors():
        img = Gtk.Image.new_from_pixbuf(
            GdkPixbuf.Pixbuf.new_from_file_at_scale(ICON, -1, ICON_HEIGHT, True)
        )
        make_button_window(monitor, img, "nomicron", NOTIFY_CMD, 0)
        gear = Gtk.Label(label=GEAR_GLYPH)
        make_button_window(monitor, gear, "gear", GEAR_NOTIFY_CMD, BUTTON_WIDTH)


app.connect("activate", on_activate)
app.run(None)
