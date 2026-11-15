## Bar palette: the sway variables the old swaybar read, parsed from the
## same files sway does. `appearance.conf` seeds the pre-theme defaults and
## its wallust include (`~/.cache/wallust/sway-*.conf`) overrides them once
## a theme exists - exactly sway's substitution order, so a wallpaper switch
## (which rewrites the include and reloads sway) recolors the bar too, here
## without needing the reload. Re-read on mtime change; no GC pressure.

import std/[os, strutils, tables]
import ellipse_ui

{.push gcsafe.}

type
  Palette* = object
    vars*: Table[string, Color]

proc hexColor(s: string): Color =
  ## `#rgb`, `#rrggbbaa` and `#rrggbb`, wallust/sway style.
  var h = s.strip
  if h.startsWith('#'): h = h[1..^1]
  template byte(x: string): float32 = float32(parseHexInt(x))
  try:
    case h.len
    of 3: rgb(byte(h[0..0] & h[0..0]), byte(h[1..1] & h[1..1]),
              byte(h[2..2] & h[2..2]))
    of 6: rgb(byte(h[0..1]), byte(h[2..3]), byte(h[4..5]))
    of 8: rgb(byte(h[0..1]), byte(h[2..3]), byte(h[4..5]), byte(h[6..7]))
    else: Color()
  except ValueError:
    Color()

proc feed(p: var Palette; text: string) =
  ## Apply `set $name value` lines; hex values only, sway's other sets
  ## (workspace names, font families) are not colours and pass by.
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line.startsWith('#'): continue
    if not line.startsWith("set "): continue
    # maxSplit=2 keeps the value verbatim - WITH its leading whitespace,
    # so it must be stripped before the hex test.
    let parts = line.split(WhiteSpace, maxSplit = 2)
    if parts.len < 3: continue
    if not parts[1].startsWith('$'): continue
    let val = parts[2].strip
    if val.startsWith('#'):
      p.vars[parts[1]] = hexColor(val)

proc swayConfigDir(): string =
  getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "sway"

var
  cacheText {.threadvar.}: string   ## signature of everything parsed
  cache {.threadvar.}: Palette

proc refresh*(): Palette =
  ## The live palette: defaults from appearance.conf, wallust overrides on
  ## top. Cached by content, so the per-frame call costs two file reads
  ## only when either file changed.
  var sig = ""
  var p = Palette(vars: initTable[string, Color]())
  let app = swayConfigDir() / "appearance.conf"
  try:
    let t = readFile(app)
    sig.add t
    feed(p, t)
  except CatchableError: discard
  let cacheDir = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "wallust"
  if dirExists(cacheDir):
    for kind, f in walkDir(cacheDir):
      let (_, name, ext) = splitFile(f)
      # splitFile keeps the dot: ext == ".conf"
      if kind != pcFile or ext != ".conf" or not name.startsWith("sway-"):
        continue
      try:
        let t = readFile(f)
        sig.add t
        feed(p, t)
      except CatchableError: discard
  if sig != cacheText:
    cacheText = sig
    cache = p
  cache

proc get*(p: Palette; name: string; fallback: Color): Color =
  p.vars.getOrDefault("$" & name, fallback)
