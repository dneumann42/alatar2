#!/bin/sh
# ============================================================================
# Volume key handler: changes the default sink/source with pactl and shows
# the result in one live-updating mako notification.
#
# Usage: volume.sh up | down | mute | mic
#
# Every call for a device reuses the same notification: the id printed by
# `notify-send -p` is remembered under the cache dir and fed back via -r, so
# holding a key mutates the visible popup instead of stacking new ones (mako's
# `synchronous` hint is set as a fallback for when the id file is stale).
# The `int:value` hint is what makes mako render the level as a progress bar.
# ============================================================================
set -u

action="${1:-}"
case "$action" in
    up | down | mute | mic) ;;
    *)
        echo "usage: $0 up|down|mute|mic" >&2
        exit 2
        ;;
esac

step=5
timeout=1500 # ms the popup lingers after the last keypress

cache="${XDG_CACHE_HOME:-$HOME/.cache}/alatar"
mkdir -p "$cache"

case "$action" in
    mic)
        title="Microphone"
        idfile="$cache/notify-id-mic"
        ;;
    *)
        title="Volume"
        idfile="$cache/notify-id-volume"
        ;;
esac

# The lock keeps concurrent key-repeat invocations from interleaving their
# state reads and notification replaces (they would fight over the id file).
exec 9>"$idfile.lock"
flock 9

case "$action" in
    up)
        pactl set-sink-mute @DEFAULT_SINK@ 0
        pactl set-sink-volume @DEFAULT_SINK@ +"$step"%
        ;;
    down)
        pactl set-sink-volume @DEFAULT_SINK@ -"$step"%
        ;;
    mute)
        pactl set-sink-mute @DEFAULT_SINK@ toggle
        ;;
    mic)
        pactl set-source-mute @DEFAULT_SOURCE@ toggle
        ;;
esac

if [ "$action" = mic ]; then
    pct=$(pactl get-source-volume @DEFAULT_SOURCE@ |
        grep -o '[0-9]\+%' | head -n1 | tr -d '%')
    muted=$(pactl get-source-mute @DEFAULT_SOURCE@ | grep -c '[Yy]es')
    icon_on=microphone-sensitivity-medium-symbolic
    icon_off=microphone-sensitivity-muted-symbolic
else
    pct=$(pactl get-sink-volume @DEFAULT_SINK@ |
        grep -o '[0-9]\+%' | head -n1 | tr -d '%')
    muted=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -c '[Yy]es')
    case "$pct" in
        [6-9][0-9] | 1[0-9][0-9]) icon_on=audio-volume-high-symbolic ;;
        [3-5][0-9]) icon_on=audio-volume-medium-symbolic ;;
        *) icon_on=audio-volume-low-symbolic ;;
    esac
    icon_off=audio-volume-muted-symbolic
fi

# The bar keeps showing the level even while muted; the text says so.
if [ "$muted" -gt 0 ]; then
    icon=$icon_off
    text="Muted"
else
    icon=$icon_on
    text="$pct%"
fi

set -- -a alatar-"$title" -i "$icon" -u low -t "$timeout" \
    -h "int:value:$pct" -h "string:synchronous:alatar-$title"

# Replace the live notification when we know its id; if the server rejects
# the (expired/dismissed) id, send a fresh one instead.
id=$(cat "$idfile" 2>/dev/null || true)
out=""
if [ -n "$id" ]; then
    out=$(notify-send -p -r "$id" "$@" "$title" "$text" 2>/dev/null) || out=""
fi
if [ -z "$out" ]; then
    out=$(notify-send -p "$@" "$title" "$text")
fi
printf '%s\n' "$out" > "$idfile"
