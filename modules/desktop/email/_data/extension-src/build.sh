#!/bin/sh
# Rebuild the provisioning xpi from extension-src after any change here.
# Output lands at ../extension/<em:id>.xpi (profile cells require the id as
# filename) and alatar symlinks that into
# ~/.thunderbird/alatar.default-release/extensions/. Bump "version" in
# manifest.json when you change the code: the cell updates an installed
# entry on version change AND a version change is what hot-loads a fresh
# background instead of waiting for another full Thunderbird start.
set -eu
cd "$(dirname "$0")"
OUT=../extension/proton-bridge-provision@dneumann.dev.xpi
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# python3 -m zipfile keeps the build dependency-free (no `zip` binary needed).
python3 -m zipfile -c "$OUT" manifest.json schema.json api.js background.js
echo "wrote $OUT"
