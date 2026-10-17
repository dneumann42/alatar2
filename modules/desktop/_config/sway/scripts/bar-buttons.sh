#!/usr/bin/env sh
# ============================================================================
# sway exec_always launcher for the Nim bar-buttons (this project's second
# binary): clickable GTK4 layer-shell buttons beside the swaybar, configured
# in statusbar/buttons.toml.
#
# Builds the project with nimble when the binary is missing or any source
# file is newer than it (same on-demand logic as status.sh). Then execs the
# binary with libgtk4-layer-shell LD_PRELOADED — it shims libwayland symbols
# and must land in the global scope before libwayland does (GTK4 needs
# libwayland itself, so this cannot be arranged from inside the binary; see
# statusbar/src/statusbar/layershell.nim). exec keeps the pid, so sway
# reload/exit still kills the actual button process.
# ============================================================================
set -u

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
proj="$here/../statusbar"
bin="$proj/bin/barbuttons"

needs_build=0
if [ ! -x "$bin" ]; then
    needs_build=1
elif [ -n "$(find "$proj/src" "$proj/statusbar.nimble" -newer "$bin" 2>/dev/null | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" = 1 ] && command -v nimble >/dev/null 2>&1; then
    log="$proj/build.log"
    if (cd "$proj" && nimble --offline build) >"$log" 2>&1; then
        rm -f "$log"
    else
        echo "bar-buttons: nimble build failed, see $log" >&2
    fi
fi

if [ -x "$bin" ]; then
    shell=/usr/lib/libgtk4-layer-shell.so
    [ -e "$shell" ] || { echo "bar-buttons: missing $shell" >&2; exit 1; }
    exec env LD_PRELOAD="${LD_PRELOAD+$LD_PRELOAD:}$shell" "$bin"
fi

echo "bar-buttons: $bin not built and nimble unavailable (PATH: $PATH)" >&2
exit 1
