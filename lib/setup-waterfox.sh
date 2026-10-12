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
#   * Homepage locks the home/default page to $WATERFOX_INDEX_HTML (file://).
#   * New tab: browser.newtab.url is dead in Firefox-41+ engines, so the
#     script builds a tiny chrome_url_overrides extension around the same
#     index.html and installs it through ExtensionSettings' "path" property
#     (local-path policy installs are exempt from AMO signing).
# Additionally it installs lib/waterfox-userchrome.css (20px undecorated
# tabs) into every Waterfox profile as chrome/userChrome.css and enables
# user stylesheets by appending the legacy-customizations pref to user.js
# (re-applied on every start, safe to write while the browser is running).
# CLI addon installation (old -install-global-extension) no longer exists,
# so policies are the scriptable route.
#
# Run:  bash lib/setup-waterfox.sh
#
# Configuration (env):
#   WATERFOX_BIN           waterfox launcher       (default: found on PATH)
#   WATERFOX_DISTRIBUTION  policies dir            (default: <appdir>/distribution)
#   WATERFOX_DEFAULT_ENGINE default search engine  (default: DuckDuckGo)
#   WATERFOX_INDEX_HTML    home + newtab page file (default: <repo>/index.html)
#
# Extensions: id | latest.xpi URL (AMO redirects to the current signed file).
# Existing policies.json content is preserved and merged.

WATERFOX_BIN="${WATERFOX_BIN:-$(command -v waterfox || true)}"
WATERFOX_DEFAULT_ENGINE="${WATERFOX_DEFAULT_ENGINE:-DuckDuckGo}"

waterfox::script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

WATERFOX_INDEX_HTML="${WATERFOX_INDEX_HTML:-$(waterfox::script_dir)/../index.html}"
WATERFOX_NEWTAB_ID="alatar-newtab@local"
WATERFOX_NEWTAB_XPI="$(waterfox::script_dir)/waterfox-newtab.xpi"

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

waterfox::install_userchrome() {
    # Installs the alatar userChrome.css into every profile listed in
    # profiles.ini and unlocks user stylesheets via user.js. Profile dirs are
    # user-owned, so no sudo is involved.
    local css="$(waterfox::script_dir)/waterfox-userchrome.css"
    local profiles_root="${WATERFOX_PROFILE_ROOT:-$HOME/.waterfox}"
    local ini="$profiles_root/profiles.ini"
    [ -f "$css" ] || { waterfox::log "error: userChrome.css not found: $css"; return 1; }
    [ -f "$ini" ] || { waterfox::log "warn: no profiles.ini at $ini - skipping userChrome"; return 0; }

    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        local pdir
        if [ "${path:0:1}" = "/" ]; then pdir="$path"; else pdir="$profiles_root/$path"; fi
        mkdir -p "$pdir/chrome"
        install -m 644 "$css" "$pdir/chrome/userChrome.css"
        grep -q 'legacyUserProfileCustomizations' "$pdir/user.js" 2>/dev/null || \
            echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' >> "$pdir/user.js"
        waterfox::log "userChrome.css installed: $pdir"
    done < <(grep '^Path=' "$ini" | cut -d= -f2-)
}

waterfox::build_newtab_extension() {
    # Args: <xpi path> <extension id> <page html file> -> writes a minimal
    # MV2 extension whose newtab override is a copy of the page.
    local xpi="$1" id="$2" page="$3" tmp dir
    [ -f "$page" ] || { waterfox::log "error: index page not found: $page"; return 1; }
    tmp="$(mktemp -d)"
    dir="$tmp/alatar-newtab"
    mkdir -p "$dir"
    cp "$page" "$dir/index.html"
    cat > "$dir/manifest.json" <<MANIFEST
{
  "manifest_version": 2,
  "name": "Alatar New Tab",
  "version": "1.0",
  "browser_specific_settings": {"gecko": {"id": "$id"}},
  "chrome_url_overrides": {"newtab": "index.html"}
}
MANIFEST
    python3 - "$xpi" "$dir" <<'ZIP'
import os, sys, zipfile
xpi, src = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(xpi, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for name in files:
            full = os.path.join(root, name)
            z.write(full, os.path.relpath(full, src))
ZIP
    rm -rf "$tmp"
    waterfox::log "newtab extension: $xpi (page: $page)"
}

waterfox::merge_policies() {
    # Args: <policies.json path> <default engine> <homepage URL>
    #       <newtab id|newtab xpi path> <extension entries...> -> merged JSON on stdout.
    # Keeps every existing policy untouched except ExtensionSettings (our
    # entries are set/refreshed), SearchEngines.Default, and Homepage.
    local path="$1" engine="$2" homepage="$3"; shift 3
    python3 - "$path" "$engine" "$homepage" "$@" <<'PY'
import json, os, sys

path, engine, homepage, argv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
newtab_id, newtab_path = argv[0].split("|", 1)
entries = argv[1:]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

policies = data.setdefault("policies", {})

if engine:
    search = policies.setdefault("SearchEngines", {})
    search["Default"] = engine

if homepage:
    policies["Homepage"] = {"Locked": True, "URL": homepage}

settings = policies.setdefault("ExtensionSettings", {})

settings[newtab_id] = {"installation_mode": "force_installed", "path": newtab_path}

for entry in entries:
    guid, url = entry.split("|", 1)
    settings[guid] = {"installation_mode": "force_installed", "install_url": url}

print(json.dumps(data, indent=4) + "\n")
PY
}

waterfox::ensure() {
    command -v python3 >/dev/null 2>&1 || { waterfox::log "error: python3 is required"; return 1; }

    local app_dir dist_dir policies_file tmp index_url
    app_dir="$(waterfox::app_dir)"
    dist_dir="${WATERFOX_DISTRIBUTION:-$app_dir/distribution}"
    policies_file="$dist_dir/policies.json"
    index_url="file://$(readlink -f "$WATERFOX_INDEX_HTML")"

    waterfox::build_newtab_extension "$WATERFOX_NEWTAB_XPI" "$WATERFOX_NEWTAB_ID" "$WATERFOX_INDEX_HTML" || return 1
    waterfox::install_userchrome || waterfox::log "warn: userChrome install failed (continuing)"

    waterfox::log "target: $policies_file"
    waterfox::log "home + newtab: $index_url"

    tmp="$(mktemp)"
    waterfox::merge_policies "$policies_file" "$WATERFOX_DEFAULT_ENGINE" "$index_url" \
        "$WATERFOX_NEWTAB_ID|$WATERFOX_NEWTAB_XPI" "${WATERFOX_EXTENSIONS[@]}" > "$tmp" \
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

    waterfox::log "enforcing: darkreader, vimium, proton-pass, alatar-newtab; default engine: $WATERFOX_DEFAULT_ENGINE; home/newtab: $index_url"
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
