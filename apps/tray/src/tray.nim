## tray - the sway tray with real menus.
##
## A wlr-layer-shell strip docked to the right edge of the top bar, just
## left of the bar-buttons zone: StatusNotifierItem icons fed by the
## tinydbus host (tray/sni.nim) over ellipse's fdwatch. A click that the
## item cannot Activate (ayatana apps expose no Activate at all, and
## swaybar could never show their menus either) spawns THIS binary again
## as `--menu-child`: a second layer-shell surface - the kit's dialog-is-
## its-own-process pattern, anchored under the strip - that owns the
## dbusmenu round trip, renders the gothic panel, and vanishes on Escape
## or on EventReceived. The strip's surface is icon-sized at all times:
## opening a menu must never stretch the bar.
##
## The visuals follow nomicon's gothic theme: the same wallust-driven
## palette, square stone corners and parchment ink (nomicon/theme), the
## same hover/shade behaviour as its quick buttons. Icons paint through
## the renderer's overlay pass (tray textures); everything else is clay.
##
## Usage: tray                    strip (menus spawn as children)
##        tray --menu-child ...    the dialog process (strip spawns it)
##        tray --probe [secs]      console host dump (no window)
##        tray --menu <needle>     console dbusmenu dump (parser bench)
##        tray --light             light parchment theme instead of dark
import std/[os, strutils, sequtils, sets, tables]
import tinydbus
import ellipse_ui
import ellipse_ui/keys
import ellipse/platform/fdwatch
import ellipse/platform/process
import tray/theme

import tray/[dbusd, sni, menu]
import ellipse/platform/platform  # platform.quit(): the loop-exit call

# gcsafe discipline: the ellipse app shell (workspace kit) requires every
# app hook to be GC-safe - tray/theme.nim threadvar-caches the wallust
# palette for exactly that, and the bus/fdwatch closures were already
# checked individually. view() runs per frame inside the gcsafe zone.

const
  slotW = 22            ## one icon cell across
  slotH = 16            ## icon glyph box inside the cell
  stripH = 20           ## matches the swaybar height (bar.conf)
  menuRowH = 26
  menuW = 260
  barInset = 24         ## fallback inset when no buttons.toml is readable
  gap = 2

type
  Tray = ref object
    bus: Bus
    host: sni.Host
    icons: Table[string, Icon]   ## service & path -> texture
    iconSig: Table[string, string]
    openItem: TrayItem      # strip side: which icon owns the child
    child: ChildProcess     # the --menu-child process, when running
    childRunning: bool
    menuSvc*, menuPath*, menuUnique*: string  # child-side targets
    entries: seq[menu.MenuEntry]   # child side only: the menu model
    fetching: bool                  # child side only
    reqW, reqH: int32
    reqMR: int32         # last right margin pushed to the compositor
    dark: bool
    dirty: bool

var tr {.threadvar.}: Tray
  # threadvar: the GC-safe fd-callback contract permits thread-local but
  # not shared mutable globals (single-threaded use still - the kit's own
  # pacing/fdwatch do the same).
proc initTrayDefaults() =
  tr = Tray(bus: nil, host: nil,
            icons: initTable[string, Icon](),
            iconSig: initTable[string, string](),
            openItem: nil, entries: @[], fetching: false,
            reqW: -1, reqH: -1, reqMR: -1, dark: true, dirty: false)
initTrayDefaults()

proc freeIconFor(k: string) =
  var found: Icon
  if tr.icons.pop(k, found) and found != nil:
    found.freeIcon
    tr.iconSig.del(k)

# --- theme-icon files: identify + raw decode via the kit's child processes ----------
#
# Steam and Spotify export their tray icons as theme *files* (IconName +
# IconThemePath), not ARGB pixmaps, and Nim 2.4 dropped the std PNG codec.
# ImageMagick is already a declared desktop package: two frame-polled
# children per icon - `magick identify` for the geometry, `magick ... bgra:-`
# for raw BGRA bytes (which is native-order ARGB32 on little-endian).
# Everything is cached by path+mtime and resolved asynchronously, so the
# letter tile shows for a frame or two and the real logo takes over.

type
  IconStage = enum jSize, jPixels
  IconJob = object
    p: ChildProcess
    stage: IconStage
    key, sig, path: string
    w, h: int32

var iconJobs {.threadvar.}: seq[IconJob]
var btnText {.threadvar.}: string

const
  iconMax = 48                      ## downscale target, px
  iconSizeDirs = ["48x48", "32x32", "24x24", "22x22", "16x16", "scalable"]
  iconCatDirs = ["apps", "status", "panel", "actions", "devices"]
  iconThemeDirs = ["hicolor", "Adwaita"]

proc findIconFile(name, themePath: string): string =
  if name.len == 0: return ""
  var dirs: seq[string] = @[]
  if themePath.len > 0: dirs.add themePath
  let home = getHomeDir()
  for th in iconThemeDirs:
    dirs.add home / ".local/share/icons" / th
    dirs.add "/usr/share/icons/" & th
  for d in dirs:
    for ext in [".png", ".svg"]:
      let direct = d / (name & ext)
      if fileExists(direct): return direct
  for d in dirs:
    for sz in iconSizeDirs:
      for cat in iconCatDirs:
        for ext in [".png", ".svg"]:
          let cand = d / sz / cat / (name & ext)
          if fileExists(cand): return cand
  ""

proc enqueueIcon(key, sig, path: string) =
  for j in iconJobs:
    if j.key == key and j.sig == sig: return
  var j = IconJob(stage: jSize, key: key, sig: sig, path: path)
  j.p = spawnProcess(@["magick", "identify", "-format", "%w %h", path])
  iconJobs.add j

proc finishIcon(j: IconJob; bytes: string) =
  let n = int(j.w) * int(j.h)
  if n <= 0 or bytes.len < n * 4: return
  var argb = newSeq[uint32](n)
  for i in 0 ..< n:
    let o = i * 4
    argb[i] = (uint32(bytes[o+3]) shl 24) or (uint32(bytes[o]) shl 16) or
              (uint32(bytes[o+1]) shl 8) or uint32(bytes[o+2])
  # BGRA bytes -> native ARGB32: b,g,r,a -> a<<24 | r<<16 | g<<8 | b
  # (argb[i] built from: a=o+3, b=o, g=o+1, r=o+2)
  let icon = loadIcon(argb, j.w, j.h)
  if icon != nil:
    freeIconFor(j.key)
    tr.icons[j.key] = icon
    tr.iconSig[j.key] = j.sig

proc tickIconJobs() =
  var i = 0
  while i < iconJobs.len:
    var j = iconJobs[i]
    if j.p.poll():
      if j.stage == jSize:
        let dims = j.p.output.strip.split(WhiteSpace)
        if dims.len >= 2 and parseInt(dims[0]) > 0:
          var w = parseInt(dims[0])
          var h = parseInt(dims[1])
          if max(w, h) > iconMax:
            let sc = float64(iconMax) / float64(max(w, h))
            w = max(1, int(float64(w) * sc))
            h = max(1, int(float64(h) * sc))
          j.w = w.int32
          j.h = h.int32
          var scale = ""
          if max(w, h) < iconMax or dims[0].parseInt > iconMax or
              dims[1].parseInt > iconMax:
            scale = $w & "x" & $h
          var args = @["magick", j.path, "-depth", "8"]
          if scale.len > 0: args.add @["-resize", scale]
          args.add @["bgra:-"]
          j.p.close()
          j.p = spawnProcess(args)
          j.stage = jPixels
          iconJobs[i] = j
          continue
        j.p.close()
        iconJobs.del(i)
        continue
      else:
        finishIcon(j, j.p.output)
        j.p.close()
        iconJobs.del(i)
        continue
    iconJobs[i] = j
    inc i

# --- bar-buttons sync: dock clear of whatever the right side holds -------------
#
# scripts/bar-buttons.sh renders statusbar/buttons.toml as 24px button
# surfaces stacked from the screen's right edge, and the email/package-
# manager/terminal buttons live there. The tray's right margin therefore
# cannot be a constant: it parses the same file (button_width + the number
# of side="right" entries) and docks at (n+1) slots, one button-block wide
# flush against the innermost button. Re-read every frame through a
# text cache (the wallust-theme trick), so adding a button in the config
# moves the tray on the spot without a reload.

proc buttonsFile(): string =
  let base = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  base / "sway" / "statusbar" / "buttons.toml"

func parseButtons(text: string): (int32, int) =
  ## (button_width, right-side button count) from the TOML subset it uses.
  var bw = 24'i32
  var nRight = 0
  var side = ""
  var inButton = false
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line.startsWith('#'): continue
    if line == "[[button]]":
      if inButton and side == "right": inc nRight
      inButton = true
      side = ""
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip
    var val = line[eq + 1 ..^ 1].strip
    if val.startsWith('"'):
      let close = val.find('"', 1)
      val = if close >= 0: val[1 ..< close] else: val
    else:
      let hash = val.find('#')
      if hash >= 0: val = val[0 ..< hash].strip
    case key
    of "button_width":
      try: bw = parseInt(val).int32 except ValueError: discard
    of "side":
      if inButton: side = val
    else: discard
  if inButton and side == "right": inc nRight
  (bw, nRight)

proc marginEndDefault(): int32 =
  let (bw, n) = parseButtons(
    try: readFile(buttonsFile()) except CatchableError: "")
  if n == 0 and bw == 24'i32:
    barInset.int32          # no config readable: original one-slot inset
  else:
    n.int32 * bw

# barbuttons owns the swaybar margins and needs our live strip width to
# size the right gap; publish it every frame. The fresh mtime is a
# heartbeat: if the tray dies, barbuttons sees the file go stale and
# shrinks the gap back to the button block alone.
proc publishWidth(w: int32) =
  let path = getEnv("XDG_RUNTIME_DIR", "/tmp") / "alatar-tray.width"
  try: writeFile(path, $w) except CatchableError: discard

# --- icons --------------------------------------------------------------------

func itemKey(it: TrayItem): string = it.service & it.path

func pixmapSig(it: TrayItem): string =
  if it.pixmaps.len == 0: ""
  else:
    let p = it.pixmaps[^1] ## the last size is usually the best one
    $p.width & "x" & $p.height & ":" & $p.argb.len & ":" &
      $p.argb[0] & ":" & $p.argb[^1]

proc cacheSig(it: TrayItem): string =
  ## Identity of the icon's current source: the pixmap bytes, or the
  ## theme file (found on disk, so a repoint by pamac's update/no-update
  ## icon swap busts the cache and reloads).
  if it.pixmaps.len > 0:
    "px:" & it.pixmapSig
  else:
    let f = findIconFile(it.iconName, it.iconThemePath)
    (if f.len > 0: "file:" & f else: "")

proc iconFor(it: TrayItem): Icon =
  let k = it.itemKey
  let sig = it.cacheSig
  if sig.len == 0: return nil         # nothing to show: letter tile
  if tr.icons.hasKey(k):
    if tr.iconSig.getOrDefault(k) == sig:
      return tr.icons[k]
    freeIconFor(k)                    # stale pixmap/file: replace below
  elif tr.iconSig.getOrDefault(k) == sig:
    return nil                        # decode in flight (or failed): tile
  tr.iconSig[k] = sig
  if it.pixmaps.len > 0:
    let p = it.pixmaps[^1]
    let icon = loadIcon(p.argb, p.width, p.height)
    if icon != nil:
      tr.icons[k] = icon
    return nil
  let file = findIconFile(it.iconName, it.iconThemePath)
  if file.len > 0:
    enqueueIcon(k, sig, file)
  nil

# --- icons -------------------------------------------------------

proc pruneIcons(tr: Tray) =
  var alive: HashSet[string]
  for it in tr.host.snapshot: alive.incl(it.itemKey)
  var gone: seq[string] = @[]
  for k in tr.icons.keys:
    if k notin alive: gone.add k
  for k in gone: freeIconFor(k)


# --- menu state ------------------------------------------------------------------

proc closeMenu(tr: Tray) =
  tr.openItem = nil
  if tr.childRunning:
    tr.child.kill()
    tr.child.close()
    tr.childRunning = false
  requestFrame()

# --- child-side menu model --------------------------------------------------

proc refetchMenu(tr: Tray) =
  if tr.fetching or tr.menuSvc.len == 0: return
  tr.fetching = true
  proc got(entries: seq[menu.MenuEntry]) =
    tr.fetching = false
    tr.entries = entries
    requestFrame()
  menu.fetchMenu(tr.bus, tr.menuSvc, tr.menuPath, got)

proc openMenuFor(tr: Tray; item: TrayItem) =
  ## Detach the menu into its own process: a fresh layer-shell surface the
  ## compositor anchors under the strip (see menuChild). Killing the child
  ## (click the icon again, or a different icon) is the whole teardown.
  tr.closeMenu()
  tr.openItem = item
  var args = @[getAppFilename(), "--menu-child", item.service, item.menu]
  if item.uniqueName.len > 0: args.add item.uniqueName
  tr.child = spawnProcess(args)
  tr.childRunning = tr.child.running
  if not tr.childRunning:
    echo "tray: could not start the menu child"
    tr.openItem = nil
  requestFrame()

proc activateOrMenu(tr: Tray; item: TrayItem) =
  # left click on a second time closes the menu that click opened.
  if tr.openItem == item:
    tr.closeMenu()
    return
  if item.isMenu or item.menu.len == 0:
    # ItemIsMenu items are menu-only; items without any menu just get the
    # Activate attempt below (which either raises their window or errors
    # quietly).
    if item.isMenu:
      tr.openMenuFor(item)
      return
  # Items without the method (all ayatana-appindicator trays, Steam
  # included) answer UnknownMethod: that click becomes the menu instead.
  var m = methodCall(item.service, item.path,
                     "org.kde.StatusNotifierItem", "Activate")
  var b = initBodyBuilder()
  b.add 0'i32
  b.add 0'i32
  m.setBody(b)
  let want = item
  proc done(bus: Bus; reply: Message) =
    if reply.kind == Error and "UnknownMethod" in reply.errorName:
      tr.openMenuFor(want)
    else:
      tr.closeMenu()
  tr.bus.request(m, done)

# --- layout (gothic strip + menu panel, nomicon's visual language) ------------------

proc prefixOf(e: menu.MenuEntry): string =
  if e.toggleType == "checkmark":
    (if e.toggleState == "on": "✓ " elif e.toggleState == "mixed": "– " else: "  ")
  elif e.toggleType == "radio":
    (if e.toggleState == "on": "● " else: "○ ")
  elif e.depth > 0: "  ".repeat(e.depth) else: ""

proc syncButtons() =
  var text = ""
  try: text = readFile(buttonsFile()) except CatchableError: discard
  if text == btnText: return
  btnText = text
  let (bw, n) = parseButtons(text)
  let me = n.int32 * bw
  if me != tr.reqMR:
    if remarginLayer(0, me, 0, 0):
      tr.reqMR = me
      # The remargin marks the layer state dirty; SDL's next frame commit
      # carries it. Do NOT nudge requestLayerSize here: on the very first
      # pass reqW/reqH are still the -1 sentinels and set_size(-1) is a
      # wayland protocol error that takes the display connection down.
      requestFrame()

proc view() =
  tickIconJobs()
  syncButtons()
  requestFrameIn(1_000_000_000'i64)  # keep the buttons.toml poll alive
  setTheme(gothicTheme(tr.dark))
  let t = activeTheme
  let items = tr.host.snapshot

  # one pass over the slots decides clicks alongside their visuals

  clay "tray", col(width = grow(), height = grow(),
      padding = padAll(2), gap = gap):
    clay "strip", row(width = fit(), height = fixedPx(stripH - 4),
        gap = gap, alignY = centerY):
      for it in items:
        let sid = elementId("slot." & it.itemKey)
        let over = pointerOver(sid)
        openElement(sid, row(width = fixedPx(slotW), height = grow(),
            alignX = centerX, alignY = centerY)
            .bg(if over: shade(true, pressing(sid)) else: Color()))
        closeElement()
        if clickedIn(sid):
          tr.activateOrMenu(it)
  # the strip surface is icon-sized, always: the menu is a separate
  # layer-shell surface (the dialog child), so nothing here shifts
  var w = (4 + items.len * (slotW + gap)).int32
  publishWidth(w)
  let h = stripH.int32
  if tr.childRunning and tr.openItem != nil and tr.child.poll():
    # the child exited: it chose (or was killed) - drop the open state
    tr.child.close()
    tr.childRunning = false
    tr.openItem = nil
  if w != tr.reqW or h != tr.reqH:
    if requestLayerSize(w, h):
      tr.reqW = w
      tr.reqH = h

# --- the overlay pass: icons on top of the clay picture ---------------------------------

proc overlay() =
  let t = activeTheme
  for it in tr.host.snapshot:
    let sid = elementId("slot." & it.itemKey)
    let box = elementData(sid).box
    if box.width <= 0: continue   # first frame before clay has measured
    let cx = box.x + box.width / 2
    let cy = box.y + box.height / 2
    let icon = iconFor(it)
    if icon != nil:
      let sc = min(float32(slotH) / float32(icon.w),
                   float32(slotH) / float32(icon.h))
      let w = float32(icon.w) * sc
      let h = float32(icon.h) * sc
      overlayIcon(icon, rect(cx - w / 2, cy - h / 2, w, h))
    else:
      # letter tile: the gothic chisel, no PNG decoder in the kit (yet)
      let r = rect(cx - slotH / 2, cy - slotH / 2, slotH.float32, slotH.float32)
      overlayRect(r, t.palette.buttonBg)
      overlayFrame(r, 1, t.palette.panelBorder)
      let letter = (if it.id.len > 0: $it.id[0] else: "?").toUpperAscii
      let lw = measureText(letter, TextConfig(fontSize: 12)).width
      overlayText(letter, cx - lw / 2, cy - 7, 12, t.palette.labelColor)

# --- the dialog child: one menu as its own layer-shell surface ------------------
#
# Started by the strip as `<this binary> --menu-child <service> <menuPath>
# [uniqueName]`. Its own D-Bus connection (a plain client - the watcher
# belongs to the strip), its own window: anchored to the bar's top edge at
# the strip's right margin with `exclusive 0`, which the compositor places
# directly under the reserved bar strip - i.e. dropping from the icon,
# without the strip surface changing size at all. Keyboard-exclusive
# layer: Escape dismisses, and choosing an item reports EventReceived (and
# the toggle event for checkables) before exiting. LayoutChanged /
# ItemsPropertiesChanged for this menu path trigger a live refetch.

proc menuChildSetup() =
  proc got(entries: seq[menu.MenuEntry]) =
    tr.fetching = false
    tr.entries = entries
    requestFrame()
  tr.fetching = true
  menu.fetchMenu(tr.bus, tr.menuSvc, tr.menuPath, got)
  let bus = tr.bus
  bus.onSignal =
    proc (b: Bus; m: Message) =
      if menu.isOurSignal(m, tr.menuSvc, tr.menuUnique, tr.menuPath) and
          m.member in ["LayoutChanged", "ItemsPropertiesChanged"] and
          not tr.fetching:
        tr.fetching = true
        proc got2(entries: seq[menu.MenuEntry]) =
          tr.fetching = false
          tr.entries = entries
          requestFrame()
        menu.fetchMenu(b, tr.menuSvc, tr.menuPath, got2)

proc menuChildView() =
  setTheme(gothicTheme(tr.dark))
  let t = activeTheme
  if pressed("Escape"):
    platform.quit()
  var rows = 0
  for e in tr.entries:
    if e.visible: inc rows
  clay "menuwin", col(width = fixedPx(menuW), height = grow(),
      gap = 0, padding = padAll(2))
      .bg(t.palette.panelBg)
      .border(t.metrics.borderHairline, t.palette.panelBorder):
    if tr.fetching and rows == 0:
      clay "menu.wait", row(width = grow(), height = fixedPx(menuRowH),
          padding = padAll(6)):
        textElement("loading\u2026", TextConfig(fontSize: t.text.menu,
            color: t.palette.dimColor))
    for e in tr.entries:
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
      if clickedIn(rid) and e.enabled and not tr.fetching:
        menu.activateItem(tr.bus, tr.menuSvc, tr.menuPath, e)
        platform.quit()
  let h = (4 + max(rows, if tr.fetching: 1 else: 0) * menuRowH).int32
  if h != tr.reqH and h > 0:
    if requestLayerSize(menuW.int32, h):
      tr.reqH = h

proc menuChild(service, path, unique: string) =
  tr.menuSvc = service
  tr.menuPath = path
  tr.menuUnique = unique
  if getEnv("TRAY_LIGHT") == "1": tr.dark = false
  tr.reqW = menuW.int32
  tr.bus = newBus()
  let bus = tr.bus
  proc dbusWake() {.gcsafe.} =
    bus.pump()
    requestFrame()
  if not watchFd(bus.fd(), dbusWake):
    echo "tray menu: failed to watch the dbus socket"
    system.quit(1)
  run App(window: WindowConfig(
        title: "tray-menu",
        width: menuW, height: 60,
        resizable: false,
        layer: LayerConfig(
          enabled: true, edge: edgeTop, level: layerOverlay,
          thickness: 60, length: menuW, exclusive: 0,
          anchorEnd: true, marginEnd: marginEndDefault(),
          keyboard: keyboardExclusive, namespace: "alatar-tray-menu")),
      debugMode: false,
      setup: menuChildSetup,
      view: menuChildView)

# --- dbus plumbing ------------------------------------------------------------

proc initBus() =
  tr.bus = newBus()
  tr.host = newHost(tr.bus)
  let autoNeedle = getEnv("TRAY_AUTO")  # test helper: auto-open one item's
                                        # menu as soon as the item loads
  tr.host.onItemsChanged =
    proc (h: sni.Host) =
      tr.pruneIcons()
      if autoNeedle.len > 0 and tr.openItem == nil:
        for it in h.snapshot:
          if it.loaded and (autoNeedle in it.id or autoNeedle in it.service):
            tr.openMenuFor(it)
            break
      requestFrame()
  let bus = tr.bus
  proc dbusWake() {.gcsafe.} =
    bus.pump()
    requestFrame()   # state may have changed even without host callbacks
  let ok = watchFd(bus.fd(), dbusWake)
  if not ok:
    echo "tray: failed to watch the dbus socket"
  setOverlay(overlay)

# --- entry --------------------------------------------------------------------

proc printItems(host: sni.Host) =
  let its = host.snapshot
  echo "--- items (" & $its.len & ") watcher=" &
       $host.ownsWatcher & " bus=" & host.bus.uniqueName & " ---"
  for item in its:
    echo "  ", item.service, " ", item.path,
         "  id=", (if item.loaded: item.id else: "(loading)"),
         " status=", item.status,
         " icon='", item.iconName, "'",
         " themePath='", item.iconThemePath, "'",
         " pixmaps=", $item.pixmaps.len,
         (if item.pixmaps.len > 0:
            "[" & item.pixmaps.mapIt($it.width & "x" & $it.height).join(",") & "]"
          else: ""),
         " menu='", item.menu, "'",
         " isMenu=", $item.isMenu

proc probe(seconds: int) =
  tr.bus = newBus()
  tr.host = newHost(tr.bus)
  var dirty = true
  tr.host.onItemsChanged =
    proc (h: sni.Host) = dirty = true
  var elapsed = 0
  while elapsed < seconds * 1000 and not tr.bus.broke:
    if tr.bus.fdReady(dbusd.pollTimeoutMs):
      tr.bus.pump()
    else:
      elapsed += dbusd.pollTimeoutMs
    if dirty:
      dirty = false
      printItems(tr.host)
  printItems(tr.host)

proc menuDump(needle: string) =
  ## Fetch and print one item's dbusmenu: the GetLayout/GetGroupProperties
  ## chain without a window - the parser's own test bench.
  tr.bus = newBus()
  tr.host = newHost(tr.bus)
  var rows: seq[seq[menu.MenuEntry]] = @[]
  var target: TrayItem = nil
  var waited = 0
  # find the item whose id/menu mentions the needle (loaded properties)
  while waited < 5000 and target == nil and not tr.bus.broke:
    if tr.bus.fdReady(dbusd.pollTimeoutMs):
      tr.bus.pump()
    else:
      waited += dbusd.pollTimeoutMs
    for it in tr.host.snapshot:
      if it.loaded and (needle in it.id or needle in it.service or
          needle in it.menu):
        target = it
        break
  if target == nil:
    echo "no item matching '", needle, "' (watcher=", $tr.host.ownsWatcher,
         ", items=", tr.host.snapshot.len, ")"
    return
  echo "item: ", target.id, "  menu=", target.menu
  menu.debug = true
  proc got(entries: seq[menu.MenuEntry]) {.gcsafe.} =
    echo "[dump] got ", entries.len, " rows"
    rows.add entries
  menu.fetchMenu(tr.bus, target.service, target.menu, got)
  var t = 0
  while rows.len == 0 and t < 5000 and not tr.bus.broke:
    if tr.bus.fdReady(dbusd.pollTimeoutMs):
      tr.bus.pump()
    else:
      t += dbusd.pollTimeoutMs
  if rows.len == 0:
    echo "(no layout reply)"
    return
  echo "[dump] rows=", rows.len, " first=", rows[0].len
  for e in rows[0]:
    if not e.visible: continue
    let marks = (if e.toggleState == "on": "[x] "
                 elif e.toggleState == "mixed": "[-] "
                 elif e.toggleState.len > 0: "[ ] " else: "")
    echo "  ", "  ".repeat(e.depth), marks, (if e.label.len == 0: "(sep)" else: e.label),
         (if not e.enabled: "  (disabled)" else: "")

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == "--probe":
    let secs =
      if paramCount() >= 2: parseInt(paramStr(2))
      else: 5
    probe(secs)
  elif paramCount() >= 2 and paramStr(1) == "--menu":
    menuDump(paramStr(2))
  elif paramCount() >= 3 and paramStr(1) == "--menu-child":
    let extra = if paramCount() >= 4: paramStr(4) else: ""
    menuChild(paramStr(2), paramStr(3), extra)
  else:
    for a in commandLineParams():
      if a == "--light": tr.dark = false
    run App(window: WindowConfig(
          title: "tray",
          width: 26, height: stripH,
          resizable: false,
          layer: LayerConfig(
            enabled: true, edge: edgeTop, level: layerOverlay,
            thickness: stripH.int32, length: 26, exclusive: -1,
            anchorEnd: true, marginEnd: marginEndDefault(),
            keyboard: keyboardOnDemand, namespace: "alatar-tray")),
        debugMode: false,
        setup: initBus,
        view: view)
