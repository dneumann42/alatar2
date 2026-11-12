# ============================================================================
# bar-buttons — configurable GTK4 layer-shell buttons beside the swaybar.
#
# swaybar can only render text, so each button is a tiny gtk4-layer-shell
# surface anchored to every monitor's top edge, sitting inside the bar's
# side gaps. bar.conf's `gaps` line is only the initial value at load time;
# at runtime we push the computed margins to swaybar ourselves (syncBarGaps)
# and bar_height must stay in sync with `height`. Buttons are defined in
# buttons.toml (beside this project's sources; see that file for the keys).
# Left-side buttons stack left→right from the screen's left edge in file
# order, right-side buttons stack from the right edge. A click runs the
# button's command through `sh -c`, detached.
#
# The file is watched (1 s mtime poll in the GLib loop): edits apply live.
# Button + tray margins are synced to swaybar automatically (syncBarGaps
# below) — adding/removing buttons or applets needs NO `swaymsg reload`:
# we push the gaps into sway's runtime config, then restart only swaybar,
# which re-renders in ~100 ms. (swaybar 1.12 parses barconfig_update and
# redraws, but its layer-surface margins are only ever re-sent on a
# reconfigure, and a bare reconfigure garbles the layout — measured on
# swayfx 0.6. A fresh swaybar process is the one path that lays out
# correctly.) The spawned replacement is our child; see onTerminate.
#
# Must be started with LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so — see
# scripts/bar-buttons.sh and statusbar/layershell.nim for why.
# ============================================================================

import std/json except parseFile     # parsetoml.parseFile is the one used
import std/[os, strformat, strutils, times]
import posix except Time, sleep   # times.Time and os.sleep(ms) win
import parsetoml
import osproc
import statusbar/[layershell, util]

const
  appId    = "dev.dneumann.sway-bar-buttons"
  preloadLib = "/usr/lib/libgtk4-layer-shell.so"

type
  Side = enum sideLeft, sideRight

  Button = ref object
    side: Side
    command: string
    icon: string     # resolved absolute path; "" when glyph is used
    glyph: string    # "" when icon is used
    font: string     # glyph buttons only
    fontSize: int    # pt, glyph buttons only
    cssClass: string

  Settings = ref object
    barHeight, buttonWidth, iconHeight: int
    font: string
    fontSize: int
    bg, bgHover, fg, fgHover: string
    swayBarId: string          # sway bar to push gaps to; "" disables
    gapPadLeft, gapPadRight: int  # extra px per side beyond our buttons
    trayWidthFile: string      # alatar-tray heartbeat file; "" disables
    buttons: seq[Button]

var
  app: pointer
  cfg: Settings
  cfgPath: string
  cfgStamp: Time
  cssProvider: pointer
  windows: seq[pointer]
  activated = false
  pushedGapLeft, pushedGapRight = -1   # px swaybar is currently using
  barProc: Process                      # swaybar we (re)spawned, if any
  pendingGapLeft, pendingGapRight = -1  # debounced apply: pending values
  pendingAt: Time
  pendingSet = false
  debounceMs = 1500                     # gap must hold steady this long

# ---- config ----

template optStr(t: TomlValueRef, key, dflt: string): string =
  if t.hasKey(key): t[key].getStr(dflt) else: dflt

template optInt(t: TomlValueRef, key: string, dflt: int): int =
  if t.hasKey(key): t[key].getInt(dflt) else: dflt

proc parseConfig(path: string): Settings =
  let root = parseFile(path)
  let s = Settings(
    barHeight:   root.optInt("bar_height", 20),     # sync: bar.conf `height`
    buttonWidth: root.optInt("button_width", 24),   # gaps derive from this
    iconHeight:  root.optInt("icon_height", 16),
    font:        root.optStr("font", "JetBrainsMono Nerd Font"),
    fontSize:    root.optInt("font_size", 11),
    bg:          root.optStr("background", "#000000"),
    bgHover:     root.optStr("hover_background", "#1c1f26"),
    fg:          root.optStr("foreground", "#9aa4b2"),
    fgHover:     root.optStr("hover_foreground", "#e6eaf2"),
    swayBarId:   root.optStr("sway_bar_id", "main"),
    gapPadLeft:  root.optInt("gap_pad_left", 0),
    gapPadRight: root.optInt("gap_pad_right", 0),
    trayWidthFile: root.optStr("tray_width_file",
        getEnv("XDG_RUNTIME_DIR", "/tmp") / "alatar-tray.width"),
    buttons:     @[])
  var n = 0
  if root.hasKey("button"):
    let arr = root["button"]
    if arr.kind != TomlValueKind.Array:
      raise newException(ValueError, "'button' must be an array of tables")
    for b in arr.arrayVal:
      inc n
      let side = b.optStr("side", "left")
      if side notin ["left", "right"]:
        raise newException(ValueError, &"button {n}: side must be left|right, got '{side}'")
      let btn = Button(
        side:     if side == "left": sideLeft else: sideRight,
        command:  b.optStr("command", ""),
        icon:     b.optStr("icon", ""),
        glyph:    b.optStr("glyph", ""),
        font:     b.optStr("font", s.font),
        fontSize: b.optInt("font_size", s.fontSize),
        cssClass: "barbtn" & $n)
      if btn.command.len == 0:
        raise newException(ValueError, &"button {n}: missing command")
      if btn.icon.len > 0:
        btn.icon = btn.icon.expandTilde
        if not btn.icon.isAbsolute:
          btn.icon = parentDir(path).joinPath(btn.icon)
      elif btn.glyph.len == 0:
        raise newException(ValueError, &"button {n}: needs icon or glyph")
      s.buttons.add btn
  result = s

proc loadCfg(): Settings =
  ## Parse current config; on failure report and keep the old one (a
  ## half-saved file during editing must not blank the bar).
  try:
    result = parseConfig(cfgPath)
  except CatchableError as e:
    stderr.writeLine "bar-buttons: " & cfgPath & ": " & e.msg
    result = nil

# ---- styling ----

proc css(c: Settings): string =
  for b in c.buttons:
    let fontBits =
      if b.glyph.len > 0:
        &"\n  color: {c.fg};\n  font-family: {b.font};\n  font-size: {b.fontSize}pt;"
      else: ""
    let hoverFont = if b.glyph.len > 0: &" color: {c.fgHover};" else: ""
    result &= &"""
button.{b.cssClass} {{
  background-image: none;
  background-color: {c.bg};
  border: none;
  border-radius: 0;
  box-shadow: none;
  outline: none;
  margin: 0;
  padding: 0;
  min-width: 0;
  min-height: 0;{fontBits}
}}
button.{b.cssClass}:hover {{ background-color: {c.bgHover};{hoverFont} }}
"""

# ---- windows ----

proc onClicked(btn, userData: pointer) {.cdecl.} =
  spawnDetached(cast[Button](userData).command)

proc makeWindow(monitor: pointer, b: Button, slot: int) =
  var child: pointer
  if b.icon.len > 0:
    let pb = gdk_pixbuf_new_from_file_at_scale(b.icon.cstring, -1, cfg.iconHeight.cint, 1, nil)
    if pb.isNil:
      stderr.writeLine "bar-buttons: cannot load icon '" & b.icon & "'"
      return
    child = gtk_image_new_from_pixbuf(pb)
  else:
    child = gtk_label_new(b.glyph.cstring)

  let btn = gtk_button_new()
  gtk_button_set_child(btn, child)
  gtk_widget_add_css_class(btn, b.cssClass.cstring)
  gtk_widget_set_can_focus(btn, 0)
  gtk_widget_set_size_request(btn, cfg.buttonWidth.cint, cfg.barHeight.cint)
  discard gtk_widget_set_cursor_from_name(btn, "pointer")
  # userData points into cfg.buttons, which the global cfg keeps alive
  discard g_signal_connect_data(btn, "clicked",
      cast[pointer](onClicked), cast[pointer](b), nil, 0)

  let win = gtk_application_window_new(app)
  gtk_window_set_child(win, btn)
  # shrink-wrap the window to the button (a fresh GtkApplicationWindow would
  # otherwise ask the compositor for the stock 200x200 default size)
  gtk_window_set_default_size(win, 1, 1)

  let edge = if b.side == sideLeft: edgeLeft else: edgeRight
  gtk_layer_init_for_window(win)
  gtk_layer_set_monitor(win, monitor)
  gtk_layer_set_namespace(win, "sway-bar-buttons")
  gtk_layer_set_layer(win, layerOverlay)
  gtk_layer_set_anchor(win, edgeTop, 1)
  gtk_layer_set_anchor(win, edge, 1)
  gtk_layer_set_margin(win, edgeTop, 0)
  gtk_layer_set_margin(win, edge, (slot * cfg.buttonWidth).cint)
  gtk_layer_set_exclusive_zone(win, -1)  # overlay the gap, reserve nothing
  gtk_layer_set_keyboard_mode(win, kbNone)
  gtk_window_present(win)
  windows.add win

proc trayWidth(): int =
  ## Live width of the apps/tray strip, from its per-frame heartbeat file
  ## (`alatar-tray.width` in $XDG_RUNTIME_DIR, written by apps/tray).
  ## 0 when disabled, missing, unparseable, or older than 5 s — the tray
  ## died, so the gap may shrink back to the button block alone.
  if cfg.trayWidthFile.len == 0 or not fileExists(cfg.trayWidthFile): return 0
  try:
    if (getTime() - getLastModificationTime(cfg.trayWidthFile)).inSeconds > 5: return 0
    let txt = readOrEmpty(cfg.trayWidthFile).strip
    if txt.isUnsignedInt: txt.parseInt else: 0
  except CatchableError:
    0

proc computeGaps(): (int, int) =
  ## px swaybar must reserve per side: our buttons plus the configured
  ## static pad plus the live tray strip width.
  var nLeft, nRight = 0
  for b in cfg.buttons:
    if b.side == sideLeft: inc nLeft
    else: inc nRight
  (nLeft * cfg.buttonWidth + cfg.gapPadLeft,
   nRight * cfg.buttonWidth + cfg.gapPadRight + trayWidth())

proc restartSwaybar() =
  ## Replace the running swaybar with a fresh one that starts with the
  ## margins we just pushed — the ONLY path that lays them out correctly
  ## (swaybar 1.12 re-sends layer margins only in its reconfigure branch,
  ## and reposition-only updates garble its render; measured on swayfx
  ## 0.6). Sway never respawns swaybar at runtime, so we own it: our
  ## child dies with us (onTerminate), and on the next full sway reload
  ## sway spawns its own tracked bar again.
  discard sh("pkill", "-x", "swaybar")
  if barProc != nil:
    discard barProc.waitForExit(500)   # reap the one pkill just signalled
  sleep(100)
  let exe = findExe("swaybar")
  if exe.len == 0:
    stderr.writeLine "bar-buttons: swaybar not found in PATH"
    return
  try:
    barProc = startProcess(exe, args = ["-b", cfg.swayBarId])
  except CatchableError as e:
    stderr.writeLine "bar-buttons: swaybar respawn failed: " & e.msg

proc syncBarGaps() =
  ## Queue gap updates: swaybar restarts flicker, so only act once the
  ## computed pair has held steady for debounceMs (applet storms during
  ## app startup collapse into one restart). The pair is pushed into
  ## sway's runtime config with `bar <id> gaps <top> <right> <bottom>
  ## <left>` — the all-numeric form is mandatory, `gaps left N` is
  ## window-gaps syntax and a parse error for bars.
  if cfg.swayBarId.len == 0: return
  let (left, right) = computeGaps()
  if left == pushedGapLeft and right == pushedGapRight:
    pendingSet = false
    return
  if not pendingSet or left != pendingGapLeft or right != pendingGapRight:
    pendingGapLeft = left; pendingGapRight = right
    pendingAt = getTime() + initDuration(milliseconds = debounceMs)
    pendingSet = true

proc cmdOk(res: string): bool =
  ## swaymsg command replies: [{"success":true,...}] — pretty-printed, so
  ## parse it properly instead of grepping for one exact whitespace shape.
  try:
    let j = parseJson(res)
    j.kind == JArray and j.len > 0 and j[0].contains("success") and
      j[0]["success"].getBool
  except CatchableError:
    false

proc applyPendingGaps() =
  if not pendingSet: return
  if getTime() < pendingAt: return
  pendingSet = false
  let (left, right) = (pendingGapLeft, pendingGapRight)
  let res = sh("swaymsg", "-r", "bar", cfg.swayBarId,
               "gaps", "0", $right, "0", $left)
  if not cmdOk(res):
    stderr.writeLine "bar-buttons: swaymsg bar gaps failed: " & res
    return
  pushedGapLeft  = left
  pushedGapRight = right
  restartSwaybar()

proc currentBarGaps(id: string): (int, int) =
  ## sway's view of the bar's gaps; (-1, -1) when unreadable (no bar yet).
  let outp = sh("swaymsg", "-t", "get_bar_config", id)
  if outp.len == 0: return (-1, -1)
  try:
    let j = parseJson(outp)
    if j.contains("gaps"):
      let g = j["gaps"]
      return (g["left"].getInt, g["right"].getInt)
  except CatchableError:
    discard
  (-1, -1)

proc build() =
  ## (Re)create every button window from cfg.
  for w in windows: gtk_window_destroy(w)
  windows.setLen 0
  let style = css(cfg)
  gtk_css_provider_load_from_data(cssProvider, style.cstring, -1)
  let disp = gdk_display_get_default()
  let models = gdk_display_get_monitors(disp)  # GListModel owned by the display
  for mi in 0 ..< g_list_model_get_n_items(models).int:
    let mon = g_list_model_get_item(models, mi.cuint)  # new ref, unref below
    var nLeft, nRight = 0
    for b in cfg.buttons:
      if b.side == sideLeft:
        makeWindow(mon, b, nLeft); inc nLeft
      else:
        makeWindow(mon, b, nRight); inc nRight
    g_object_unref(mon)
  syncBarGaps()

# ---- main loop hooks ----

proc pollConfig(data: pointer): cint {.cdecl.} =
  if fileExists(cfgPath):
    let stamp = getLastModificationTime(cfgPath)
    if stamp != cfgStamp:
      cfgStamp = stamp
      let next = loadCfg()
      if next != nil:
        cfg = next
        build()
  syncBarGaps()      # folds in the tray's 1 Hz width heartbeat
  applyPendingGaps() # acts once the pair has held steady
  1  # keep the timeout

proc onMonitorsChanged(model, position, nRemoved, nAdded: pointer) {.cdecl.} =
  build()

proc cleanup() {.noconv.} =
  ## Normal-exit path: reap our spawned swaybar.
  if barProc != nil:
    try:
      barProc.terminate()
      discard barProc.waitForExit(1000)
    except CatchableError:
      discard

proc onTerminate(sig: cint) {.noconv.} =
  ## SIGTERM/SIGHUP/SIGINT: sway kills exec_always children with these on
  ## reload. Keep it async-signal-safe: one kill + _exit — quit()/waits
  ## here deadlock on the runtime's locks (observed: the process survives
  ## the reload, squats the GtkApplication app_id and sway's replacement
  ## instance exits, leaving sway's fresh swaybar next to our orphan child
  ## = two bars).
  if barProc != nil:
    var pid: cint
    try: pid = barProc.processID.cint except CatchableError: pid = 0
    if pid > 0: discard kill(pid, SIGTERM)
  exitnow(0)   # posix's _exit wrapper: async-signal-safe, skips the runtime

proc onActivate(a, userData: pointer) {.cdecl.} =
  if activated: return  # a second launch forwards 'activate' to this one
  activated = true
  cssProvider = gtk_css_provider_new()
  gtk_style_context_add_provider_for_display(gdk_display_get_default(),
      cssProvider, stylePriorityApplication)
  build()
  # GdkMonitor list is a GListModel; it fires items-changed on hotplug
  # (GdkDisplay itself has no monitors-changed signal under GTK4)
  discard g_signal_connect_data(gdk_display_get_monitors(gdk_display_get_default()),
      "items-changed", cast[pointer](onMonitorsChanged), nil, nil, 0)
  discard g_timeout_add(1000, pollConfig, nil)

proc findConfig(): string =
  if paramCount() >= 1:
    result = paramStr(1).expandTilde
    if not fileExists(result): quit "bar-buttons: no such config: " & result
    return
  # beside the binary: statusbar/bin/ -> statusbar/buttons.toml
  let beside = getAppDir().parentDir / "buttons.toml"
  if fileExists(beside): return beside
  let inConfig = getConfigDir() / "sway/statusbar/buttons.toml"
  if fileExists(inConfig): return inConfig
  quit "bar-buttons: buttons.toml not found (expected beside the binary)"

proc predecessorKilled(): bool =
  ## Swayfx reload does NOT kill exec_always children (measured: a reload
  ## left the old barbuttons alive, its spawned swaybar orphaned next to
  ## sway's fresh tracked one = two bars, and the replacement instance
  ## died in GtkApplication's single-instance handshake). So every new
  ## instance takes over explicitly: TERM any older barbuttons (their
  ## onTerminate reaps our swaybar too) and wait for them to vanish.
  let me = getpid().int
  var killed = false
  for tok in sh("pgrep", "-x", "barbuttons").splitWhitespace:
    if tok.isUnsignedInt:
      let pid = tok.parseInt
      if pid != me:
        discard kill(pid.cint, SIGTERM)
        killed = true
        var waited = 0
        while waited < 2000 and fileExists("/proc/" & $pid):
          sleep(100); inc waited, 100
  killed

when isMainModule:
  if preloadLib notin getEnv("LD_PRELOAD", ""):
    quit "bar-buttons: needs LD_PRELOAD=" & preloadLib &
         " (run via scripts/bar-buttons.sh; see statusbar/layershell.nim)"
  cfgPath  = findConfig()
  cfg      = parseConfig(cfgPath)     # first load: hard-fail on a bad config
  cfgStamp = getLastModificationTime(cfgPath)
  # Seed the "what swaybar uses" cache from sway itself: at boot the bar is
  # already laid out for bar.conf's gaps, so an equal recompute must not
  # trigger a pointless restart.
  let tookOver = predecessorKilled()
  (pushedGapLeft, pushedGapRight) = currentBarGaps(cfg.swayBarId)
  # Install the (async-signal-safe) handlers before spawning anything:
  # sway's reload kills on this platform are best-effort, but HUP/INT and
  # external TERMs must still reap our swaybar child cleanly.
  discard signal(cint(SIGTERM), onTerminate)
  discard signal(cint(SIGINT), onTerminate)
  discard signal(cint(SIGHUP), onTerminate)
  if tookOver:
    # The predecessor's onTerminate took our spawned swaybar to the grave,
    # and sway may meanwhile have loaded its own tracked one — pkill and
    # respawn so exactly ONE bar is left, laid out for the live gaps.
    restartSwaybar()
  app = gtk_application_new(appId, 0)
  discard g_signal_connect_data(app, "activate",
      cast[pointer](onActivate), nil, nil, 0)
  discard g_application_run(app, 0, nil)
