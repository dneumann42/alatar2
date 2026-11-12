# apps/tray - nimble config.
#
# The strip UI runs on the phase-2 patched ellipse kit (layer corner
# anchors + resize, overlay icon textures), unmerged in the private
# checkout: add its source dirs to the search path instead of a nimble
# dependency (see tray.nimble). `import clay` needs the extra clay dir
# entry - the same kit Makefile trick apps/nomicon copies.
#
# tinydbus is vendored (vendor/tinydbus) instead of a nimble dependency:
# one annotation is required for the kit's GC-safe fd-callback contract
# (addVariant's value proc marked {.gcsafe.}; upstream PR pending). The
# vendor dir must precede any installed copy on the search path - the
# requires line is gone from tray.nimble, so it is the only one.
switch("threads", "on")
switch("define", "tinydbus.disableValidation")

when defined(posix):
  import std/[os, strutils]

  switch("path", getEnv("ALATAR_SRC", getEnv("HOME", "/root")) /
         ".alatar" / "apps" / "tray" / "vendor" / "tinydbus")

  let ws = getEnv("HOME", "/root") / "Workspace" / "ellipse" / "src"
  if dirExists(ws / "ellipse_ui"):
    switch("path", ws)
    switch("path", ws / "clay")
  else:
    echo "apps/tray needs the patched ellipse checkout at ~/Workspace/ellipse"
    quit(1)
