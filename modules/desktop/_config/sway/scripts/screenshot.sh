#!/bin/sh

set -eu

# Screenshot picker: Print opens a wofi menu to choose the capture type.
# The shot is copied to the clipboard and shown in a mako notification via
# its image-path hint, which requires a file, so each capture is written to
# a preview file under the cache dir (pruned after a day).

choice=$(printf 'monitor\nregion\n' |
    wofi --dmenu --prompt 'Screenshot') || true
[ -n "$choice" ] || exit 0

preview_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mako-screenshots"
mkdir -p "$preview_dir"
find "$preview_dir" -type f -mtime +1 -delete 2>/dev/null || true
preview="$preview_dir/screenshot-$(date +%Y-%m-%d_%H-%M-%S).png"

case "$choice" in
    region)
        grim -g "$(slurp)" "$preview"
        ;;
    monitor)
        # The focused output is the one showing the active workspace.
        output=$(swaymsg -t get_outputs |
            jq -r 'first(.[] | select(.focused) | .name)')
        if [ -z "$output" ] || [ "$output" = null ]; then
            exit 1
        fi
        grim -o "$output" "$preview"
        ;;
    *)
        exit 1
        ;;
esac

wl-copy --type image/png < "$preview"
# -p prints the notification ID; mako passes it to the right-click exec
# action, which resolves it back to the preview path (screenshot-open.sh).
notify_id=$(notify-send -p \
    --app-name screenshot \
    --urgency low \
    --hint "string:image-path:$preview" \
    'Screenshot' "Copied to clipboard ($choice)") || true
if [ -n "${notify_id:-}" ]; then
    printf '%s\n' "$preview" > "$preview_dir/id-$notify_id"
fi
