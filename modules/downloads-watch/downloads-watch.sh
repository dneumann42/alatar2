#!/bin/sh
# ============================================================================
# downloads-watch: ask about files in Downloads that tidy.toml wants
# somewhere else, and move them when the answer is yes.
#
# Triggered by downloads-watch.path (systemd's inotify watch on the
# directory) and by downloads-watch.timer every 25 minutes as a safety net;
# sway-session.target also asks once at login. Runs as downloads-watch.service.
# `alatar tidy --dry` lists the out-of-place files; if there are any, a mako
# notification carries a "default" action ("Move them"), so its button *and*
# a left click (see the mako config in desktop/_config) both answer.
# notify-send --wait keeps this oneshot unit busy while the question is open -
# further triggers merge into the running instance, so the user is never
# nagged twice in parallel. On "Move them": run the tidy, then a second
# notification reports the result. Dismiss or expiry leaves everything alone.
# ============================================================================
set -u

dir="${DOWNLOADS_DIR:-$HOME/Downloads}"

alatar=""
for c in "${ALATAR_BIN:-}" "$HOME/.local/bin/alatar" "$HOME/.alatar/bin/alatar"; do
    [ -n "$c" ] && [ -x "$c" ] && { alatar="$c"; break; }
done
if [ -z "$alatar" ]; then
    alatar="$(command -v alatar 2>/dev/null || true)"
fi
if [ -z "$alatar" ]; then
    echo "downloads-watch: no alatar binary found (set ALATAR_BIN)" >&2
    exit 1
fi

outp="$("$alatar" tidy --dry "$dir")"
rc=$?
if [ $rc -eq 0 ]; then
    exit 0 # everything in place
fi
if [ $rc -ge 2 ] || [ -z "$outp" ]; then
    echo "downloads-watch: 'tidy --dry' failed with code $rc" >&2
    exit 1
fi

count=$(printf '%s\n' "$outp" | wc -l)
# mako wraps long lines, so show "file -> ~/target/dir" instead of the pair
# of absolute paths tidy prints for scripting use.
body=$(printf '%s\n' "$outp" | head -n 12 |
    sed -E "s|^.*/([^/]+) +-> +(.*)/[^/]*$|\1 -> \2|; s|$HOME|~|")
if [ "$count" -gt 12 ]; then
    body="$body
... and $((count - 12)) more"
fi

answer="$(notify-send --wait -t 600000 -u normal \
    -c downloads-tidy \
    -A "default=Move them" \
    -A "skip=Leave them" \
    "Downloads: $count file(s) out of place" "$body")"
rc=$?
if [ $rc -ne 0 ]; then
    echo "downloads-watch: notify-send failed (is mako running?)" >&2
    exit 1
fi

# Anything but the default action (skip button, dismiss, 10 min expiry) is a
# no: leave the files where they are. The next trigger asks again.
if [ "$answer" != "default" ]; then
    exit 0
fi

moved_log="$("$alatar" tidy "$dir")"
rc=$?
if [ $rc -ne 0 ]; then
    notify-send -u critical -t 30000 \
        "Downloads tidy failed" \
        "alatar exited $rc - see: journalctl --user -u downloads-watch.service"
    exit 1
fi

moved=$(printf '%s\n' "$moved_log" | grep -c '^moved ' || true)
left="$("$alatar" tidy --dry "$dir" 2>/dev/null | sed '/^$/d' | wc -l)"
if [ "$left" -gt 0 ]; then
    notify-send -t 20000 "Downloads tidied" \
        "moved $moved of $count; $left stayed put (no rule for them yet)"
else
    notify-send -t 20000 "Downloads tidied" "moved $moved file(s)"
fi
exit 0
