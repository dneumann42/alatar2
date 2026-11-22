#!/bin/sh
# Older Alatar releases stored the bar and Nomicon preference here.
set -eu
state="${XDG_STATE_HOME:-$HOME/.local/state}/alatar"
[ -f "$state/bar-mode" ] && [ ! -e "$state/appearance-migrated" ] || exit 0

case "$(cat "$state/bar-mode")" in
    light) scheme=prefer-light ;;
    dark) scheme=prefer-dark ;;
    *) exit 0 ;;
esac

gsettings set org.gnome.desktop.interface color-scheme "$scheme"
touch "$state/appearance-migrated"
