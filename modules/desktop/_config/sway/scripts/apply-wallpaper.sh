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
# Whatever image ends up on screen, wallust then regenerates the desktop
# theme from it (sway/kitty colors in ~/.cache/wallust - see
# ~/.config/wallust/wallust.toml), so the palette always matches the picture.
#
# Always exits 0: not finding a wallpaper must never mark the unit failed.
# ============================================================================
set -u

cache="${XDG_CACHE_HOME:-$HOME/.cache}/awww"
wallpapers="${WALLPAPERS_DIR:-$HOME/Media/Wallpapers}"
fallback="${WALLPAPER_FALLBACK:-000000}"   # awww wants rrggbb, without the '#'

command -v awww >/dev/null 2>&1 || { echo "apply-wallpaper: awww not on PATH" >&2; exit 0; }

# Regenerate the wallust theme from a displayed image. The hooks in
# wallust.toml apply it (sway reload, notification). Best-effort: no wallust
# or a failed generation must leave the unit and the wallpaper alone.
generate_theme() {
    command -v wallust >/dev/null 2>&1 || { echo "apply-wallpaper: wallust not on PATH" >&2; return 0; }
    wallust run "$1" || echo "apply-wallpaper: wallust failed, theme unchanged" >&2
}

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
    # `awww query` prints "<output>: ... currently displaying: image: <path>"
    # for pictures and "... color: RRGGBB" after `awww clear`: only the image
    # lines feed a palette, so the sed yields empty for a solid colour.
    shown="$(awww query 2>/dev/null | sed -n 's/.* currently displaying: image: //p' | head -n 1)"
    if [ -n "$shown" ]; then
        generate_theme "$shown"
    fi
    exit 0
fi

# 2. A picture from the wallpapers directory (-t none: no fade on login).
if [ -d "$wallpapers" ]; then
    pick="$(find "$wallpapers" -maxdepth 1 -type f \
              \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
              2>/dev/null | shuf -n 1)"
    if [ -n "$pick" ] && awww img -t none "$pick" >/dev/null 2>&1; then
        generate_theme "$pick"
        exit 0
    fi
fi

# 3. Solid theme background.
echo "apply-wallpaper: nothing to show (empty awww cache, no pictures in $wallpapers); using #$fallback" >&2
awww clear "$fallback" >/dev/null 2>&1 || true
exit 0
