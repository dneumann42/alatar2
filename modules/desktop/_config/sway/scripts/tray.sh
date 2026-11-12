#!/usr/bin/env sh
# ============================================================================
# sway launcher for the tray host (apps/tray): the tinydbus SNI host whose
# strip docks on the bar's right edge (bar.conf keeps tray_output none so
# the watcher name is ours to claim; scripts/status.sh owns the other
# layer-shell neighbours in that strip).
#
# Build logic mirrors bar-buttons.sh: nimble when the binary is missing or
# any source/nimble/vendor file is newer. No --offline: apps/tray builds
# against the patched ellipse checkout via config.nims paths, and the
# vendored tinydbus needs no network at all - plain `nimble build` resolves
# from the package cache without a remote round trip for the URL deps.
#
# pkill first: sway reload re-runs exec_always and the tray has no
# single-instance guard (a second copy would sit in the watcher queue
# forever, eating memory like the swayidle pile-up does).
# ============================================================================
set -u

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
proj="$here/../../../../../apps/tray"
bin="$proj/bin/tray"

pkill -x tray 2>/dev/null

needs_build=0
if [ ! -x "$bin" ]; then
    needs_build=1
elif [ -n "$(find "$proj/src" "$proj/vendor" "$proj/tray.nimble" "$proj/config.nims" -newer "$bin" 2>/dev/null | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" = 1 ]; then
    command -v nimble >/dev/null 2>&1 || {
        echo "tray: $bin not built and nimble unavailable (PATH: $PATH)" >&2
        exit 1
    }
    log="$proj/build.log"
    if (cd "$proj" && nimble build) >"$log" 2>&1; then
        rm -f "$log"
    else
        echo "tray: nimble build failed, see $log" >&2
        exit 1
    fi
fi

exec "$bin"
