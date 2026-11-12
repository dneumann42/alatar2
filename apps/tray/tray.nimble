version       = "0.1.0"
description   = "Tray: SNI tray host with dbusmenu rendering for sway (tinydbus + ellipse)."
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
bin           = @["tray"]
binDir        = "bin"

requires "nim >= 2.4.0"

# tinydbus is VENDORED under vendor/tinydbus (one {.gcsafe.} annotation on
# addVariant's callback for the kit's fd-callback contract; upstream PR
# pending) - no nimble requires line; see config.nims.

# The GUI kit itself is NOT a nimble dependency while the phase-2 patches
# (layer corner anchors + resize, overlay icon textures) live unmerged in
# the private ellipse checkout: config.nims puts ~/Workspace/ellipse/src
# on the search path instead. Its own dependencies are mirrored here so
# resolution stays complete (keep in sync with the kit's nimble file).
requires "chroma >= 1.0.0"
requires "https://github.com/nim-lang/sdl3#bb137829ff619b0a27a473628cb28fc1c86f3fe5"
requires "https://github.com/dneumann42/plugnim#fb9605750fff720873c501ff4710ab4322f0f6a4"
