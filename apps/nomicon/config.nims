# apps/nomicon - nimble config.
#
# `import clay` inside the nimble-installed ellipse kit needs one extra
# path: the installed package keeps clay/ as a *sub*directory of its
# package dir (and nim does not resolve a module through a directory
# without init.nim), the same reason ellipse's own Makefile and config.nims
# pass -p:src/clay. Register the clay/ dir of the dependency nimble
# resolves - the one installed at the revision nomicon.nimble pins.
import std/[os, strutils]

const ellipsePinned = "03fa577e00cc61c25b97d604e86d72084ce728b9"

let nimbleDir = getEnv("NIMBLE_DIR", getEnv("HOME", "/root") / ".nimble") / "pkgs2"
if dirExists(nimbleDir):
  for kind, dir in walkDir(nimbleDir):
    if kind == pcDir and dir.splitPath()[1].startsWith("ellipse-"):
      let meta = dir / "nimblemeta.json"
      if fileExists(meta) and ellipsePinned in readFile(meta):
        let clay = dir / "clay"
        if dirExists(clay):
          switch("path", clay)
