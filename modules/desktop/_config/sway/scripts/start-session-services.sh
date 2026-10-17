#!/bin/sh
# ============================================================================
# Bring up the systemd user session for sway: publish the compositor's
# environment to the user manager, activate sway-session.target, then make sure
# the session services that hang off it are actually running (wallpaper.service
# = the awww daemon, polkit-gnome.service).
#
# Run by sway as `exec_always` (appearance.conf), so it re-runs on reload and
# after the compositor restarts. Doing the import and the start *sequentially
# in one script* is the point: two `exec_always systemctl` lines fork
# independently, so "start sway-session.target" could reach the user manager
# before WAYLAND_DISPLAY was published - the units would then fail their
# ConditionEnvironment= check and stay dead until the next reload.
#
# alatar only *enables* these units (src/alatar/services.nim): `alatar install`
# normally runs on a TTY or over SSH, where there is no compositor yet.
# ============================================================================
set -u

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Take WAYLAND_DISPLAY from sway's own environment; if it was stripped, find the
# compositor socket ourselves.
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for sock in "$runtime_dir"/wayland-*; do
        [ -S "$sock" ] || continue
        WAYLAND_DISPLAY="${sock##*/}"
        export WAYLAND_DISPLAY
        break
    done
fi

if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]; then
    echo "start-session-services: no Wayland compositor in $runtime_dir; not starting the session target" >&2
    exit 0
fi

systemctl --user import-environment \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP DISPLAY SWAYSOCK 2>/dev/null || true

# --no-block: sway must never wait on unit starts (a hung service would take the
# session down with it).
systemctl --user --no-block start sway-session.target 2>/dev/null || true

# Units enabled *after* the target was last activated - i.e. everything alatar
# installs into a live session - are not pulled in by a target that is already
# up, so start them by name. is-enabled keeps disabled units out.
for unit in wallpaper.service polkit-gnome.service downloads-watch.service downloads-watch.path downloads-watch.timer; do
    systemctl --user is-enabled "$unit" >/dev/null 2>&1 || continue
    systemctl --user --no-block start "$unit" 2>/dev/null || true
done

exit 0
