import std/[json, os, osproc, sequtils, streams, strutils]

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

  DisplayOutput* = object
    name*: string
    active*: bool
    power*: bool
    x*, y*, width*, height*: int
    transform*: string

proc capture(command: string; args: seq[string]): tuple[output: string, code: int] =
  try:
    let p = startProcess(command = command, args = args,
                         options = {poUsePath, poStderrToStdout})
    result.output = p.outputStream.readAll().strip()
    result.code = p.waitForExit()
    close(p)
  except CatchableError as e:
    raise newException(ControlError, "Failed to run '" & command & "': " & e.msg, e)

proc runOk(command: string; args: seq[string]): string {.raises: [ControlError].} =
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
  let r = try: capture("busctl", @["--system", "is-active", "org.bluez"])
        except ControlError: (output: "", code: 1)
  r.code == 0 and r.output == "active"

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

## --- display ----------------------------------------------------------------------

func jsonField(o: JsonNode, key: string): JsonNode =
  if o.kind == JObject:
    for k, v in o.pairs:
      if k == key:
        return v
  nil

func jStr(o: JsonNode, key: string): string =
  let v = o.jsonField(key)
  if v != nil and v.kind == JString: v.str else: ""

func jBool(o: JsonNode, key: string): bool =
  let v = o.jsonField(key)
  v != nil and v.kind == JBool and v.bval

func jInt(o: JsonNode, key: string): int =
  let v = o.jsonField(key)
  if v != nil and v.kind == JInt: int(v.num) else: 0

proc parseSwayJson(raw: string): JsonNode {.raises: [ControlError].} =
  try:
    result = parseJson(raw)
  except CatchableError as e:
    raise newException(ControlError, "swaymsg returned invalid JSON: " & e.msg, e)

proc swayOutputs*(): seq[DisplayOutput] {.raises: [ControlError].} =
  let tree = parseSwayJson(runOk("swaymsg", @["-t", "get_outputs"]))
  if tree.kind != JArray:
    raise newException(ControlError, "swaymsg get_outputs: expected a JSON array")
  for o in tree:
    let name = o.jStr("name")
    if name.len == 0 or o.jBool("non_desktop"):
      continue
    let rect = o.jsonField("rect")
    result.add DisplayOutput(
      name: name,
      active: o.jBool("active"),
      power: o.jBool("power"),
      x: if rect != nil: rect.jInt("x") else: 0,
      y: if rect != nil: rect.jInt("y") else: 0,
      width: if rect != nil: rect.jInt("width") else: 0,
      height: if rect != nil: rect.jInt("height") else: 0,
      transform: o.jStr("transform"))

proc swayConfig*(): string {.raises: [ControlError].} =
  parseSwayJson(runOk("swaymsg", @["-t", "get_config"])).jStr("config")

## Quoting the name keeps connector identifiers with spaces intact; sway
## output names never contain quotes themselves.
proc setOutputEnabled*(name: string, enabled: bool) {.raises: [ControlError].} =
  discard runOk("swaymsg",
    @["output \"" & name & "\" " & (if enabled: "enable" else: "disable")])

## The sway config directory, where the user's keybinding scripts live.
proc swayConfigDir(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".config") / "sway"

func swayScriptsDir*(): string =
  swayConfigDir() / "scripts"

## Runs a script from ~/.config/sway/scripts the way the keybinding that
## calls it does: through sway's own `exec`, so it inherits the compositor
## environment instead of whatever the calling app happens to have.
## `set-wallpaper.sh` is the wallpaper switcher bound to Shift+Mod4+w.
proc swayExecScript*(name: string) {.raises: [ControlError].} =
  let path = swayScriptsDir() / name
  if not fileExists(path):
    raise newException(ControlError, "Missing sway script: " & path)
  discard runOk("swaymsg", @["exec " & path])

## A disabled output reports a 0x0 rect and drops its transform, so after a
## `sway reload` or a nomicon toggle the portrait screen cannot be recognized
## from get_outputs alone. swaymsg -t get_config only returns the top-level
## file (includes are not expanded), so scan the sway config directory for
## `output <name> ... transform <90|270>` instead: the vertical monitor is
## the one sway physically rotates. (swayConfigDir is defined above.)
func isPortraitTransform(value: string): bool =
  value in ["90", "270", "flipped-90", "flipped-270"]

func rotatedNameInLine(line: string): string =
  let toks = line.strip().split(maxSplit = 1)
  if toks.len < 2 or toks[0] != "output":
    return ""
  var words: seq[string] = @[]
  var rest = toks[1]
  var quoted = false
  var value = ""
  for c in rest:
    if c == '"':
      quoted = not quoted
    elif c == ' ' and not quoted:
      if value.len > 0:
        words.add value
        value = ""
    else:
      value.add c
  if value.len > 0:
    words.add value
  if words.len < 2:
    return ""
  var i = 1
  while i < words.len:
    if words[i] == "transform" and i + 1 < words.len and
        words[i + 1].isPortraitTransform():
      return words[0]
    inc i
  ""

proc rotatedOutputNames*(): seq[string] =
  let dir = swayConfigDir()
  if not dirExists(dir):
    return @[]
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    let text = try: readFile(path) except CatchableError: continue
    for line in text.splitLines():
      let name = line.rotatedNameInLine()
      if name.len > 0 and name notin result:
        result.add name
