import std/os

switch("path", getEnv("ALATAR_SRC", thisDir() / ".." / ".." / "src"))

# Use the same ellipse checkout as the bar for custom chrome rendering.
let ellipseSrc = getHomeDir() / "Workspace" / "ellipse" / "src"
switch("path", ellipseSrc)
switch("path", ellipseSrc / "clay")
