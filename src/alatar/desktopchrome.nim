## Square two-step bevels and gradients painted behind Clay's content.

import std/math
import ellipse_ui
import ellipse/platform/termmode

when withSdl:
  from sdl3 import nil

{.push gcsafe.}

type
  Chrome* = enum
    panel, raised, hovered, pressedButton, selected, attention, bindingMode

  Surface = object
    start, finish, highlight, shadow: Color

var
  surfaces {.threadvar.}: array[Chrome, Surface]
  revisions {.threadvar.}: array[Chrome, uint64]

proc token(kind: Chrome): pointer =
  unsafeAddr surfaces[kind]

when withSdl:
  proc gradient(box: Rect; start, finish: Color; horizontal: bool) =
    let ren = cast[sdl3.Renderer](sdlRenderer())
    let x = box.x + box.width
    let y = box.y + box.height
    func vertex(px, py: float32; c: Color): sdl3.Vertex =
      sdl3.Vertex(position: sdl3.FPoint(x: px, y: py),
        color: sdl3.FColor(r: c.r / 255, g: c.g / 255, b: c.b / 255, a: c.a / 255))
    var vertices = [
      vertex(box.x, box.y, start),
      vertex(x, box.y, if horizontal: finish else: start),
      vertex(x, y, finish),
      vertex(box.x, y, if horizontal: start else: finish)]
    var indices = [0.cint, 1, 2, 0, 2, 3]
    discard sdl3.setRenderDrawBlendMode(ren, sdl3.BLENDMODE_BLEND)
    discard sdl3.renderGeometry(ren, nil, addr vertices[0], 4, addr indices[0], 6)

  proc paint(cmd: RenderCommand; kind: Chrome) =
    let s = surfaces[kind]
    let r = cmd.box
    if r.width <= 4 or r.height <= 4: return
    if kind == panel:
      gradient(rect(r.x, r.y + 1, r.width, r.height - 2), s.start, s.finish, true)
      overlayRect(rect(r.x, r.y, r.width, 1), s.highlight)
      overlayRect(rect(r.x, r.y + r.height - 1, r.width, 1), s.shadow)
      return
    let inset = kind in {pressedButton, selected}
    let high = if inset: s.shadow else: s.highlight
    let low = if inset: s.highlight else: s.shadow
    var box = r
    for step in 0..1:
      let hi = if step == 0: high else: lerp(high, s.start, 0.52)
      let lo = if step == 0: low else: lerp(low, s.finish, 0.42)
      overlayRect(rect(box.x, box.y, box.width - 1, 1), hi)
      overlayRect(rect(box.x, box.y + 1, 1, box.height - 2), hi)
      overlayRect(rect(box.x + box.width - 1, box.y, 1, box.height - 1), lo)
      overlayRect(rect(box.x, box.y + box.height - 1, box.width, 1), lo)
      box = rect(box.x + 1, box.y + 1, box.width - 2, box.height - 2)
    gradient(box, s.start, s.finish, kind in {selected, attention, bindingMode})

  proc paintChrome(cmd: RenderCommand) =
    for kind in Chrome:
      if cmd.customData == token(kind):
        paint(cmd, kind)
        return

proc installChrome*() =
  when withSdl:
    for kind in Chrome:
      registerCommandPainter(token(kind), paintChrome)

func withOpacity*(color: Color; opacity: float32): Color =
  rgb(color.r, color.g, color.b, color.a * opacity)

proc updateChrome*(bg, face, accent, accent2, urgent: Color; light: bool;
                   opacity = 1'f32) =
  let white = rgb(255, 255, 255)
  let black = rgb(0, 0, 0)
  let edgeLight = lerp(face, white, if light: 0.86 else: 0.42)
  let edgeDark = lerp(face, black, if light: 0.63 else: 0.83)
  let screen = lerp(bg, Color(r: accent.r, g: accent.g, b: accent.b, a: bg.a),
                    if light: 0.13 else: 0.24)
  let colors = [
    (bg, screen),
    (lerp(face, white, 0.13), lerp(face, black, 0.14)),
    (lerp(face, white, 0.25), face),
    (lerp(face, black, 0.19), face),
    (accent, lerp(accent, if light: black else: white, 0.30)),
    (urgent, lerp(urgent, if light: black else: white, 0.22)),
    (accent2, lerp(accent2, if light: black else: white, 0.30))]
  for kind in Chrome:
    let (start, finish) = colors[ord(kind)]
    let alpha = if terminalMode(): 1'f32 else: opacity
    let next = Surface(start: withOpacity(start, alpha), finish: withOpacity(finish, alpha),
      highlight: withOpacity(edgeLight, alpha), shadow: withOpacity(edgeDark, alpha))
    if surfaces[kind] != next:
      surfaces[kind] = next
      inc revisions[kind]

proc chrome*(decl: sink ElementDeclaration; kind: Chrome): ElementDeclaration =
  when withSdl:
    if not terminalMode():
      return decl.custom(token(kind), revisions[kind])
  decl.bg(surfaces[kind].start)

proc buttonChrome*(id: ElementId): Chrome =
  if pressing(id): pressedButton
  elif pointerOver(id): hovered
  else: raised

func pressPadding*(down: bool): Padding =
  if down: Padding(top: 2, left: 2) else: Padding()


func luminance(c: Color): float32 =
  func linear(channel: float32): float32 =
    let s = channel / 255
    if s <= 0.04045: s / 12.92 else: pow((s + 0.055) / 1.055, 2.4)
  0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)

func contrastingInk*(face, preferred: Color): Color =
  let bg = luminance(face)
  let fg = luminance(preferred)
  if (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05) >= 4.5: preferred
  elif bg < 0.179: rgb(255, 255, 255)
  else: rgb(0, 0, 0)

widget focusable desktopButton(label: string, width = fit(), height = fit(),
                                 fontSize = 0'u16) -> bool:
  emits Pressed
  if terminalMode():
    return button(id, label, width = width, height = height, fontSize = fontSize,
      tabIndex = tabIndex)
  let t = activeTheme
  let down = pressing(id)
  let ink = contrastingInk(t.palette.buttonBg, t.palette.textColor)
  var padding = squeeze(padAll(t.metrics.padButton), down)
  if down:
    inc padding.left
    dec padding.right
  var decl = col(width = width, height = height, alignX = centerX,
    alignY = centerY, padding = padding).chrome(buttonChrome(id))
  if focused(id):
    decl.border = BorderConfig(color: ink,
      width: BorderWidth(top: 1, right: 1, bottom: 1, left: 1))
  item(id, decl):
    text(label, if fontSize > 0: fontSize else: t.text.button, ink)
  result = clickedIn(id) or keyActivated(id)
  if result:
    emit Pressed(id: id)
