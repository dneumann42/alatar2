#!/bin/sh

# Opened from mako's right-click action on screenshot notifications (the
# bindings would live in the wallust-generated mako config; template at
# ~/.config/wallust/templates/mako.conf.j2). $1 is the notification ID that mako
# substitutes into the exec command; the screenshot script stored the
# matching preview path under the cache dir.

set -eu

preview_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mako-screenshots"

[ -f "$preview_dir/id-$1" ] || exit 0
preview=$(cat "$preview_dir/id-$1")
[ -f "$preview" ] || exit 0

exec gimp "$preview"
