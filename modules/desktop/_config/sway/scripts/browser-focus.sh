#!/bin/sh

set -eu

browser="${browser:-waterfox}"
timeout=100 # ~5s at 50ms per poll

# Wait (if needed) for the browser to be running, then raise its windows:
# float them, drag them onto the currently focused workspace (a no-op for
# windows already here), and focus one. Focus stays on the current workspace
# because the move happens before the focus.
if ! swaymsg -t get_tree | jq -e '.. | objects | select(.app_id == "waterfox")' \
        >/dev/null 2>&1; then
    "$browser" --new-instance >/dev/null 2>&1 &
    until swaymsg -t get_tree |
          jq -e '.. | objects | select(.app_id == "waterfox")' \
              >/dev/null 2>&1; do
        timeout=$((timeout - 1))
        [ "$timeout" -gt 0 ] || exit 1
        sleep 0.05
    done
fi

workspace="$(swaymsg -t get_workspaces |
    jq -r '.[] | select(.focused) | .name')"

swaymsg "[app_id=\"waterfox\"] floating enable, \
         move to workspace \"${workspace}\", focus"
