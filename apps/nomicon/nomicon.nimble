import std/tables

version       = "0.1.0"
description   = "Nomicon Settings for Alatar"
license       = "MIT"
author        = "dneumann"

srcDir        = "src"
namedBin      = {"nomicon": "nomicon-settings", "launcher": "nomicon-launcher"}.toTable
binDir        = "bin"

requires "nim >= 2.4.0"

# config.nims selects the desktop's patched ellipse checkout.
requires "chroma >= 1.0.0"
requires "https://github.com/nim-lang/sdl3#bb137829ff619b0a27a473628cb28fc1c86f3fe5"
requires "https://github.com/dneumann42/plugnim#fb9605750fff720873c501ff4710ab4322f0f6a4"
