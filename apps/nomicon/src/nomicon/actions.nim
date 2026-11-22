import std/sequtils

import alatar/[controls, desktopmode]

import ./state

template attempt(s: State, body: untyped) =
  try:
    body
    s.note = ""
  except ControlError as e:
    s.note = e.msg

proc refreshOutput(s: State) =
  attempt s:
    s.sinks = sinks()
    s.volumeUi = s.defaultSink.volume

proc refreshInput(s: State) =
  attempt s:
    s.sources = sources()
    s.micUi = s.defaultSource.volume

proc syncAirplane(s: State) =
  s.airplane = not s.connected

proc refreshWifi(s: State) =
  attempt s:
    s.wifiOn = wifiEnabled()
    s.networks = wifiNetworks()
  syncAirplane(s)

proc refreshWired(s: State) =
  attempt s:
    let connection = wiredConnection()
    s.wiredDevice = connection.device
    s.wiredName = connection.name
    s.wiredOn = connection.name.len > 0
  syncAirplane(s)

proc refreshBluetooth(s: State) =
  attempt s:
    s.btAvailable = bluetoothAvailable()
    s.btOn = s.btAvailable and bluetoothEnabled()
    s.btDevices = if s.btOn: bluetoothDevices() else: @[]
  syncAirplane(s)

proc refreshDisplays(s: State) =
  attempt s:
    s.outputs = swayOutputs()
    var name = portraitOutputName(s.outputs)
    if name.len == 0: name = s.monitorName
    if name.len > 0 and not s.outputs.anyIt(it.name == name): name = ""
    if name.len == 0:
      for candidate in rotatedOutputNames():
        if s.outputs.anyIt(it.name == candidate):
          name = candidate
          break
    s.monitorName = name
    s.monitorOn = s.outputs.anyIt(it.name == name and it.power)
    s.primaryName = primaryOutputName(s.outputs)

proc loadSettings*(group: SettingsGroup): State =
  result = newState()
  case group
  of settingsWifi: refreshWifi(result)
  of settingsWired: refreshWired(result)
  of settingsBluetooth: refreshBluetooth(result)
  of settingsDisplays: refreshDisplays(result)
  of settingsOutput: refreshOutput(result)
  of settingsInput: refreshInput(result)

proc applySettings*(s: State, group: SettingsGroup, loaded: State) =
  case group
  of settingsWifi:
    s.wifiOn = loaded.wifiOn
    s.networks = loaded.networks
  of settingsWired:
    s.wiredOn = loaded.wiredOn
    s.wiredDevice = loaded.wiredDevice
    s.wiredName = loaded.wiredName
  of settingsBluetooth:
    s.btAvailable = loaded.btAvailable
    s.btOn = loaded.btOn
    s.btDevices = loaded.btDevices
  of settingsDisplays:
    s.outputs = loaded.outputs
    s.monitorName = loaded.monitorName
    s.monitorOn = loaded.monitorOn
    s.primaryName = loaded.primaryName
  of settingsOutput:
    s.sinks = loaded.sinks
    s.volumeUi = loaded.volumeUi
  of settingsInput:
    s.sources = loaded.sources
    s.micUi = loaded.micUi
  s.pending.excl(group)
  syncAirplane(s)

proc refreshPanel*(s: State, panel: Panel) =
  case panel
  of panelWifi: refreshWifi(s)
  of panelWired: refreshWired(s)
  of panelBluetooth: refreshBluetooth(s)
  of panelOutput: refreshOutput(s)
  of panelInput: refreshInput(s)
  else: discard

proc toggleWifi*(s: State) =
  attempt s:
    setWifiEnabled(not s.wifiOn)
    refreshWifi(s)

proc toggleWired*(s: State) =
  attempt s:
    setWiredEnabled(not s.wiredOn)
    refreshWired(s)

proc toggleBluetooth*(s: State) =
  attempt s:
    setBluetoothEnabled(not s.btOn)
    refreshBluetooth(s)

proc toggleAirplane*(s: State) =
  attempt s:
    let enable = s.connected
    setWifiEnabled(not enable)
    if s.btAvailable: setBluetoothEnabled(not enable)
    if s.wiredDevice.len > 0: setWiredEnabled(not enable)
    refreshWifi(s)
    refreshWired(s)
    refreshBluetooth(s)

## `disable` (not `power off`): sway moves the vertical monitor's windows to
## the remaining outputs and re-applies its stored transform/position on
## `enable`, and sway re-appends re-enabled outputs behind DP-1 in the
## XWayland list, so the 32" stays XRandR monitor 0 for Steam games.
## Single mode means *single*: every non-primary output (the vertical plus
## any side monitors like HDMI-A-1) goes down, leaving only the 32" alive;
## Dual brings them all back up.
proc toggleMonitor*(s: State) =
  attempt s:
    if s.monitorName.len == 0:
      raise newException(ControlError, "No vertical monitor found")
    if s.primaryName.len == 0:
      raise newException(ControlError, "No primary monitor found")
    let enable = not s.monitorOn
    for o in s.outputs:
      if o.name == s.primaryName:
        continue
      setOutputEnabled(o.name, enable)
    refreshDisplays(s)

## Same switcher as sway's Shift+Mod4+w binding: opens the picker through
## sway's own exec so it runs with the compositor's environment. The picker
## is a detached sway process; waiting for it would freeze the app, and
## sway's exec never reports its exit code back, so success just means the
## command reached sway. Note: sway reloads when wallust applies the new
## theme, which closes this window if it is tiled (see sway issue #8215).
proc switchWallpaper*(s: State) =
  attempt s:
    swayExecScript("set-wallpaper.sh")
    s.note = "Wallpaper picker opened"

proc connectNetwork*(s: State, ssid: string) =
  attempt s:
    connectWifi(ssid)
    refreshWifi(s)

proc toggleDevice*(s: State, address: string) =
  attempt s:
    for d in s.btDevices:
      if d.address == address:
        if d.connected: disconnectBluetooth(address)
        else: connectBluetooth(address)
        break
    refreshBluetooth(s)
    if settingsOutput notin s.pending: refreshOutput(s)
    if settingsInput notin s.pending: refreshInput(s)

proc toggleMute*(s: State) =
  attempt s:
    setMuted(s.defaultSink(), not s.defaultSink().muted)
    refreshOutput(s)

proc toggleMicMute*(s: State) =
  attempt s:
    setMuted(s.defaultSource(), not s.defaultSource().muted)
    refreshInput(s)

proc setSinkVolume*(s: State, percent: int) =
  attempt s:
    setVolume(s.defaultSink(), percent)
    refreshOutput(s)

proc setMicVolume*(s: State, percent: int) =
  attempt s:
    setVolume(s.defaultSource(), percent)
    refreshInput(s)

proc selectSink*(s: State, name: string) =
  attempt s:
    for node in s.sinks:
      if node.name == name:
        setPreferred(node)
        break
    refreshOutput(s)

proc selectSource*(s: State, name: string) =
  attempt s:
    for node in s.sources:
      if node.name == name:
        setPreferred(node)
        break
    refreshInput(s)

proc toggleNightLight*(s: State) =
  s.nightLight = not s.nightLight

proc toggleDarkStyle*(s: State) =
  try:
    setDarkMode(not s.darkStyle)
    s.darkStyle = not s.darkStyle
    s.note = ""
  except CatchableError as err:
    s.note = "Could not save color mode: " & err.msg

proc cycleBacklight*(s: State) =
  s.backlight = (s.backlight + 1) mod 3

proc togglePower*(s: State) =
  if s.powerMode == pmSaver:
    s.powerMode = s.powerWas
  else:
    s.powerWas = s.powerMode
    s.powerMode = pmSaver

proc pickMode*(s: State, mode: PowerMode) =
  if mode != pmSaver: s.powerWas = mode
  s.powerMode = mode

proc setPanel*(s: State, panel: Panel) =
  s.panel = if s.panel == panel: panelNone else: panel
  if s.panel != panelNone:
    refreshPanel(s, s.panel)

proc dismiss*(s: State) =
  s.panel = panelNone
  s.note = ""

func closeApp*(s: State, name: string) =
  for i, app in s.background:
    if app == name:
      s.background.delete(i)
      break
