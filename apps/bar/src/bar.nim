## bar - the swaybar replacement, in ellipse_ui.
##
## One process per output (`--output NAME`, launched by
## `_config/sway/scripts/bar.sh`), each a full-width top layer surface 20px
## thick with an exclusive zone - exactly what swaybar reserved, and what
## maximised windows stop at. Everything the old setup spread over three
## moving parts (swaybar + its gaps + apps/tray strip + GTK barbuttons)
## lives inside this one surface:
##
##   [left buttons] [workspace pills] [binding-mode pill]  ...  [status
##   blocks] [tray icons] [right buttons]
##
##  * pills and the mode pill read sway's IPC (GET_TREE + a workspace/mode
##    subscription); clicking runs `workspace`, the wheel over them cycles
##    with wrap, middle-click anywhere does back_and_forth - the old
##    bar.conf mouse shortcuts, kept.
##  * the status line is the SAME `statusbar` binary swaybar drove (the one
##    in _config/sway/statusbar): spawned as a child, i3bar JSON parsed,
##    pango markup drawn as styled runs, clicks forwarded as swaybar-shaped
##    events, so clicks.nim's media/volume/date handlers behave verbatim.
##  * the tray host (apps/tray's tinydbus SNI modules) runs in the
##    `--tray` process; icons paint through the kit's overlay pass and
##    dbusmenu popups spawn as `--menu-child` layer surfaces, the same
##    dialog-is-its-own-process pattern the strip used.
##  * buttons come from statusbar/buttons.toml, hot-reloaded like
##    barbuttons reloaded it.
##
## Colours mirror bar.conf's `colors` block, read from the same files sway
## does: appearance.conf seeds the defaults and the wallust include
## overrides them, re-parsed whenever the wallpaper-driven theme changes.
##
## Usage: bar --output DP-1 [--tray]     one output's bar
##        bar --menu-child SVC PATH [UNIQUE] [--out NAME]   menu dialog
import std/[os, strutils, sets]
import tinydbus
import ellipse_ui
import ellipse_ui/keys
import ellipse/platform/fdwatch
import ellipse/platform/process
import tray/theme                 # gothic palette, for the menu child only
import tray/[dbusd, icons, sni, menu]

import bar/[buttons, ipc, palette, statusline]

const
  barH = 20           ## swaybar's `height` (bar.conf)
  pillMinW = 42       ## swaybar's `workspace_min_width`
  pillPad = 5         ## swaybar's workspace-button horizontal padding
  statusPad = 8       ## swaybar's `status_padding` (gap between blocks)
  edgePad = 16        ## swaybar's `status_edge_padding`... the right edge
                      ## is the button block there, so this pad sits left
                      ## of it, after the tray icons
  slotW = 22          ## one tray icon cell across (apps/tray's sizing)
  slotH = 16          ## icon glyph box inside the cell
  menuRowH = 26
  menuW = 260
  fontPx = 15         ## pango 11pt at 96 dpi in the kit's 72-dpi px units
  boldPx = 15

type
  Bar = ref object
    output*: string
    trayHost: bool
    ipc: Ipc
    ipcWatch: int32
    sl: StatusLine
    # tray (the SNI host)
    bus: Bus
    host: sni.Host
    openItem: TrayItem
    child: ChildProcess
    childRunning: bool
    lastMiddle: bool
    lastRight: bool
    # buttons.toml live reload
    btnText: string
    cfg: buttons.ButtonsCfg
    # palette live reload
    pal: palette.Palette
    # menu-child side (the dialog process reuses the record)
    menuSvc, menuPath, menuUnique: string
    entries: seq[menu.MenuEntry]
    fetching: bool
    reqH: int32

var br {.threadvar.}: Bar
var firedProcs {.threadvar.}: seq[ChildProcess]

# --- theme colour shortcuts ----------------------------------------------------

func c(p: palette.Palette, n: string, def: Color): Color = p.get(n, def)

# --- sway commands ---------------------------------------------------------------

proc gotoWorkspace(b: Bar; name: string) =
  b.ipc.runCommand("workspace \"" & name & "\"")

proc cycleWorkspace(b: Bar; dir: int) =
  ## Wheel over the pills: next/previous, wrapping past first/last like
  ## bar.conf's `wrap_scroll yes`.
  var shown: seq[Worksp] = @[]
  for w in b.ipc.workspaces:
    if w.output == b.output or w.output.len == 0: shown.add w
  if shown.len == 0: return
  var idx = -1
  for i, w in shown:
    if w.focused: idx = i
  let next =
    if idx < 0: (if dir > 0: 0 else: shown.len - 1)
    else: (idx + dir + shown.len) mod shown.len
  b.gotoWorkspace(shown[next].name)

# --- tray: activate / open the dbusmenu child -----------------------------------

proc closeMenu(b: Bar) =
  b.openItem = nil
  if b.childRunning:
    b.child.kill()
    b.child.close()
    b.childRunning = false
  requestFrame()

proc openMenuFor(b: Bar; item: TrayItem) =
  b.closeMenu()
  b.openItem = item
  var args = @[getAppFilename(), "--menu-child", item.service, item.menu]
  if item.uniqueName.len > 0: args.add item.uniqueName
  if b.output.len > 0: args.add @["--out", b.output]
  b.child = spawnProcess(args)
  b.childRunning = b.child.running
  if not b.childRunning:
    echo "bar: could not start the menu child"
    b.openItem = nil
  requestFrame()

proc activateOrMenu(b: Bar; item: TrayItem) =
  if b.openItem == item:
    b.closeMenu()
    return
  if item.isMenu:
    b.openMenuFor(item)
    return
  var m = methodCall(item.service, item.path,
                     "org.kde.StatusNotifierItem", "Activate")
  var bb = initBodyBuilder()
  bb.add 0'i32
  bb.add 0'i32
  m.setBody(bb)
  let want = item
  proc done(bus: Bus; reply: Message) =
    if reply.kind == Error and "UnknownMethod" in reply.errorName:
      br.openMenuFor(want)
    else:
      br.closeMenu()
  b.bus.request(m, done)

# --- buttons: live reload + detached commands ------------------------------------

proc buttonsConfig(b: Bar) =
  var text = ""
  try: text = readFile(buttons.buttonsFile()) except CatchableError: discard
  if text == b.btnText: return
  b.btnText = text
  b.cfg = buttons.parse(text)

proc runButton(b: Bar; btn: BarButton) =
  if btn.command.len == 0: return
  # same detached-sh trick the status blocks use: the quick `sh` wrapper
  # exits, the real app lives on without us
  var p = spawnProcess(@["sh", "-c", btn.command & " >/dev/null 2>&1 & disown"])
  if p.running: firedProcs.add p

proc tickFired() =
  var i = 0
  while i < firedProcs.len:
    if firedProcs[i].poll():
      firedProcs[i].close()
      firedProcs.del(i)
    else: inc i

# --- input: wheel + middle click --------------------------------------------------

proc handleInput(b: Bar) =
  # middle-click anywhere on the bar: back_and_forth (bar.conf's button2)
  let mid = mouseMiddleDown()
  if mid and not b.lastMiddle:
    b.ipc.runCommand("workspace back_and_forth")
  b.lastMiddle = mid

  let wheel = wheelDelta()
  if int(wheel.y) == 0: return
  let button = if wheel.y > 0: 4 else: 5
  # wheel over a status block belongs to that block (volume, media)...
  for i, blk in b.sl.blocks:
    let bid = elementId("block." & $i & "." & blk.name)
    if pointerOver(bid):
      let box = elementData(bid).box
      let (px, py) = pointerPosition()
      b.sl.sendClick(blk, max(0, int(px - box.x)), max(0, int(py - box.y)),
                     button)
      return
  # ...otherwise, over the pills, it cycles workspaces (wrap_scroll)
  if pointerOver(elementId("pills")):
    b.cycleWorkspace(if wheel.y > 0: -1 else: 1)

proc blockClick(b: Bar; blk: Block; i: int) =
  let bid = elementId("block." & $i & "." & blk.name)
  let box = elementData(bid).box
  let (px, py) = pointerPosition()
  let x = max(0, int(px - box.x))
  let y = max(0, int(py - box.y))
  if clickedIn(bid):
    b.sl.sendClick(blk, x, y, 1)
  # right-click: statusbar's handlers ignore it today; forward anyway so
  # future ones get it.
  if pointerOver(bid) and mouseRightDown() and not b.lastRight:
    b.sl.sendClick(blk, x, y, 3)
  b.lastRight = mouseRightDown()

# --- the main view ----------------------------------------------------------------

proc pillColor(p: palette.Palette; w: Worksp): (Color, Color) =
  ## (background, ink) for one workspace pill, bar.conf's colors block.
  if w.focused: (c(p, "accent", rgb(137, 180, 250)),
                 c(p, "bar_flat", rgb(0, 0, 0)))
  elif w.urgent: (c(p, "urgent", rgb(243, 139, 168)),
                  c(p, "bar_flat", rgb(0, 0, 0)))
  elif w.visible or (w.focused and w.output == ""):
    (c(p, "surface", rgb(32, 36, 46)), c(p, "text", rgb(230, 234, 242)))
  else:
    # inactive pills blend into the translucent bar, like swaybar's
    (Color(), c(p, "muted", rgb(154, 164, 178)))

proc view() =
  let b = br
  tickIconJobs()
  tickFired()
  b.buttonsConfig()
  b.pal = palette.refresh()
  let p = b.pal
  let barBg = c(p, "bar_bg", rgb(0, 0, 0, 217))

  if b.ipc.poll():
    discard
  if b.sl.feed(): discard
  b.sl.restartIfNeeded()
  b.handleInput()

  # tray child exited on its own (chosen / dismissed): clear the open mark
  if b.childRunning and b.openItem != nil and b.child.poll():
    b.child.close()
    b.childRunning = false
    b.openItem = nil

  # keep the 1s heartbeat (clock, buttons.toml poll) and a faster one while
  # icon jobs decode
  requestFrameIn(200_000_000'i64)

  var items: seq[TrayItem] = @[]
  if b.trayHost and b.host != nil: items = b.host.snapshot

  var shown: seq[Worksp] = @[]
  for w in b.ipc.workspaces:
    if w.output == b.output or w.output.len == 0 or w.urgent: shown.add w

  # --- width budget, swaybar's overflow rule: the status group is pinned
  #     to the right edge and gets cut from its LEFT when the output is
  #     narrow (the portrait panel). clay can't clip on the left, so we
  #     drop whole blocks, oldest first, until the row fits.
  let surfW = windowPixelSize().width
  var nLeft, nRight = 0
  for btn in b.cfg.items:
    if btn.side == "left": inc nLeft else: inc nRight
  var cost = float32(nLeft + nRight) * b.cfg.buttonWidth.float32
  cost += float32(edgePad)
  var pillCost = 0'f32
  for w in shown:
    pillCost += max(pillMinW.float32, measureText(w.name,
        TextConfig(fontSize: fontPx.uint16)).width + 2 * pillPad.float32)
  cost += pillCost
  if b.ipc.modeName != "default" and b.ipc.modeName.len > 0:
    cost += measureText(b.ipc.modeName, TextConfig(fontSize: fontPx.uint16)).width
  if items.len > 0:
    cost += 4'f32 + items.len.float32 * slotW.float32 +
      float32(items.len - 1) * 2'f32          # padding + gaps of the tray row
  var pre: seq[(int, Block, seq[Run], float32)]
  var statusCost = 0'f32
  for i, blk in b.sl.blocks:
    let runs = statusline.parseRuns(statusline.nerdify(blk.fullText),
                                     c(p, "text", rgb(230, 234, 242)))
    var total = 0'f32
    for r in runs:
      total += measureText(r.text, TextConfig(fontSize: fontPx.uint16,
        fontId: if r.bold: MonoFont else: 0'u16)).width
    let cellW = max(blk.minWidth.float32, total)
    statusCost += cellW
    if i > 0: statusCost += 1 + 2 * statusPad   # separator + its two gaps
    pre.add (i, blk, runs, cellW)
  var avail = surfW - cost - 2'f32
  while pre.len > 0 and statusCost > avail:
    statusCost -= pre[0][3]
    if pre.len > 1: statusCost -= 1 + 2 * statusPad
    pre.delete(0)

  # layout rows: [left buttons][pills][mode] ... [status][icons][right btns]
  clay "bar", row(width = grow(), height = fixedPx(barH), gap = 0,
      padding = padAll(0))
      .bg(barBg):

    # --- left buttons ---
    for i, btn in b.cfg.items:
      if btn.side != "left": continue
      let bid = elementId("lbtn." & $i)
      let over = pointerOver(bid)
      openElement(bid, row(width = fixedPx(b.cfg.buttonWidth.float32), height = grow(),
          alignX = centerX, alignY = centerY)
          .bg(if over: b.cfg.hoverBackground else: Color()))
      if btn.glyph.len > 0:
        textElement(btn.glyph, TextConfig(fontSize: b.cfg.fontSize.toPx.uint16,
          color: if over: b.cfg.hoverForeground else: b.cfg.foreground))
      closeElement()
      if clickedIn(bid): b.runButton(btn)

    # --- workspace pills ---
    clay "pills", row(width = fit(), height = grow(), gap = 0,
        alignY = centerY):
      for w in shown:
        let wid = elementId("ws." & w.name)
        let (bg, ink) = pillColor(p, w)
        let tw = measureText(w.name, TextConfig(fontSize: fontPx.uint16)).width
        let cw = max(pillMinW.float32, tw + 2 * pillPad.float32)
        openElement(wid, row(width = fixedPx(cw), height = grow(),
            alignX = centerX, alignY = centerY)
            .bg(bg))
        textElement(w.name, TextConfig(fontSize: fontPx.uint16, color: ink))
        closeElement()
        if clickedIn(wid): b.gotoWorkspace(w.name)

    # --- binding-mode indicator (the "resize" pill) ---
    if b.ipc.modeName != "default" and b.ipc.modeName.len > 0:
      clay "mode", row(width = fit(), height = grow(), alignX = centerX,
          alignY = centerY)
          .bg(c(p, "accent2", rgb(116, 199, 236))):
        textElement(b.ipc.modeName, TextConfig(fontSize: fontPx.uint16,
          color: c(p, "bar_flat", rgb(0, 0, 0))))

    # --- push the status group to the right edge ---
    openElement(elementId("space"), row(width = grow(), height = grow()))
    closeElement()

    # --- status blocks, in swaybar's stream order (suffix that fits) ---
    clay "status", row(width = fit(), height = grow(), gap = statusPad,
        alignY = centerY):
      for pos, entry in pre:
        let (i, blk, runs, cellW) = entry
        if pos > 0:
          openElement(elementId("sep." & $i), col(width = fixedPx(1),
              height = fixedPx(barH - 6))
              .bg(c(p, "inactive", rgb(69, 71, 90))))
          closeElement()
        var total = 0'f32
        for r in runs:
          total += measureText(r.text, TextConfig(fontSize: fontPx.uint16,
            fontId: if r.bold: MonoFont else: 0'u16)).width
        let lead =
          case blk.align
          of "left": 0'f32
          of "right": cellW - total
          else: (cellW - total) / 2
        let bid = elementId("block." & $i & "." & blk.name)
        openElement(bid, row(width = fixedPx(cellW), height = grow(),
            gap = 0, padding = padAll(0), alignY = centerY))
        if lead > 1:
          openElement(elementId("lead." & $i),
            row(width = fixedPx(lead), height = fixedPx(1)))
          closeElement()
        for j, r in runs:
          textElement(r.text, TextConfig(fontSize: fontPx.uint16, color: r.color,
            fontId: if r.bold: MonoFont else: 0'u16))
        closeElement()
        b.blockClick(blk, i)

    # --- swaybar's status_edge_padding: 16px of clear bar between the
    #     status group and whatever owns the right edge (icons + buttons)
    openElement(elementId("edge.pad"), row(width = fixedPx(edgePad),
        height = fixedPx(1)))
    closeElement()

    # --- tray icons (the SNI host lives in one process; other outputs'
    #     bars simply show nothing here, like swaybar with tray_output none)
    if items.len > 0:
      clay "tray", row(width = fit(), height = grow(), gap = 2,
          padding = padAll(2), alignY = centerY):
        for it in items:
          let sid = elementId("slot." & it.itemKey)
          let over = pointerOver(sid)
          openElement(sid, row(width = fixedPx(slotW), height = grow(),
              alignX = centerX, alignY = centerY)
              .bg(if over: shade(true, pressing(sid)) else: Color()))
          closeElement()
          if clickedIn(sid):
            b.activateOrMenu(it)

    # --- right buttons ---
    for i, btn in b.cfg.items:
      if btn.side != "right": continue
      let bid = elementId("rbtn." & $i)
      let over = pointerOver(bid)
      openElement(bid, row(width = fixedPx(b.cfg.buttonWidth.float32), height = grow(),
          alignX = centerX, alignY = centerY)
          .bg(if over: b.cfg.hoverBackground else: Color()))
      if btn.glyph.len > 0:
        textElement(btn.glyph, TextConfig(fontSize: b.cfg.fontSize.toPx.uint16,
          color: if over: b.cfg.hoverForeground else: b.cfg.foreground))
      closeElement()
      if clickedIn(bid): b.runButton(btn)

# --- the overlay pass: icon textures over the clay picture -----------------------

proc overlay() =
  let b = br
  # button icons first (they are plain files; glyph buttons draw in clay)
  for i, btn in b.cfg.items:
    if btn.icon.len == 0: continue
    let bid = elementId((if btn.side == "left": "lbtn." else: "rbtn.") & $i)
    let box = elementData(bid).box
    if box.width <= 0: continue
    let icon = icons.loadIconFile(btn.icon)
    if icon != nil:
      let cell = float32(barH - 4)
      let sc = min(min(float32(b.cfg.iconHeight) / float32(icon.w),
                       float32(b.cfg.iconHeight) / float32(icon.h)),
                   cell / max(1'f32, max(float32(icon.w), float32(icon.h))))
      let w = float32(icon.w) * sc
      let h = float32(icon.h) * sc
      overlayIcon(icon, rect(box.x + box.width / 2 - w / 2,
                             box.y + box.height / 2 - h / 2, w, h))
  if not (b.trayHost and b.host != nil): return
  let p = b.pal
  for it in b.host.snapshot:
    let sid = elementId("slot." & it.itemKey)
    let box = elementData(sid).box
    if box.width <= 0: continue   # first frame before clay has measured
    let cx = box.x + box.width / 2
    let cy = box.y + box.height / 2
    let icon = icons.iconFor(it)
    if icon != nil:
      let sc = min(float32(slotH) / float32(icon.w),
                   float32(slotH) / float32(icon.h))
      let w = float32(icon.w) * sc
      let h = float32(icon.h) * sc
      overlayIcon(icon, rect(cx - w / 2, cy - h / 2, w, h))
    else:
      # letter tile, like the tray strip: no PNG decoder in the kit (yet)
      let r = rect(cx - slotH / 2, cy - slotH / 2, slotH.float32, slotH.float32)
      overlayRect(r, c(p, "surface", rgb(32, 36, 46)))
      overlayFrame(r, 1, c(p, "inactive", rgb(69, 71, 90)))
      let letter = (if it.id.len > 0: $it.id[0] else: "?").toUpperAscii
      let lw = measureText(letter, TextConfig(fontSize: 12)).width
      overlayText(letter, cx - lw / 2, cy - 7, 12,
                  c(p, "text", rgb(230, 234, 242)))

# --- setup ------------------------------------------------------------------------

proc ipcWake() {.gcsafe.} =
  if br != nil and br.ipc != nil:
    discard br.ipc.poll()
    requestFrame()

proc dbusWake() {.gcsafe.} =
  br.bus.pump()
  requestFrame()

proc setup() =
  let b = br
  discard b.ipc.poll()            # first connect + subscribe + tree
  b.sl = statusline.newStatusLine()
  setOverlay(overlay)
  if b.trayHost:
    b.bus = dbusd.newBus()
    b.host = sni.newHost(b.bus)
    b.host.onItemsChanged =
      proc (h: sni.Host) =
        var alive: HashSet[string]
        for it in h.snapshot: alive.incl(it.itemKey)
        icons.pruneIcons(alive)
        requestFrame()
    discard fdwatch.watchFd(b.bus.fd(), dbusWake)

proc rebindIpcWatch(b: Bar) =
  ## The IPC socket's fd changes on every (re)connect; keep the watch
  ## pointed at the live one.
  let f = b.ipc.fd()
  if f == b.ipcWatch: return
  if b.ipcWatch >= 0: fdwatch.unwatchFd(b.ipcWatch)
  if f >= 0: discard fdwatch.watchFd(f, ipcWake)
  b.ipcWatch = f

proc before() =
  let b = br
  rebindIpcWatch(b)

# --- the menu child (dialog-is-its-own-process, apps/tray's pattern) -------------

func prefixOf(e: menu.MenuEntry): string =
  if e.toggleType == "checkmark":
    (if e.toggleState == "on": "✓ " elif e.toggleState == "mixed": "– " else: "  ")
  elif e.toggleType == "radio":
    (if e.toggleState == "on": "● " else: "○ ")
  elif e.depth > 0: "  ".repeat(e.depth) else: ""

var mch {.threadvar.}: Bar   # reuse the record for the child's few fields

proc menuChildSetup() =
  proc got(entries: seq[menu.MenuEntry]) =
    mch.fetching = false
    mch.entries = entries
    requestFrame()
  mch.fetching = true
  menu.fetchMenu(mch.bus, mch.menuSvc, mch.menuPath, got)
  let bus = mch.bus
  bus.onSignal =
    proc (b: Bus; m: Message) =
      if menu.isOurSignal(m, mch.menuSvc, mch.menuUnique, mch.menuPath) and
          m.member in ["LayoutChanged", "ItemsPropertiesChanged"] and
          not mch.fetching:
        mch.fetching = true
        proc got2(entries: seq[menu.MenuEntry]) =
          mch.fetching = false
          mch.entries = entries
          requestFrame()
        menu.fetchMenu(b, mch.menuSvc, mch.menuPath, got2)

proc menuChildView() =
  setTheme(gothicTheme(true))
  let t = activeTheme
  if pressed("Escape"):
    platform.quit()
  var rows = 0
  for e in mch.entries:
    if e.visible: inc rows
  clay "menuwin", col(width = fixedPx(menuW), height = grow(),
      gap = 0, padding = padAll(2))
      .bg(t.palette.panelBg)
      .border(t.metrics.borderHairline, t.palette.panelBorder):
    if mch.fetching and rows == 0:
      clay "menu.wait", row(width = grow(), height = fixedPx(menuRowH),
          padding = padAll(6)):
        textElement("loading\u2026", TextConfig(fontSize: t.text.menu,
            color: t.palette.dimColor))
    for e in mch.entries:
      if not e.visible: continue
      let rid = elementId("mrow." & $e.id)
      let hot = pointerOver(rid) and e.enabled
      openElement(rid, row(width = grow(), height = fixedPx(menuRowH),
          gap = 6, padding = padAll(7), alignY = centerY)
          .bg(if hot: shade(true, pressing(rid), t.palette.selectedBg)
              else: Color()))
      if e.label.len == 0:
        openElement()
        configureOpenElement(col(width = grow(), height = fixedPx(1))
            .bg(t.palette.panelBorder))
        closeElement()
      else:
        textElement(prefixOf(e) & e.label, TextConfig(
          fontSize: t.text.menu,
          color: if e.enabled: t.palette.textColor else: t.palette.dimColor))
      closeElement()
      if clickedIn(rid) and e.enabled and not mch.fetching:
        menu.activateItem(mch.bus, mch.menuSvc, mch.menuPath, e)
        platform.quit()
  let h = (4 + max(rows, if mch.fetching: 1 else: 0) * menuRowH).int32
  if h != mch.reqH and h > 0:
    if requestLayerSize(menuW.int32, h):
      mch.reqH = h

proc menuChild(service, path, unique, output: string) =
  mch = Bar()
  mch.menuSvc = service
  mch.menuPath = path
  mch.menuUnique = unique
  mch.reqH = -1
  mch.bus = dbusd.newBus()
  let bus = mch.bus
  proc wake() {.gcsafe.} =
    bus.pump()
    requestFrame()
  if not fdwatch.watchFd(bus.fd(), wake):
    echo "bar menu: failed to watch the dbus socket"
    system.quit(1)
  var mr = 0'i32
  try: mr = buttons.parse(readFile(buttons.buttonsFile())).rightWidth.int32
  except CatchableError: discard
  if mr == 0: mr = 24
  run App(window: WindowConfig(
      title: "tray-menu",
      width: menuW, height: 60,
      resizable: false,
      layer: LayerConfig(
        enabled: true, edge: edgeTop, level: layerOverlay,
        thickness: 60, length: menuW, exclusive: 0,
        anchorEnd: true, marginEnd: mr,
        keyboard: keyboardExclusive, namespace: "alatar-tray-menu",
        output: output)),
    debugMode: false,
    setup: menuChildSetup,
    view: menuChildView)

# --- entry ------------------------------------------------------------------------

proc parseOutputs(args: seq[string]): tuple[outp: string, rest: seq[string]] =
  result.outp = ""
  var i = 0
  while i < args.len:
    if args[i] == "--output" or args[i] == "--out":
      if i + 1 < args.len: result.outp = args[i + 1]; inc i
    else:
      result.rest.add args[i]
    inc i

when isMainModule:
  let all = commandLineParams()
  let (outp, rest) = parseOutputs(all)
  if rest.len >= 3 and rest[0] == "--menu-child":
    let unique = if rest.len >= 4: rest[3] else: ""
    menuChild(rest[1], rest[2], unique, outp)
    quit 0
  br = Bar(output: outp, trayHost: "--tray" in all,
           ipc: ipc.newIpc(), ipcWatch: -1)
  # fonts: the Nerd Font the old swaybar used, at every size; the MonoFont
  # slot doubles as the bold face (the status line's `<b>`)
  fontPath = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
  monoFontPaths = @["/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf"]
  run App(window: WindowConfig(
        title: "bar" & (if outp.len > 0: "@" & outp else: ""),
        width: 1280, height: barH,
        resizable: false,
        layer: LayerConfig(
          enabled: true, edge: edgeTop, level: layerTop,
          thickness: barH.int32, length: 0, exclusive: barH.int32,
          keyboard: keyboardNone, namespace: "alatar-bar",
          output: outp)),
      debugMode: false,
      setup: setup,
      before: before,
      view: view)
