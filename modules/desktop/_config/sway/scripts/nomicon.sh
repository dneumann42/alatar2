#!/usr/bin/env sh
# ============================================================================
# sway launcher for nomicon (apps/nomicon, the ellipse GUI app): focus its
# window if one exists, else build on demand and launch it.
#
# Build logic mirrors bar-buttons.sh: nimble when the binary is missing or
# any source/nimble file is newer. `--offline` keeps reloads fast; drop the
# flag once when a fresh ellipse checkout must be fetched over ssh.
#
# ellipse sets the Wayland app_id to org.ellipse.platform for every app
# (platform.nim, SDL_SetAppMetadata), so the nomicon window is identified
# by app_id + title; window-rules.conf matches the same pair.
# ============================================================================
set -u

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
proj="$here/../../../../../apps/nomicon"
bin="$proj/bin/nomicon"

if swaymsg -t get_tree 2>/dev/null | grep -q '"nomicon"'; then
    exec swaymsg '[app_id="org.ellipse.platform" title="^nomicon$"] focus'
fi

needs_build=0
if [ ! -x "$bin" ]; then
    needs_build=1
elif [ -n "$(find "$proj/src" "$proj/nomicon.nimble" -newer "$bin" 2>/dev/null | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" = 1 ]; then
    command -v nimble >/dev/null 2>&1 || {
        echo "nomicon: $bin not built and nimble unavailable (PATH: $PATH)" >&2
        exit 1
    }
    log="$proj/build.log"
    if (cd "$proj" && nimble --offline build) >"$log" 2>&1; then
        rm -f "$log"
    else
        echo "nomicon: nimble build failed, see $log" >&2
        exit 1
    fi
fi

exec "$bin"
