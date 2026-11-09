import ellipse_ui

import ./actions
import ./state
import ./widgets

proc service(s: State, key, title, status: string, active: bool,
             panel: Panel, action: proc (s: State),
             width: SizingAxis = grow()) =
  case quickButton(elementId(key), title, status, active,
                   open = s.panel == panel, width = width):
  of bhToggle: action(s)
  of bhExpand: s.setPanel(panel)
  of bhNone: discard

proc link(s: State, key, label: string) =
  if textLink(elementId(key), label):
    s.dismiss()

proc sourceRow(key: string, title: string, status: string,
               active: bool): bool =
  quickButton(elementId(key), title, status, active, arrow = false,
              width = grow()) == bhToggle

proc plain(s: State, key, title, status: string, active: bool,
           action: proc (s: State)) =
  if sourceRow(key, title, status, active):
    action(s)

proc note(s: State) =
  if s.note.len > 0:
    caption(s.note)

proc reopenBackground(s: State) =
  s.setPanel(panelBackground)

## The disclosure cards open inline, directly under the row whose button
## was expanded (see `toggleGrid`, `audioRows`, `backgroundRow`), so the
## panel belongs to the control it came from instead of one fixed spot at
## the foot of the grid.

proc panelCard(s: State) =
  case s.panel
  of panelWifi:
    Card(title = "Wi-Fi Networks"):
      note(s)
      if s.networks.len == 0 and s.note.len == 0:
        caption("No networks found.")
      for n in s.networks:
        if sourceRow("net." & n.ssid, n.ssid, signalLabel(n.signal),
                     n.connected):
          s.connectNetwork(n.ssid)
      link(s, "wifi.more", "All Networks…")
  of panelWired:
    Card(title = "Wired"):
      note(s)
      caption(if s.wiredName.len > 0: "Connected: " & s.wiredName
              else: "No wired connection.")
      link(s, "wired.settings", "Wired Settings…")
  of panelBluetooth:
    Card(title = "Bluetooth Devices"):
      note(s)
      if not s.btOn:
        if s.note.len == 0:
          caption("Bluetooth is off.")
      else:
        for d in s.btDevices:
          if sourceRow("dev." & d.address, d.name,
                       if d.connected:
                         (if d.battery > 0: $d.battery & "% Connected"
                          else: "Connected")
                       else: "Paired",
                       d.connected):
            s.toggleDevice(d.address)
      link(s, "bt.settings", "Bluetooth Settings…")
  of panelPower:
    Card(title = "Power Mode"):
      for mode in PowerMode:
        if sourceRow("mode." & $mode, powerLabel(mode), "",
                     s.powerMode == mode):
          s.pickMode(mode)
      link(s, "power.settings", "Power Settings…")
  of panelOutput:
    Card(title = "Audio Outputs"):
      note(s)
      for node in s.sinks:
        if sourceRow("out." & node.name,
                     if node.description.len > 0: node.description
                     else: node.name,
                     if node.muted: "Muted" else: $node.volume & "%",
                     node.preferred):
          s.selectSink(node.name)
  of panelInput:
    Card(title = "Audio Inputs"):
      note(s)
      for node in s.sources:
        if sourceRow("in." & node.name,
                     if node.description.len > 0: node.description
                     else: node.name,
                     if node.muted: "Muted" else: $node.volume & "%",
                     node.preferred):
          s.selectSource(node.name)
  of panelBackground:
    Card(title = "Background Apps"):
      if s.background.len == 0:
        caption("No background apps.")
      var gone = ""
      for app in s.background:
        if sourceRow("app." & app, app, "Running", false):
          gone = app
      if gone.len > 0:
        s.closeApp(gone)
      link(s, "app.settings", "App Settings…")
  of panelNone:
    discard

proc toggleGrid(s: State) =
  clay "grid", col(width = grow(), gap = 8):
    clay "grid.net", row(width = grow(), gap = 8):
      service(s, "wifi", "Wi-Fi", s.wifiSubtitle, s.wifiOn, panelWifi,
              toggleWifi)
      service(s, "wired", "Wired", s.wiredSubtitle, s.wiredOn, panelWired,
              toggleWired)
    if s.panel in {panelWifi, panelWired}:
      panelCard(s)
    clay "grid.sys", row(width = grow(), gap = 8):
      service(s, "bt", "Bluetooth", s.btSubtitle, s.btOn, panelBluetooth,
              toggleBluetooth)
      service(s, "power", "Power Mode", powerLabel(s.powerMode),
              s.powerMode != pmBalanced, panelPower, togglePower)
    if s.panel in {panelBluetooth, panelPower}:
      panelCard(s)
    clay "grid.light", row(width = grow(), gap = 8):
      plain(s, "night", "Night Light",
            if s.nightLight: "On" else: "Off", s.nightLight,
            toggleNightLight)
      plain(s, "dark", "Dark Style",
            if s.darkStyle: "On" else: "Off", s.darkStyle, toggleDarkStyle)
    clay "grid.misc", row(width = grow(), gap = 8):
      plain(s, "airplane", "Airplane Mode",
            if s.airplane: "On" else: "Off", s.airplane, toggleAirplane)
      plain(s, "backlight", "Keyboard", s.backlightLabel,
            s.backlight > 0, cycleBacklight)
      plain(s, "monitor", "Monitor Mode", s.monitorSubtitle,
            s.monitorOn, toggleMonitor)
      plain(s, "wallpaper", "Wallpaper", "Shift+Super+W", false,
            switchWallpaper)

proc brightnessRow(s: State) =
  clay "bright", row(width = grow(), gap = 6, alignY = centerY):
    clay "bright.label", col(width = fixedPx(140)):
      caption("Brightness")
    s.brightness = slider(hashId("bright.slider"), s.brightness).value

proc audioRows(s: State) =
  clay "audio", col(width = grow(), gap = 8):
    clay "audio.out", row(width = grow(), gap = 6, alignY = centerY):
      service(s, "sound", "Sound", s.sinkSubtitle,
              not s.defaultSink.muted, panelOutput, toggleMute,
              width = fixedPx(140))
      let volume = slider(hashId("sound.slider"), s.volumeUi,
                          dimmed = s.defaultSink.muted)
      s.volumeUi = volume.value
      if volume.committed:
        s.setSinkVolume(volume.value)
    if s.panel == panelOutput:
      panelCard(s)
    clay "audio.in", row(width = grow(), gap = 6, alignY = centerY):
      service(s, "mic", "Input", s.micSubtitle,
              not s.defaultSource.muted, panelInput, toggleMicMute,
              width = fixedPx(140))
      let mic = slider(hashId("mic.slider"), s.micUi,
                       dimmed = s.defaultSource.muted)
      s.micUi = mic.value
      if mic.committed:
        s.setMicVolume(mic.value)
    if s.panel == panelInput:
      panelCard(s)

proc backgroundRow(s: State) =
  service(s, "background", "Background",
          $s.background.len & (if s.background.len == 1: " App" else: " Apps"),
          s.panel == panelBackground, panelBackground, reopenBackground)
  if s.panel == panelBackground:
    panelCard(s)

proc render*(s: State) =
  clay "menu", col(width = grow(), height = grow(), padding = padAll(12),
      gap = 8)
      .clip(horizontal = false, vertical = true,
            childOffset = currentScrollOffset()):
    toggleGrid(s)
    brightnessRow(s)
    audioRows(s)
    backgroundRow(s)
    scrollbar(hashId("menu.bar"), hashId("menu"))
