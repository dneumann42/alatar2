#!/bin/sh
# ============================================================================
# Put a wallpaper on screen for the running session. Called by
# wallpaper.service (ExecStartPost) right after the awww daemon comes up, and
# safe to run by hand any time.
#
# Preference order:
#   1. the image awww displayed last (its cache under ~/.cache/awww)
#   2. a random picture from $WALLPAPERS_DIR (default ~/Media/Wallpapers)
#   3. the theme background colour, so a fresh install gets a deliberate
#      background instead of a black screen
#
# Always exits 0: not finding a wallpaper must never mark the unit failed.
# ============================================================================
set -u

cache="${XDG_CACHE_HOME:-$HOME/.cache}/awww"
wallpapers="${WALLPAPERS_DIR:-$HOME/Media/Wallpapers}"
fallback="${WALLPAPER_FALLBACK:-111318}"   # awww wants rrggbb, without the '#'

command -v awww >/dev/null 2>&1 || { echo "apply-wallpaper: awww not on PATH" >&2; exit 0; }

# The daemon binds its socket a moment after it is exec'd: wait up to ~5 s.
i=0
while [ "$i" -lt 50 ] && ! awww query >/dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
done
if ! awww query >/dev/null 2>&1; then
    echo "apply-wallpaper: no awww daemon socket (WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>})" >&2
    exit 0
fi

# 1. Restore the cached image - but only if there is one. With an empty cache
#    `awww restore` still exits 0 (it only logs warnings), so trusting the exit
#    status alone would leave the outputs black and skip the steps below.
if [ -n "$(find "$cache" -type f -print -quit 2>/dev/null)" ] &&
   awww restore >/dev/null 2>&1; then
    exit 0
fi

# 2. A picture from the wallpapers directory (-t none: no fade on login).
if [ -d "$wallpapers" ]; then
    pick="$(find "$wallpapers" -maxdepth 1 -type f \
              \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
              2>/dev/null | shuf -n 1)"
    if [ -n "$pick" ] && awww img -t none "$pick" >/dev/null 2>&1; then
        exit 0
    fi
fi

# 3. Solid theme background.
echo "apply-wallpaper: nothing to show (empty awww cache, no pictures in $wallpapers); using #$fallback" >&2
awww clear "$fallback" >/dev/null 2>&1 || true
exit 0
