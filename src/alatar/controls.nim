import std/[os, osproc, sequtils, streams, strutils]

when defined(posix) and compileOption("threads"):
  import std/[locks, posix]

  var captureSpawnLock: Lock
  initLock(captureSpawnLock)

type
  ControlError* = object of CatchableError

  AudioKind* = enum
    sink, source

  AudioNode* = object
    kind*: AudioKind
    name*: string
    description*: string
    volume*: int
    muted*: bool
    preferred*: bool

  WifiNetwork* = object
    ssid*: string
    signal*: int
    connected*: bool

  BluetoothDevice* = object
    address*: string
    name*: string
    connected*: bool
    battery*: int

  WiredConnection* = object
    device*: string
    name*: string

proc capture(command: string; args: seq[string]): tuple[output: string, code: int] =
  try:
    var p: Process
    defer:
      if p != nil: p.close()
    when defined(posix) and compileOption("threads"):
      # Keep simultaneous commands from inheriting each other's pipe ends.
      withLock captureSpawnLock:
        p = startProcess(command, args = args, options = {poUsePath, poStderrToStdout})
        for fd in [p.inputHandle.cint, p.outputHandle.cint]:
          if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0:
            raiseOSError(osLastError())
    else:
      p = startProcess(command, args = args, options = {poUsePath, poStderrToStdout})
    result.output = p.outputStream.readAll().strip()
    result.code = p.waitForExit()
  except CatchableError as e:
    raise newException(ControlError, "Failed to run '" & command & "': " & e.msg, e)

proc runOk*(command: string; args: seq[string]): string {.raises: [ControlError].} =
  let r = capture(command, args)
  if r.code != 0:
    raise newException(ControlError,
      "'" & command & " " & args.join(" ") & "' failed: " &
      (if r.output.len > 0: r.output else: "exit code " & $r.code))
  r.output

proc fieldValue(text, field: string): string =
  for line in text.splitLines():
    let t = line.strip()
    if t.startsWith(field & ":"):
      return t[(field.len + 1)..^1].strip()
  ""

proc digitsValue(text: string): int =
  for c in text:
    if c in Digits:
      result = result * 10 + (ord(c) - ord('0'))

proc percent(text: string): int =
  var i = 0
  while i < text.len and text[i] != '%':
    inc i
  if i >= text.len:
    return 0
  var j = i
  while j > 0 and text[j - 1] in Digits:
    dec j
  text[j ..< i].digitsValue()

## --- audio ---------------------------------------------------------------------

proc parseNode(blockText: string; kind: AudioKind; preferred: string): AudioNode {.raises: [].} =
  let name = blockText.fieldValue("Name")
  AudioNode(
    kind: kind,
    name: name,
    description: blockText.fieldValue("Description"),
    volume: blockText.fieldValue("Volume").percent(),
    muted: blockText.fieldValue("Mute") == "yes",
    preferred: name.len > 0 and name == preferred)

proc audioNodes(kind: AudioKind): seq[AudioNode] {.raises: [ControlError].} =
  let plural = if kind == sink: "sinks" else: "sources"
  let preferred = runOk("pactl", @["get-default-" & $kind])
  runOk("pactl", @["list", plural]).split("\n\n")
    .mapIt(it.parseNode(kind, preferred))
    .filterIt(it.name.len > 0 and not it.name.endsWith(".monitor"))

proc sinks*(): seq[AudioNode] {.raises: [ControlError].} =
  audioNodes(sink)

proc sources*(): seq[AudioNode] {.raises: [ControlError].} =
  audioNodes(source)

proc defaultNode(nodes: seq[AudioNode], kind: AudioKind): AudioNode {.
    raises: [ControlError].} =
  for node in nodes:
    if node.preferred:
      return node
  raise newException(ControlError, "No default audio " & $kind)

proc defaultSink*(): AudioNode {.raises: [ControlError].} =
  sinks().defaultNode(sink)

proc defaultSource*(): AudioNode {.raises: [ControlError].} =
  sources().defaultNode(source)

proc kindPrefix(node: AudioNode): string =
  if node.kind == sink: "sink" else: "source"

proc setVolume*(node: AudioNode, percent: int) {.raises: [ControlError].} =
  discard runOk("pactl", @["set-" & node.kindPrefix & "-volume", node.name,
                           $clamp(percent, 0, 100) & "%"])

proc nudgeVolume*(node: AudioNode, step: int) {.raises: [ControlError].} =
  discard runOk("pactl", @["set-" & node.kindPrefix & "-volume", node.name,
                           (if step >= 0: "+" else: "") & $step & "%"])

proc setMuted*(node: AudioNode, muted: bool) {.raises: [ControlError].} =
  discard runOk("pactl", @["set-" & node.kindPrefix & "-mute", node.name,
                           $ord(muted)])

proc toggleMuted*(node: AudioNode): bool {.raises: [ControlError].} =
  discard runOk("pactl", @["set-" & node.kindPrefix & "-mute", node.name,
                           "toggle"])
  runOk("pactl", @["get-" & node.kindPrefix & "-mute", node.name])
    .fieldValue("Mute") == "yes"

proc setPreferred*(node: AudioNode) {.raises: [ControlError].} =
  discard runOk("pactl", @["set-default-" & $node.kind, node.name])

## --- wifi -----------------------------------------------------------------------

proc wifiEnabled*(): bool {.raises: [ControlError].} =
  runOk("nmcli", @["radio", "wifi"]) == "enabled"

proc setWifiEnabled*(enabled: bool) {.raises: [ControlError].} =
  discard runOk("nmcli", @["radio", "wifi", if enabled: "on" else: "off"])

proc splitEscaped(line: string): seq[string] =
  var field = ""
  var i = 0
  while i < line.len:
    if line[i] == '\\' and i + 1 < line.len:
      field.add line[i + 1]
      inc i, 2
    elif line[i] == ':':
      result.add field
      field = ""
      inc i
    else:
      field.add line[i]
      inc i
  result.add field

proc number(text: string): int =
  text.digitsValue()

proc wifiNetworks*(rescan = false): seq[WifiNetwork] {.
    raises: [ControlError].} =
  let args = @["-t", "-f", "SSID,SIGNAL,IN-USE", "device", "wifi", "list"] &
    (if rescan: @[] else: @["--rescan", "no"])
  for line in runOk("nmcli", args).splitLines():
    let parts = line.splitEscaped()
    if parts.len < 3 or parts[0].len == 0:
      continue
    var known = false
    for network in result.mitems:
      if network.ssid != parts[0]: continue
      known = true
      let signal = parts[1].number()
      if signal > network.signal: network.signal = signal
      if parts[2] == "*": network.connected = true
    if not known:
      result.add WifiNetwork(ssid: parts[0], signal: parts[1].number(),
                             connected: parts[2] == "*")

proc connectWifi*(ssid: string) {.raises: [ControlError].} =
  discard runOk("nmcli", @["device", "wifi", "connect", ssid])

## --- wired ----------------------------------------------------------------------

proc wiredConnection*(): WiredConnection {.raises: [ControlError].} =
  for line in runOk("nmcli", @["-t", "-f", "DEVICE,TYPE,STATE,CONNECTION",
                               "device"]).splitLines():
    let parts = line.splitEscaped()
    if parts.len >= 2 and parts[1] == "ethernet":
      result.device = parts[0]
      if parts.len >= 3 and parts[2] == "connected" and parts.len >= 4:
        result.name = parts[3]
      return

proc setWiredEnabled*(enabled: bool) {.raises: [ControlError].} =
  let connection = wiredConnection()
  if connection.device.len == 0:
    raise newException(ControlError, "No wired device found")
  discard runOk("nmcli", @["device", if enabled: "connect" else: "disconnect",
                           connection.device])

## --- bluetooth --------------------------------------------------------------------

proc bluetoothCtl(args: seq[string]): string {.raises: [ControlError].} =
  runOk("bluetoothctl", @["--timeout", "5"] & args)

proc bluetoothAvailable*(): bool =
  # 'busctl is-active' is not a busctl verb (it silently exits non-zero with
  # "Unknown command verb", so the daemon looked dead even while running):
  # Ping the org.bluez name on the system bus instead - exit 0 means the
  # bluetoothd owns the name bluetoothctl talks to. A failed D-Bus
  # activation (no daemon, no unit) also lands here as non-zero.
  let r = try: capture("busctl", @["--system", "--timeout=5", "call",
                                   "org.bluez", "/org/bluez",
                                   "org.freedesktop.DBus.Peer", "Ping"])
        except ControlError: (output: "", code: 1)
  r.code == 0

proc bluetoothEnabled*(): bool {.raises: [ControlError].} =
  bluetoothAvailable() and bluetoothCtl(@["show"]).fieldValue("Powered") == "yes"

proc setBluetoothEnabled*(enabled: bool) {.raises: [ControlError].} =
  if not bluetoothAvailable():
    raise newException(ControlError, "Bluetooth daemon is not running")
  discard bluetoothCtl(@["power", if enabled: "on" else: "off"])

proc parseDevice(line: string): BluetoothDevice =
  let parts = line.split(maxSplit = 2)
  if parts.len < 2 or parts[0] != "Device":
    return
  result.address = parts[1]
  result.name = if parts.len > 2: parts[2] else: parts[1]
  result.battery = -1

proc bluetoothDevices*(): seq[BluetoothDevice] {.raises: [ControlError].} =
  if not bluetoothAvailable():
    raise newException(ControlError, "Bluetooth daemon is not running")
  for line in bluetoothCtl(@["devices"]).splitLines():
    let device = line.parseDevice()
    if device.address.len == 0:
      continue
    let info = bluetoothCtl(@["info", device.address])
    result.add BluetoothDevice(
      address: device.address,
      name: device.name,
      connected: info.fieldValue("Connected") == "yes",
      battery: info.fieldValue("Battery Percentage").percent())

proc connectBluetooth*(address: string) {.raises: [ControlError].} =
  discard bluetoothCtl(@["connect", address])

proc disconnectBluetooth*(address: string) {.raises: [ControlError].} =
  discard bluetoothCtl(@["disconnect", address])
