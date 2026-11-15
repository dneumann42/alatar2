# Package

version       = "0.2.0"
description   = "Swaybar status line (i3bar/sway JSON protocol): media, cpu, temp, gpu, ram, network, volume, weather, date, clock, with click support. Spawned by apps/bar now that swaybar itself is retired (its buttons sibling binary, barbuttons, is legacy: the bar draws buttons.toml in-surface)."
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
bin           = @["statusbar", "barbuttons"]
binDir        = "bin"

# Stdlib only for statusbar (os, osproc, strutils, times, json, math) - and
# deliberately NOT std/re: it dlopens libpcre.so(.3|.1|) at startup, which
# breaks the bar whenever PCRE1 is missing or shadowed (see the bootstrap
# contract in README.org). Numeric parsing lives in src/statusbar/util.nim.
# bar-buttons adds parsetoml (buttons.toml) and dlopen'ed GTK4/
# gtk4-layer-shell symbols (src/statusbar/layershell.nim - no link flags).
requires "nim >= 2.0.0"
requires "parsetoml >= 0.7.0"

# Channel/Thread are built into the system module under --threads:on.
switch "threads", "on"
