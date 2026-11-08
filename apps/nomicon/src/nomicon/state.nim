import alatar/controls

type
  Panel* = enum
    panelNone, panelWifi, panelWired, panelBluetooth, panelPower,
    panelOutput, panelInput, panelBackground

  PowerMode* = enum
    pmBalanced, pmSaver, pmPerformance

  State* = ref object
    sinks*: seq[AudioNode]
    sources*: seq[AudioNode]
    networks*: seq[WifiNetwork]
    btDevices*: seq[BluetoothDevice]
    outputs*: seq[DisplayOutput]
    wiredDevice*: string
    wiredName*: string
    wifiOn*: bool
    wiredOn*: bool
    btOn*: bool
    btAvailable*: bool
    airplane*: bool
    nightLight*: bool
    darkStyle*: bool
    monitorName*: string
    monitorOn*: bool
    primaryName*: string
    backlight*: int
    powerMode*: PowerMode
    powerWas*: PowerMode
    brightness*: int
    volumeUi*: int
    micUi*: int
    panel*: Panel
    note*: string
    background*: seq[string]

func newState*(): State =
  State(
    darkStyle: true,
    powerMode: pmBalanced, powerWas: pmBalanced,
    brightness: 60, volumeUi: 50, micUi: 50,
    background: @["Discord", "Syncthing", "Flameshot"])

func defaultNode(nodes: seq[AudioNode]): AudioNode =
  for node in nodes:
    if node.preferred:
      return node
  if nodes.len > 0: nodes[0] else: AudioNode()

func defaultSink*(s: State): AudioNode =
  s.sinks.defaultNode()

func defaultSource*(s: State): AudioNode =
  s.sources.defaultNode()

func connected*(s: State): bool =
  s.wifiOn or s.btOn or s.wiredOn

func powerLabel*(mode: PowerMode): string =
  case mode
  of pmBalanced: "Balanced"
  of pmSaver: "Power Saver"
  of pmPerformance: "Performance"

func backlightLabel*(s: State): string =
  ["Off", "Low", "High"][s.backlight]

func connectedSsid*(s: State): string =
  for network in s.networks:
    if network.connected:
      return network.ssid
  ""

func wifiSubtitle*(s: State): string =
  if not s.wifiOn: "Off"
  else:
    let ssid = s.connectedSsid
    if ssid.len > 0: ssid else: "Not Connected"

func wiredSubtitle*(s: State): string =
  if s.wiredOn and s.wiredName.len > 0: s.wiredName else: "Off"

func btSubtitle*(s: State): string =
  if not s.btAvailable: "Unavailable"
  elif not s.btOn: "Off"
  else:
    var names = 0
    var first = ""
    for d in s.btDevices:
      if d.connected:
        if first.len == 0: first = d.name
        inc names
    if names == 0: "No Devices"
    elif names == 1: first
    else: $names & " Devices"

## Logical (post-transform) portrait size identifies the vertical monitor;
## a powered-off output reports a 0x0 rect, so callers must fall back to the
## remembered connector name or the sway config transform scan.
func portraitOutputName*(outputs: seq[DisplayOutput]): string =
  for o in outputs:
    if o.active and o.height > o.width:
      return o.name
  ""

## Single mode keeps only this output up: the largest live landscape monitor
## (the 32"), which also stays XRandR monitor 0 for Steam games.
func primaryOutputName*(outputs: seq[DisplayOutput]): string =
  var best = 0
  for o in outputs:
    if o.active and o.width >= o.height and o.width * o.height > best:
      best = o.width * o.height
      result = o.name

func monitorSubtitle*(s: State): string =
  if s.monitorName.len == 0: "Not Found"
  elif s.monitorOn: "Dual"
  else: "Single"

func nodeSubtitle(node: AudioNode): string =
  if node.name.len == 0: "No Device"
  elif node.muted: "Muted"
  else: $node.volume & "%"

func sinkSubtitle*(s: State): string =
  nodeSubtitle(s.defaultSink())

func micSubtitle*(s: State): string =
  nodeSubtitle(s.defaultSource())

func signalLabel*(signal: int): string =
  if signal >= 75: "Excellent"
  elif signal >= 50: "Good"
  elif signal >= 25: "Fair"
  else: "Weak"
