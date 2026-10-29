#!/bin/sh

set -eu

# App launcher sized to the focused output. Wofi resolves a "70%" width
# against GDK's unrotated monitor geometry (it polls whichever monitor
# GTK associates with the surface pre-map, see do_percent_size in
# src/wofi.c), so on the rotated portrait display the menu ends up wider
# than the screen and the columns are cut off. Sway's rect is already
# post-rotation, so compute pixels from it and pass them as a suffixless
# number, which wofi treats as literal pixels. Result: skinny on skinny
# displays, wide on wide ones.

geom=$(swaymsg -t get_outputs |
    jq -r 'first(.[] | select(.focused)) | "\(.rect.width) \(.rect.height)"')

# No focused output (non-sway session?): fall back to the wofi config.
[ -n "$geom" ] || exec wofi --show drun

set -- $geom
ow=$1
oh=$2

if [ "$oh" -gt "$ow" ]; then
    columns=2 # portrait: two roomy columns beat four clipped ones
else
    columns=4
fi

exec wofi --show drun --width $((ow * 70 / 100)) --columns "$columns"
