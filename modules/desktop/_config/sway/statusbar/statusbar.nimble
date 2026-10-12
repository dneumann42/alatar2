# Package

version       = "0.1.0"
description   = "Swaybar status line (i3bar/sway JSON protocol): media, cpu, temp, gpu, ram, network, volume, weather, date, clock, with click support."
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
bin           = @["statusbar"]
binDir        = "bin"

# Stdlib only (os, osproc, strutils, times, json, re, math).
requires "nim >= 2.0.0"

# Channel/Thread are built into the system module under --threads:on.
switch "threads", "on"
