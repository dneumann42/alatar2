#!/usr/bin/env bash
# lib/setup-waterfox.sh - Browser configuration for Waterfox.
#
# Installs extensions and pins the default search engine declaratively via
# the enterprise-policies mechanism in <appdir>/distribution/policies.json:
#   * ExtensionSettings entries with installation_mode=force_installed make
#     Waterfox download and enable each extension from its AMO URL on next
#     start (and keep it enforced after).
#   * SearchEngines.Default sets the default search engine (must match the
#     exact name of an engine the browser knows; DuckDuckGo ships built-in).
# CLI addon installation (old -install-global-extension) no longer exists,
# so policies are the scriptable route.
#
# Run:  bash lib/setup-waterfox.sh
#
# Configuration (env):
#   WATERFOX_BIN           waterfox launcher       (default: found on PATH)
#   WATERFOX_DISTRIBUTION  policies dir            (default: <appdir>/distribution)
#   WATERFOX_DEFAULT_ENGINE default search engine  (default: DuckDuckGo)
#
# Extensions: id | latest.xpi URL (AMO redirects to the current signed file).
# Existing policies.json content is preserved and merged.

WATERFOX_BIN="${WATERFOX_BIN:-$(command -v waterfox || true)}"
WATERFOX_DEFAULT_ENGINE="${WATERFOX_DEFAULT_ENGINE:-DuckDuckGo}"

WATERFOX_EXTENSIONS=(
    "addon@darkreader.org|https://addons.mozilla.org/firefox/downloads/latest/darkreader/latest.xpi"
    "{d7742d87-e61d-4b78-b8a1-b469842139fa}|https://addons.mozilla.org/firefox/downloads/latest/vimium-ff/latest.xpi"
    "78272b6fa58f4a1abaac99321d503a20@proton.me|https://addons.mozilla.org/firefox/downloads/latest/proton-pass/latest.xpi"
)

waterfox::log() { printf 'alatar/waterfox: %s\n' "$*" >&2; }

waterfox::app_dir() {
    [ -n "$WATERFOX_BIN" ] || { waterfox::log "error: waterfox not found on PATH"; return 1; }
    dirname "$(readlink -f "$WATERFOX_BIN")"
}

waterfox::merge_policies() {
    # Args: <policies.json path> <default engine> <extension entries...> -> merged JSON on stdout.
    # Keeps every existing policy untouched except ExtensionSettings (our
    # entries are set/refreshed) and SearchEngines.Default.
    local path="$1" engine="$2"; shift 2
    python3 - "$path" "$engine" "$@" <<'PY'
import json, os, sys

path, engine, entries = sys.argv[1], sys.argv[2], sys.argv[3:]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

policies = data.setdefault("policies", {})

if engine:
    search = policies.setdefault("SearchEngines", {})
    search["Default"] = engine

settings = policies.setdefault("ExtensionSettings", {})

for entry in entries:
    guid, url = entry.split("|", 1)
    settings[guid] = {"installation_mode": "force_installed", "install_url": url}

print(json.dumps(data, indent=4) + "\n")
PY
}

waterfox::ensure() {
    command -v python3 >/dev/null 2>&1 || { waterfox::log "error: python3 is required"; return 1; }

    local app_dir dist_dir policies_file tmp
    app_dir="$(waterfox::app_dir)"
    dist_dir="${WATERFOX_DISTRIBUTION:-$app_dir/distribution}"
    policies_file="$dist_dir/policies.json"

    waterfox::log "target: $policies_file"

    tmp="$(mktemp)"
    waterfox::merge_policies "$policies_file" "$WATERFOX_DEFAULT_ENGINE" "${WATERFOX_EXTENSIONS[@]}" > "$tmp" \
        || { rm -f "$tmp"; return 1; }

    if [ -f "$policies_file" ] && cmp -s "$tmp" "$policies_file"; then
        waterfox::log "policies already up to date"
        rm -f "$tmp"
        return 0
    fi

    # /opt is root-owned; write through sudo (needs a terminal for the password
    # unless passwordless sudo is set up).
    if [ -w "$dist_dir" ]; then
        install -m 644 "$tmp" "$policies_file"
    else
        waterfox::log "writing via sudo"
        sudo install -m 644 "$tmp" "$policies_file" || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"

    waterfox::log "enforcing: darkreader, vimium, proton-pass; default engine: $WATERFOX_DEFAULT_ENGINE"
    if pgrep -x waterfox >/dev/null 2>&1; then
        waterfox::log "note: waterfox is running - restart it to apply"
    else
        waterfox::log "extensions will install on next waterfox start"
    fi
}

# Standalone execution: bash lib/setup-waterfox.sh
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    waterfox::ensure "$@"
fi
