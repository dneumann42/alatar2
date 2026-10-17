# ============================================================================
# bar-buttons — configurable GTK4 layer-shell buttons beside the swaybar.
#
# swaybar can only render text, so each button is a tiny gtk4-layer-shell
# surface anchored to every monitor's top edge, sitting inside the bar's
# side gaps (see `gaps` in ../bar.conf; bar_height/button_width below must
# stay in sync with `height` and `gaps`). Buttons are defined in
# buttons.toml (beside this project's sources; see that file for the keys).
# Left-side buttons stack left→right from the screen's left edge in file
# order, right-side buttons stack from the right edge. A click runs the
# button's command through `sh -c`, detached.
#
# The file is watched (1 s mtime poll in the GLib loop): edits apply live.
# Adding/removing buttons or changing button_width means updating bar.conf's
# `gaps` too, so run `swaymsg reload` afterwards (also restarts us).
#
# Must be started with LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so — see
# scripts/bar-buttons.sh and statusbar/layershell.nim for why.
# ============================================================================

import std/[os, strformat, strutils, times]
import parsetoml
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
    buttons: seq[Button]

var
  app: pointer
  cfg: Settings
  cfgPath: string
  cfgStamp: Time
  cssProvider: pointer
  windows: seq[pointer]
  activated = false

# ---- config ----

template optStr(t: TomlValueRef, key, dflt: string): string =
  if t.hasKey(key): t[key].getStr(dflt) else: dflt

template optInt(t: TomlValueRef, key: string, dflt: int): int =
  if t.hasKey(key): t[key].getInt(dflt) else: dflt

proc parseConfig(path: string): Settings =
  let root = parseFile(path)
  let s = Settings(
    barHeight:   root.optInt("bar_height", 20),     # sync: bar.conf `height`
    buttonWidth: root.optInt("button_width", 24),   # sync: bar.conf `gaps`
    iconHeight:  root.optInt("icon_height", 16),
    font:        root.optStr("font", "AtkynsonMono Nerd Font"),
    fontSize:    root.optInt("font_size", 11),
    bg:          root.optStr("background", "#000000"),
    bgHover:     root.optStr("hover_background", "#1c1f26"),
    fg:          root.optStr("foreground", "#9aa4b2"),
    fgHover:     root.optStr("hover_foreground", "#e6eaf2"),
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
  1  # keep the timeout

proc onMonitorsChanged(model, position, nRemoved, nAdded: pointer) {.cdecl.} =
  build()

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

when isMainModule:
  if preloadLib notin getEnv("LD_PRELOAD", ""):
    quit "bar-buttons: needs LD_PRELOAD=" & preloadLib &
         " (run via scripts/bar-buttons.sh; see statusbar/layershell.nim)"
  cfgPath  = findConfig()
  cfg      = parseConfig(cfgPath)     # first load: hard-fail on a bad config
  cfgStamp = getLastModificationTime(cfgPath)
  app = gtk_application_new(appId, 0)
  discard g_signal_connect_data(app, "activate",
      cast[pointer](onActivate), nil, nil, 0)
  discard g_application_run(app, 0, nil)
