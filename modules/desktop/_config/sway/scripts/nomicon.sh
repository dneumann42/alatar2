#!/usr/bin/env sh
# ============================================================================
# Build and launch Nomicon Launcher or Nomicon Settings.
#
# ellipse sets the Wayland app_id to org.ellipse.platform for every app
# (platform.nim, SDL_SetAppMetadata), so the nomicon window is identified
# by app_id + title; window-rules.conf matches the same pair.
# ============================================================================
set -u

here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
proj="$here/../../../../../apps/nomicon"
target=nomicon-settings
if [ "${1:-}" = "--launcher" ]; then
    target=nomicon-launcher
    shift
fi
bin="$proj/bin/$target"

if [ "${1:-}" != "--attach" ] &&
        swaymsg -t get_tree 2>/dev/null | grep -Fq "\"$target\""; then
    exec swaymsg "[app_id=\"org.ellipse.platform\" title=\"^${target}\$\"] focus"
fi

if [ ! -x "$bin" ] || [ -n "$(find "$proj/src" "$proj/config.nims" \
        "$proj/nomicon.nimble" "$proj"/../../src/alatar/desktop*.nim \
        -newer "$bin" 2>/dev/null | head -n1)" ]; then
    (cd "$proj" && nimble build "$target") >&2 || [ -x "$bin" ] || exit 1
fi

exec "$bin" "$@"
