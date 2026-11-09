import ellipse_ui

type ButtonHit* = enum
  bhNone, bhToggle, bhExpand

type SliderChange* = object
  value*: int
  committed*: bool

var held: seq[uint32]

const sliderTrackMax = 420.0  ## Slider tracks stop here: inside the horizontal
                              ## scroll region, grow() clamps to content width,
                              ## so an unbounded track ratchets wider each time
                              ## a panel card appears. The widget row is capped
                              ## at this + 8px padding so the outer `audio` col
                              ## cannot inflate either.

## --- the disclosure icon -------------------------------------------------
##
# The expand/collapse mark, chiselled from rectangles: a `+` when closed,
# the vertical stem dropped to a `−` when open. The toolkit caret is a "v"/
# "^" glyph in the UI font; the renderer only promises rectangles and text,
# so an icon built from bars is the honest upgrade - crisp at any size,
# theme-coloured, and no rotation primitives needed.

proc chisel(width, height: float32, ink: Color) =
  openElement()
  configureOpenElement(row(width = fixedPx(width), height = fixedPx(height))
    .bg(ink))
  closeElement()

proc disclosure(open: bool, ink: Color) =
  let t = activeTheme
  let side = 14.0
  let th = max(float32(t.metrics.borderRaised), 2.0)
  let arm = (side - th) / 2.0
  container(col(width = fixedPx(side), height = fixedPx(side))):
    container(row(width = grow(), height = fixedPx(arm), alignX = centerX)):
      if not open: chisel(th, arm, ink)
    chisel(side, th, ink)
    container(row(width = grow(), height = fixedPx(arm), alignX = centerX)):
      if not open: chisel(th, arm, ink)

widget focusable quickButton(title: string, subtitle: string, active: bool,
                             open = false, arrow = true, width = fit()) -> ButtonHit:
  let t = activeTheme
  let over = pointerOver(id)
  let press = pressing(id)
  let arrowId = localId("quick.arrow", id.id)
  let onArrow = arrow and clickedIn(arrowId)
  let hit = clickedIn(id) or keyActivated(id)
  let fg = if active: t.palette.onAccent else: t.palette.textColor
  item(id, row(width = width, height = fixedPx(52), gap = 8,
      alignY = centerY, padding = squeeze(padAll(10), press))
      .bg(if active: shade(over, press, t.palette.accent, t.palette.selectedBg)
          else: shade(over, press))
      .corner(t.radii.button)
      .focusRing(id)):
    container(col(width = grow(), gap = 2, alignY = centerY)):
      textElement(keepLine(title), TextConfig(fontSize: t.text.control,
        color: fg))
      textElement(keepLine(subtitle), TextConfig(fontSize: t.text.caption,
        color: if active: t.palette.onAccent else: t.palette.dimColor))
    if arrow:
      item(arrowId, row(width = fixedPx(26), height = fixedPx(26),
          alignX = centerX, alignY = centerY)
          .bg(if pressing(arrowId): t.palette.buttonPressBg
              elif pointerOver(arrowId): t.palette.buttonHoverBg
              else: Color())
          .corner(t.radii.inner)):
        disclosure(open,
          if active: t.palette.onAccent else: t.palette.labelColor)
  result = if onArrow: bhExpand elif hit: bhToggle else: bhNone

widget slider(id: ElementId, value: int, dimmed = false) -> SliderChange:
  let t = activeTheme
  let trackId = localId("slider.track", id.id)
  let fillId = localId("slider.fill", id.id)
  # The track box from last frame is finite now that the track is capped, so
  # feeding it into the fill's fixed px width can no longer compound through
  # the scroll container's content clamp and ratchet the track wider.
  let box = elementData(trackId).box
  var v = value
  if box.width > 1.0 and pressing(id):
    let px = currentContext().pointerData().position.x
    let frac = min(max((px - box.x) / box.width, 0.0), 1.0)
    v = int(frac * 100.0 + 0.5)
    if id.id notin held:
      held.add(id.id)
  elif id.id in held:
    var rest: seq[uint32]
    for h in held:
      if h != id.id: rest.add h
    held = rest
    result.committed = true
  result.value = v
  openElement(id, row(width = grow(min = 0.0, max = sliderTrackMax + 8.0),
      height = fixedPx(t.metrics.controlHeight),
      alignY = centerY, padding = padAll(4)))
  openElement(trackId, row(width = grow(min = 160.0, max = sliderTrackMax),
      height = fixedPx(8), alignY = centerY)
      .bg(t.palette.fieldBg).corner(t.radii.field)
      .border(t.metrics.borderHairline, t.palette.panelBorder))
  openElement(fillId, col(width = fixedPx(box.width * float32(v) / 100.0),
      height = fixedPx(8))
      .bg(if dimmed: t.palette.dimColor else: t.palette.accent).corner(t.radii.inner))
  closeElement()
  closeElement()
  closeElement()
