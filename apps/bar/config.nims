# apps/bar - nimble config.
#
# The swaybar replacement runs on the same phase-2 patched ellipse kit as
# apps/tray (layer corner anchors + resize, overlay icon textures, and the
# per-output layer placement / middle-button / pointer-position additions
# this project needed): config.nims puts ~/Workspace/ellipse/src on the
# search path instead of a nimble dependency. `import clay` needs the extra
# clay dir entry - the same kit Makefile trick apps/nomicon copies.
#
# The tray modules (SNI host, tinydbus plumbing, dbusmenu, gothic menu
# theme, icon decoding) are imported straight from ../tray/src: the bar IS
# the tray host now, no IPC between the two. tinydbus stays vendored under
# apps/tray/vendor (one {.gcsafe.} annotation upstream PR pending); its
# path must precede any installed copy on the search path.
switch("threads", "on")
switch("define", "tinydbus.disableValidation")

when defined(posix):
  import std/[os, strutils]

  let home = getEnv("HOME", "/root")
  switch("path", thisDir() / ".." / ".." / "src")
  switch("path", getEnv("ALATAR_SRC", home) /
         ".alatar" / "apps" / "tray" / "vendor" / "tinydbus")
  switch("path", home / ".alatar" / "apps" / "tray" / "src")

  let ws = home / "Workspace" / "ellipse" / "src"
  if dirExists(ws / "ellipse_ui"):
    switch("path", ws)
    switch("path", ws / "clay")
  else:
    echo "apps/bar needs the patched ellipse checkout at ~/Workspace/ellipse"
    quit(1)
