## Shared palette and persisted theme selection for Alatar desktop applications.
import std/[algorithm, monotimes, os, strutils, tables, tempfiles]
import ellipse_ui
import ellipse/platform/termmode
import ./desktopchrome

const
  builtinNames = ["Parchment", "Walnut", "Slate", "Evergreen", "Wallust"]
  themeFrameInterval* = 150_000_000'i64

type DesktopPalette* = object
  light*: bool
  opacity*: float32
  background*, surface*, text*, muted*, accent*, accent2*, border*, urgent*, onAccent*: Color

var
  paletteCache {.threadvar.}: DesktopPalette
  refreshAt {.threadvar.}: int64

func hexColor*(value: string): Color =
  let hex = value.strip.strip(chars = {'#'}, trailing = false)
  if hex.len notin [3, 6, 8] or not hex.allCharsInSet(HexDigits): return
  if hex.len == 3:
    return rgb(float32(parseHexInt(repeat(hex[0], 2))),
               float32(parseHexInt(repeat(hex[1], 2))),
               float32(parseHexInt(repeat(hex[2], 2))))
  rgb(float32(parseHexInt(hex[0..1])), float32(parseHexInt(hex[2..3])),
      float32(parseHexInt(hex[4..5])),
      if hex.len == 8: float32(parseHexInt(hex[6..7])) else: 255)

proc configDir(): string =
  getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "alatar"

proc themeDir(): string = configDir() / "themes"

proc readOptional(path: string): string =
  try: readFile(path)
  except IOError: ""

proc themeNames*(): seq[string] =
  result = @builtinNames
  var custom: seq[string]
  for path in walkFiles(themeDir() / "*.conf"):
    let name = path.splitFile.name
    if name.len > 0 and name.strip == name and '\n' notin name and '\r' notin name and
        name notin builtinNames:
      custom.add name
  custom.sort()
  result.add custom

proc validTheme(name: string): bool =
  name in builtinNames or
    (name.len > 0 and name.extractFilename == name and name notin [".", ".."] and
      '\0' notin name and fileExists(themeDir() / (name & ".conf")))

proc selectedTheme*(): string =
  let name = readOptional(configDir() / "theme").strip
  if validTheme(name): name else: builtinNames[0]

proc selectTheme*(name: string) =
  if not validTheme(name):
    raise newException(ValueError, "Unknown desktop theme: " & name)
  let dir = configDir()
  createDir(dir)
  let (file, path) = createTempFile(".theme-", "", dir)
  try:
    try: file.writeLine(name)
    finally: file.close()
    moveFile(path, dir / "theme")
  finally:
    if fileExists(path): removeFile(path)
  refreshAt = 0
  requestFrame()

func colors(light: bool, bg, surface, ink, muted, accent, accent2, border,
            urgent, onAccent: string): DesktopPalette =
  DesktopPalette(light: light, opacity: 0.85, background: hexColor(bg), surface: hexColor(surface),
    text: hexColor(ink), muted: hexColor(muted), accent: hexColor(accent),
    accent2: hexColor(accent2), border: hexColor(border), urgent: hexColor(urgent),
    onAccent: hexColor(onAccent))

func builtin(name: string, light: bool): DesktopPalette =
  if light:
    case name
    of "Walnut": colors(true, "dbbd9d", "d1ae87", "291b13", "533929", "734827", "634531", "86664e", "99253c", "fff7e9")
    of "Slate": colors(true, "d6dfe5", "bccbd6", "18232c", "394e60", "36556e", "3a5066", "647988", "982541", "f7fbff")
    of "Evergreen": colors(true, "d7dfcc", "bdcbb1", "1b291c", "40543d", "36563e", "47532e", "6a7d63", "982541", "f6f8ec")
    else: colors(true, "d3cec7", "c6beb1", "211b17", "493e35", "594332", "615233", "887664", "96273d", "fff6e7")
  else:
    case name
    of "Walnut": colors(false, "2c1e18", "493027", "f5dfca", "d1b295", "a87651", "a67464", "95735d", "ff99aa", "21140e")
    of "Slate": colors(false, "202a32", "34434f", "e5eff6", "b0c5d3", "81a9c4", "88a5cb", "6c8397", "ff9bb0", "15222e")
    of "Evergreen": colors(false, "222c23", "364736", "e8efda", "b7c8a8", "96b783", "b5b779", "718971", "ffa3a6", "172219")
    else: colors(false, "322822", "483b32", "f4e8d8", "ccb7a3", "c5a375", "b79c76", "9a8069", "ffa2aa", "221a14")

func overrides(contents: string): Table[string, string] =
  for raw in contents.splitLines:
    let line = raw.strip
    let sep = line.find('=')
    if sep < 0 or line.startsWith('#'): continue
    result[line[0 ..< sep].strip] = line[sep + 1 .. ^1].strip

func applyOverrides(p: var DesktopPalette, contents: string) =
  let values = overrides(contents)
  let mode = if p.light: "light." else: "dark."
  template role(field: untyped, key: string) =
    for name in [key, mode & key]:
      let color = hexColor(values.getOrDefault(name))
      if color.a > 0: p.field = color
  for name in ["opacity", mode & "opacity"]:
    try:
      let opacity = parseFloat(values.getOrDefault(name))
      if opacity >= 0 and opacity <= 1: p.opacity = opacity.float32
    except ValueError:
      discard
  role(background, "background")
  role(surface, "surface")
  role(text, "text")
  role(muted, "muted")
  role(accent, "accent")
  role(accent2, "accent2")
  role(border, "border")
  role(urgent, "urgent")
  role(onAccent, "on_accent")

proc wallust(p: var DesktopPalette) =
  # Wallust's existing bar template is the single generated palette source.
  let cache = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache")
  let relative = "wallust" / "bar-theme.conf"
  var contents = readOptional(cache / relative)
  if contents.len == 0: contents = readOptional(getHomeDir() / ".cache" / relative)
  let fallback = p
  let paper = hexColor("e0ded6")
  let ink = hexColor("181718")
  for raw in contents.splitLines:
    let parts = raw.splitWhitespace()
    if parts.len != 3 or parts[0] != "set": continue
    var value = hexColor(parts[2])
    if parts[1] == "$bar_bg":
      let hex = parts[2].strip(chars = {'#'}, trailing = false)
      if hex.len == 8 and hex.allCharsInSet(HexDigits):
        p.opacity = value.a / 255
        value.a = 255
    if value.a == 0: continue
    value.a = 255
    case parts[1]
    of "$bar_bg":
      if not p.light: p.background = value
    of "$surface": p.surface = if p.light: lerp(paper, value, 0.16) else: value
    of "$text": p.text = if p.light: lerp(ink, value, 0.06) else: value
    of "$muted": p.muted = if p.light: lerp(ink, value, 0.25) else: value
    of "$accent":
      if p.light: p.background = lerp(paper, value, 0.13)
      p.accent = if p.light: lerp(ink, value, 0.37) else: value
    of "$accent2": p.accent2 = if p.light: lerp(ink, value, 0.37) else: value
    of "$inactive": p.border = if p.light: lerp(paper, value, 0.43) else: value
    of "$urgent":
      if not p.light: p.urgent = value
    else: discard
  p.onAccent = contrastingInk(p.accent, fallback.onAccent)

proc desktopPalette*(dark: bool): DesktopPalette =
  let now = getMonoTime().ticks
  if now < refreshAt and paletteCache.light == not dark:
    return paletteCache
  let name = selectedTheme()
  result = builtin(name, not dark)
  if name == "Wallust":
    result.wallust()
  result.applyOverrides(readOptional(themeDir() / (name & ".conf")))
  paletteCache = result
  refreshAt = now + themeFrameInterval

proc applyChrome*(p: DesktopPalette) =
  updateChrome(p.background, p.surface, p.accent, p.accent2, p.urgent, p.light, p.opacity)

proc desktopTheme*(p: DesktopPalette): Theme =
  result = defaultTheme()
  let white = rgb(255, 255, 255)
  let black = rgb(0, 0, 0)
  let opacity = if terminalMode(): 1'f32 else: p.opacity
  template fill(color: Color): Color = withOpacity(color, opacity)
  result.palette = Palette(
    bg: fill(p.background), panelBg: fill(p.background), panelBorder: p.border,
    buttonBg: fill(p.surface), buttonHoverBg: fill(lerp(p.surface, white, 0.16)),
    buttonPressBg: fill(lerp(p.surface, black, 0.14)),
    fieldBg: fill(lerp(p.background, if p.light: white else: black, 0.30)),
    selectedBg: fill(lerp(p.surface, p.accent, 0.22)), accent: p.accent,
    textColor: p.text, dimColor: p.muted, labelColor: p.muted, onAccent: p.onAccent,
    shadow: rgb(0, 0, 0, 90))
  result.radii = Radii()
  result.text.button = 15
  result.text.control = 15
  result.text.menu = 14
  result.text.option = 14
  result.text.chevron = 13
  result.text.caption = 13
  result.metrics.padButton = 6
  result.metrics.padFieldX = 8
  result.metrics.padFieldY = 5
  result.metrics.controlHeight = 30
  result.metrics.toolbarHeight = 38
  result.metrics.pressOffset = 1
  result.scrollbar = ScrollbarStyle(width: 10, margin: 3, minThumb: 24,
    track: lerp(p.background, p.border, 0.35), thumb: p.border,
    thumbHot: lerp(p.border, p.text, 0.35))
  result.cells.buttonShadow = p.border
  result.cells.focusShadow = p.accent

proc applyDesktopTheme*(dark: bool) =
  let p = desktopPalette(dark)
  setTheme(desktopTheme(p))
  p.applyChrome()
  requestFrameIn(themeFrameInterval)
