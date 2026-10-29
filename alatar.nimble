# Package

version       = "0.0.0"
description   = "Generated Nim project"
author        = "dneumann"
license       = "MIT"
srcDir        = "src"
bin           = @["alatar"]
binDir        = "bin/"

requires "nim >= 2.4.0", "parsetoml", "cligen", "regex"
