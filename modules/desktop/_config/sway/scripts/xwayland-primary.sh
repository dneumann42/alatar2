#!/usr/bin/env bash
# ============================================================================
# Make the large 32" monitor (DP-1) the primary display for X11/Steam games.
#
# sway hands XWayland its outputs in creation (udev/DRM) order, not layout
# order, so the portrait HP (HDMI-A-2) arrives as XRandR monitor 0. Wine and
# Source-engine games default to monitor 0's mode list when no RandR PRIMARY
# output is set and open at the portrait resolution. sway exposes no primary
# knob, so:
#   1. cycle every output enumerated before the 0x0 one (disable + enable);
#      sway keeps each output's stored config and re-appends re-enabled
#      outputs at the END of the XWayland list, leaving DP-1 as monitor 0.
#   2. set the real RandR PRIMARY flag on monitor 0 via python-xlib, for
#      apps that query XRRGetOutputPrimary instead of position (xrandr
#      --primary cannot be used: its RRSetCrtcConfig call aborts with
#      BadValue under XWayland before the flag is sent).
#
# Idempotent: exits quietly once the 0x0 output is already monitor 0 with
# the PRIMARY flag set, so exec_always re-runs on sway reload never disturb
# running windows. Best-effort throughout: any step failing only prints to
# stderr.
# ============================================================================
set -u
export DISPLAY="${DISPLAY:-:0}"

command -v swaymsg >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - <<'PY' || true
import json, subprocess, sys, time

def sway(arg):
    p = subprocess.run(["swaymsg", arg], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError((p.stdout + p.stderr).strip() or "swaymsg failed")
    return p.stdout

def active_outputs():
    data = json.loads(sway("-t get_outputs"))
    return [o for o in data if o.get("active") and not o.get("non_desktop")]

def wait_layout():
    # sway enables outputs asynchronously; wait for one at 0x0.
    for _ in range(50):
        try:
            order = active_outputs()
            primary = next((o for o in order
                            if o["rect"]["x"] == 0 and o["rect"]["y"] == 0),
                           None)
            if primary is not None:
                return order, primary
        except Exception:
            pass
        time.sleep(0.1)
    return None, None

order, primary = wait_layout()
if order is None:
    sys.exit(0)

# 1. Re-append everything the primary trails so it sorts to the front.
idx = order.index(primary)
if idx > 0:
    ahead = order[:idx]
    for o in ahead:
        sway(f'output "{o["name"]}" disable')
    for o in ahead:
        sway(f'output "{o["name"]}" enable')
    for _ in range(30):
        try:
            if active_outputs()[0]["name"] == primary["name"]:
                break
        except Exception:
            pass
        time.sleep(0.1)

# 2. XRandR PRIMARY flag on monitor 0. GetScreenResources lists outputs in
# the same order XWayland reports them, so index 0 == the 0x0 output.
try:
    from Xlib import display
    d = display.Display()
    root = d.screen().root
    for _ in range(30):
        try:
            ids = list(root.xrandr_get_screen_resources_current().outputs)
            if ids:
                root.xrandr_set_output_primary(ids[0])
                d.sync()
                if root.xrandr_get_output_primary().output == ids[0]:
                    break
        except Exception:
            pass
        time.sleep(0.1)
except Exception as e:
    print(f"xwayland-primary: RANDR PRIMARY flag skipped: {e}", file=sys.stderr)
PY
