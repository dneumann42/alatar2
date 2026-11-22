#!/usr/bin/env sh
# ============================================================================
# sway launcher for the ellipse bar (apps/bar): the swaybar replacement, one
# process per output, plus the integrated tray host and the buttons rendered
# from statusbar/buttons.toml (the old barbuttons + tray strip + swaybar trio
# folded into one layer-shell surface per monitor).
#
# Build logic mirrors the old bar-buttons.sh/status.sh: nimble when the
# binary is missing or any source/nimble/vendor file is newer. Plain
# `nimble build` (no --offline) for apps/bar: it builds against the patched
# ellipse checkout via config.nims paths and resolves the URL deps from the
# package cache without a remote round trip. The status line's own project
# (sway's statusbar/) is stdlib-only and still built with --offline: bar
# spawns its binary directly (as swaybar's status_command used to).
#
# pkill first: sway reload re-runs exec_always, and none of these binaries
# have single-instance guards (a second copy would sit in the SNI watcher
# queue forever - the reason the old tray.sh killed `tray` the same way).
# `tray`/`barbuttons` pkills linger one release: they retire WITH this
# script's switchover but stale copies from a pre-reload session must not
# shadow the watcher the bar now claims.
# ============================================================================
set -u

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
proj="$here/../../../../../apps/bar"
bin="$proj/bin/bar"
statusproj="$here/../statusbar"
statusbin="$statusproj/bin/statusbar"

pkill -x bar 2>/dev/null
pkill -x tray 2>/dev/null
pkill -x barbuttons 2>/dev/null
pkill -x statusbar 2>/dev/null

needs_build=0
if [ ! -x "$bin" ]; then
    needs_build=1
elif [ -n "$(find "$proj/src" "$proj/bar.nimble" "$proj/config.nims" \
        "$here/../../../../../apps/tray/src" \
        "$here/../../../../../src/alatar/desktopchrome.nim" \
        "$here/../../../../../src/alatar/desktopmode.nim" \
        "$here/../../../../../src/alatar/desktoptheme.nim" -newer "$bin" 2>/dev/null \
        | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" = 1 ]; then
    command -v nimble >/dev/null 2>&1 || {
        echo "bar: $bin not built and nimble unavailable (PATH: $PATH)" >&2
        exit 1
    }
    log="$proj/build.log"
    if (cd "$proj" && nimble build) >"$log" 2>&1; then
        rm -f "$log"
    else
        echo "bar: nimble build failed, see $log" >&2
        # An older built binary still serves: fall through to launch.
        [ -x "$bin" ] || exit 1
    fi
fi

needs_build=0
if [ ! -x "$statusbin" ]; then
    needs_build=1
elif [ -n "$(find "$statusproj/src" "$statusproj/statusbar.nimble" \
        -newer "$statusbin" 2>/dev/null | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" = 1 ] && command -v nimble >/dev/null 2>&1; then
    log="$statusproj/build.log"
    if (cd "$statusproj" && nimble --offline build) >"$log" 2>&1; then
        rm -f "$log"
    else
        echo "bar: statusbar build failed, see $log" >&2
    fi
fi

# One bar per enabled output. The tray host (SNI watcher owner) runs on the
# main monitor when it exists, else the first output; swaybar's strip was
# likewise one output's property, and only one process may claim
# org.kde.StatusNotifierWatcher.
outputs="$(swaymsg -t get_outputs 2>/dev/null \
    | jq -r '.[] | select(.type == "output" and .active) | .name')"
[ -n "$outputs" ] || outputs="DP-1"

trayout="$(echo "$outputs" | grep -x 'DP-1' | head -n1)"
[ -n "$trayout" ] || trayout="$(echo "$outputs" | head -n1)"

for out in $outputs; do
    if [ "$out" = "$trayout" ]; then
        "$bin" --output "$out" --tray >/dev/null 2>&1 &
    else
        "$bin" --output "$out" >/dev/null 2>&1 &
    fi
done
disown -a 2>/dev/null || true
