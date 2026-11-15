## Bar buttons: `statusbar/buttons.toml`, the config the old GTK4
## barbuttons rendered, drawn inside the bar instead. Same file, same
## live-edit behaviour (bar.nim re-reads it on change), same visual slot
## maths - one `button_width` cell per entry, left buttons stacked
## left-to-right from the screen edge in file order, right buttons stacked
## from the right edge. `command` runs detached through `sh`, like the
## GTK buttons did.

import std/[math, os, strutils, unicode]
import ellipse_ui

{.push gcsafe.}

type
  BarButton* = ref object
    side*: string      ## "left" | "right"
    icon*: string      ## resolved file path ("" if none)
    glyph*, command*: string

  ButtonsCfg* = object
    buttonWidth*: int
    iconHeight*: int
    background*, hoverBackground*: Color
    foreground*, hoverForeground*: Color
    fontSize*: int
    items*: seq[BarButton]

func hexColor(s: string): Color =
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

func toPx*(pt: int): int =
  ## The kit measures glyphs in pixels (its Inter default sizes are pixels);
  ## buttons.toml gives a pango POINT size, as sway's `font pango:$font 11`
  ## did. pango draws pt at the panel's 96 dpi: px = pt * 96/72. Without
  ## this the button glyphs would sit visibly smaller than the status text
  ## next to them (which bar.nim already sizes the same way).
  max(8, int(round(pt.float32 * 96'f32 / 72'f32)))

func decodeUnicodeEsc(s: string): string =
  ## `"a\tb"` and `"\uf013"` become their text: quoted TOML strings carry
  ## the bar's Nerd Font codepoints, which barbuttons got from parsetoml.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i+1]
      of 'n': result.add '\n'; inc i, 2
      of 't': result.add '\t'; inc i, 2
      of 'r': result.add '\r'; inc i, 2
      of '"': result.add '"'; inc i, 2
      of '\\': result.add '\\'; inc i, 2
      of 'u', 'U':
        let digits = if s[i+1] == 'u': 4 else: 8
        if i + 2 + digits <= s.len:
          try:
            let cp = parseHexInt(s[i + 2 ..< i + 2 + digits])
            var rs = newSeq[Rune](1)
            rs[0] = Rune(uint32(cp))
            result.add $rs
            inc i, 2 + digits
            continue
          except ValueError: discard
        result.add s[i]; inc i
      else:
        result.add s[i]; inc i
    else:
      result.add s[i]; inc i

func unq(v: string): string =
  ## Strip TOML quotes (mirrors the subset parser tray.nim grew), then
  ## decode string escapes. `'''...'''` is the literal form buttons.toml
  ## uses for the multi-quote shell commands: taken verbatim.
  var val = v.strip
  if val.startsWith("'''") and val.endsWith("'''") and val.len >= 6:
    return val[3 ..< val.len - 3]
  if val.startsWith('"'):
    let close = val.find('"', 1)
    val = if close >= 0: val[1 ..< close] else: val
    return decodeUnicodeEsc(val)
  let hash = val.find('#')
  if hash >= 0: val = val[0 ..< hash].strip
  val

func parseIntSafe(v: string, def: int): int =
  try: parseInt(v) except ValueError: def

proc buttonsFile*(): string =
  getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") /
    "sway" / "statusbar" / "buttons.toml"

proc parse*(text: string): ButtonsCfg =
  ## The TOML subset buttons.toml uses: bare `key = value` globals and
  ## `[[button]]` tables. Values here are ints, colours and quoted strings.
  result.buttonWidth = 24
  result.iconHeight = 16
  result.fontSize = 11
  result.background = hexColor("#000000")
  result.hoverBackground = hexColor("#1c1f26")
  result.foreground = hexColor("#9aa4b2")
  result.hoverForeground = hexColor("#e6eaf2")
  var cur: BarButton = nil
  let dir = buttonsFile().parentDir
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line.startsWith('#'): continue
    if line == "[[button]]":
      cur = BarButton(side: "left")
      result.items.add cur
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip
    let val = unq(line[eq + 1 ..^ 1])
    if cur != nil:
      case key
      of "side": cur.side = val
      of "icon": cur.icon = if not val.startsWith("/"): dir / val else: val
      of "glyph": cur.glyph = val
      of "command": cur.command = val
      else: discard
    else:
      case key
      of "button_width": result.buttonWidth = parseIntSafe(val, 24)
      of "icon_height": result.iconHeight = parseIntSafe(val, 16)
      of "font_size": result.fontSize = parseIntSafe(val, 11)
      of "background": result.background = hexColor(val)
      of "hover_background": result.hoverBackground = hexColor(val)
      of "foreground": result.foreground = hexColor(val)
      of "hover_foreground": result.hoverForeground = hexColor(val)
      else: discard

proc rightWidth*(cfg: ButtonsCfg): int =
  ## The span the right-side buttons occupy: the margin a dropped menu
  ## child keeps clear of them (barbuttons' old job, now the bar's).
  var n = 0
  for b in cfg.items:
    if b.side == "right": inc n
  n * cfg.buttonWidth
