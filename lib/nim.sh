#!/usr/bin/env bash
# lib/nim.sh - Nim toolchain dependency for alatar.
#
# Installs a globally-available (for the user) Nim of the pinned version by
# symlinking the toolchain into $NIM_USER_BIN (default ~/.local/bin, which
# precedes /usr/bin on typical Arch PATHs). A version change replaces the
# previous installation outright, including one left by choosenim.
#
# Sourced by ./setup (entry point), but also runnable standalone:
#   bash lib/nim.sh
#
# Configuration (set in .env or the environment before sourcing):
#   NIM_VERSION    pinned Nim version    (default: 2.2.12)
#   NIM_URL        override download URL (default: official pre-built tarball)
#   ALATAR_HOME    alatar data dir       (default: ~/.alatar2)
#   NIM_SETUP_DIR  toolchain dir         (default: ~/.local/share/nim)
#   NIM_USER_BIN   user-global bin dir   (default: ~/.local/bin)
#
# After nim::ensure: $NIM_CMD points at the compiler and PATH is updated.

ALATAR_HOME="${ALATAR_HOME:-$HOME/.alatar2}"
NIM_VERSION="${NIM_VERSION:-2.2.12}"
NIM_SETUP_DIR="${NIM_SETUP_DIR:-$HOME/.local/share/nim}"
NIM_USER_BIN="${NIM_USER_BIN:-$HOME/.local/bin}"
NIM_URL="${NIM_URL:-https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz}"
NIM_BIN="$NIM_SETUP_DIR/bin"
NIM_VERSION_MARKER="$NIM_SETUP_DIR/.alatar-nim-version"

nim::log() { printf 'alatar/nim: %s\n' "$*" >&2; }

nim::installed_version() {
    [ -x "$NIM_BIN/nim" ] || return 1
    "$NIM_BIN/nim" --version 2>/dev/null | head -1 | sed -E 's/Nim Compiler Version ([0-9.]+).*/\1/'
}

nim::hijack_choosenim() {
    # Replace choosenim shims in the user bin dir and drop its storage.
    local shim
    for shim in nim nimble nimsuggest nimpretty; do
        if [ -L "$NIM_USER_BIN/$shim" ] && [[ "$(readlink -f "$NIM_USER_BIN/$shim")" == *".choosenim"* ]]; then
            nim::log "replacing choosenim shim: $NIM_USER_BIN/$shim"
            rm -f "$NIM_USER_BIN/$shim"
        fi
    done
    if [ -d "$HOME/.choosenim" ]; then
        nim::log "removing choosenim data: $HOME/.choosenim"
        rm -rf "$HOME/.choosenim"
    fi
    if command -v choosenim >/dev/null 2>&1; then
        nim::log "note: choosenim binary still on PATH at $(command -v choosenim) - remove it yourself if done with it"
    fi
}

nim::install_prebuilt() {
    for dep in curl tar xz; do
        command -v "$dep" >/dev/null 2>&1 || { nim::log "error: $dep is required"; return 1; }
    done

    # Wipe any previous installation (ours or a stale partial one): a version
    # change must fully override the old toolchain.
    if [ -d "$NIM_SETUP_DIR" ]; then
        nim::log "replacing previous nim installation in $NIM_SETUP_DIR"
        rm -rf "$NIM_SETUP_DIR"
    fi

    nim::log "installing nim $NIM_VERSION from pre-built binaries"
    local tmp
    tmp="$(mktemp -d)"

    nim::log "downloading $NIM_URL"
    curl -fL --retry 3 -o "$tmp/nim.tar.xz" "$NIM_URL"

    nim::log "extracting to $NIM_SETUP_DIR"
    mkdir -p "$NIM_SETUP_DIR"
    tar -xJf "$tmp/nim.tar.xz" -C "$NIM_SETUP_DIR" --strip-components=1
    rm -rf "$tmp"

    # The pre-built tree is self-contained: bin/{nim,nimble,nimsuggest,...}
    # plus config/ and lib/. Verify the bundled compiler actually runs.
    if [ -x "$NIM_BIN/nim" ] && ! "$NIM_BIN/nim" --version >/dev/null 2>&1; then
        nim::log "error: extracted nim does not run"
        return 1
    fi
    echo "$NIM_VERSION" > "$NIM_VERSION_MARKER"
}

nim::link_global() {
    mkdir -p "$NIM_USER_BIN"
    local tool name
    for tool in "$NIM_BIN"/*; do
        name="$(basename "$tool")"
        ln -sf "$tool" "$NIM_USER_BIN/$name"
    done
    nim::log "linked $(ls "$NIM_BIN" | tr '\n' ' ') into $NIM_USER_BIN"
}

nim::ensure() {
    # Migrate away from the old pre-user-global layout: drop any toolchain
    # slot left inside ALATAR_HOME (unless it is the explicitly configured one).
    if [ "$NIM_SETUP_DIR" != "$ALATAR_HOME/nim" ] && [ -e "$ALATAR_HOME/nim" ]; then
        nim::log "removing old toolchain slot: $ALATAR_HOME/nim"
        rm -rf "$ALATAR_HOME/nim"
    fi

    local have
    have="$(nim::installed_version || true)"

    if [ "$have" != "$NIM_VERSION" ] || [ ! -f "$NIM_VERSION_MARKER" ]; then
        nim::install_prebuilt
    else
        nim::log "nim $NIM_VERSION already installed in $NIM_SETUP_DIR"
    fi

    nim::hijack_choosenim
    nim::link_global

    PATH="$NIM_USER_BIN:$NIM_BIN:$PATH"
    export PATH
    NIM_CMD="$NIM_BIN/nim"
    [ -x "$NIM_CMD" ] || { nim::log "error: no nim binary at $NIM_CMD"; return 1; }

    # Warn (but don't touch) about system-wide nim outside our control.
    if [ -e /usr/bin/nim ] && [ "$(readlink -f /usr/bin/nim)" != "$(readlink -f "$NIM_CMD")" ]; then
        nim::log "note: a system nim exists at /usr/bin/nim ($(nim --version 2>/dev/null | head -1)); $NIM_USER_BIN shadows it for this user. To remove: sudo pacman -Rns nim"
    fi

    nim::log "using: $("$NIM_CMD" --version | head -1)"

    # Smoke test: compile and run a throwaway program (no files left behind).
    local smoke_dir smoke_out
    smoke_dir="$(mktemp -d)"
    printf 'echo "Hello from Nim!"\n' > "$smoke_dir/smoke.nim"
    smoke_out="$("$NIM_CMD" r "$smoke_dir/smoke.nim" 2>&1 | tail -1)" \
        || { rm -rf "$smoke_dir"; nim::log "error: smoke test failed: $smoke_out"; return 1; }
    rm -rf "$smoke_dir"
    nim::log "smoke test: $smoke_out"

    if [ -x "$NIM_BIN/nimble" ]; then
        nim::log "nimble: $("$NIM_BIN/nimble" --version 2>/dev/null | head -1 || echo unknown)"
    else
        nim::log "warning: nimble not found - package management unavailable"
    fi
}

# Standalone execution: bash lib/nim.sh
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    nim::ensure "$@"
fi
