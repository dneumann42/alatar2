# Package

version       = "0.1.0"
description   = "Nomicon: alatar's GUI apps on the ellipse kit (SDL3 + clay immediate-mode UI)."
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
bin           = @["nomicon"]
binDir        = "bin"

requires "nim >= 2.4.0"

# ellipse lives in a private repo, so the dependency is an ssh URL (nimble
# clones with your ssh key); the ref pins the tested main commit - bump it
# when ellipse moves. Its own deps (chroma, sdl3, plugnim) resolve from
# nimble's package list / public git URLs.
requires "ssh://git@github.com/dneumann42/ellipse#03fa577e00cc61c25b97d604e86d72084ce728b9"
