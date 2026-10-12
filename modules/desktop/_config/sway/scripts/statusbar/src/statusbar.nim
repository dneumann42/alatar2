# ============================================================================
# Swaybar status line — i3bar/sway JSON protocol with click support.
# Nim port of the former scripts/status.tcl.
#
# Modules:  media | cpu | temp | gpu | ram | network | volume | date | clock
# Icons are Font Awesome 5 glyphs (present in the AtkynsonMono Nerd Font the
# bar uses). Colors mirror appearance.conf. Field widths are fixed via
# min_width (px) + align, so blocks never resize as values change.
#
# Clicks:
#   media     left  open/focus Strawberry (flatpak, floats via window-rules)
#             right play/pause      wheel  previous / next
#   date      left  open/focus kitty running calcurse (floats via window-rules)
#   volume    left  mute toggle     wheel  volume down / up
#   bar bg    middle  jump back to previous workspace (bound in bar.conf)
#
# 12-hour clock. After editing: swaymsg reload
#
# Threading model (vs. the Tcl original's fileevent loop):
#   main thread   — 50 ms poll loop; emits one JSON array per second and
#                   immediately after click actions / fresh weather data.
#   click reader  — blocks on stdin, forwards click-event lines over a channel.
#   weather       — fetches wttr.in with curl every 10 minutes over a channel,
#                   so a slow endpoint can never stall the 1 s refresh tick.
# ============================================================================

import std/[os, osproc, strutils, times, json, math, re, algorithm, terminal]
import std/unicode except splitWhitespace

# ---- palette (keep in sync with appearance.conf) ----
const
  cAccent  = "#89b4fa"
  cAccent2 = "#74c7ec"
  cUrgent  = "#f38ba8"
  cText    = "#e6eaf2"
  cMuted   = "#9aa4b2"

# ---- Font Awesome 5 solid glyphs ----
const
  gPlay     = "\uF04B"
  gPause    = "\uF04C"
  gClock    = "\uF017"
  gCalendar = "\uF073"
  gWired    = "\uF0C1"
  gWifi     = "\uF1EB"
  gOffline  = "\uF127"
  gCpu      = "\uF4BC"
  gRam      = "\uF2DB"
  gTemp     = "\uF2C9"
  gGpu      = "\uF06D"
  gVoff     = "\uF026"
  gVlow     = "\uF027"
  gVhigh    = "\uF028"

# ---- weather emoji (rendered by Noto Color Emoji via pango fallback) ----
# NB: literal UTF-8, not \U escapes — Nim's \U takes only 4 hex digits, so
# "\U0001F324" would compile to 0x0001 followed by literal "F324".
const
  gSun    = "🌞"      # clear
  gPartly = "🌤️"  # sun behind small cloud
  gCloud  = "☁️"      # overcast
  gRain   = "🌧️"  # rain
  gSnow   = "🌨️"  # snow
  gStorm  = "🌩️"  # thunder
  gFog    = "🌫️"  # fog/mist

const DEGREE = "\u00B0"

const strawberryId = "org.strawberrymusicplayer.strawberry"

# ---------------------------------------------------------------- helpers --

proc readOrEmpty(path: string): string =
  ## File contents, or "" when the path is unreadable.
  try: readFile(path) except CatchableError: ""

proc sh(cmd: string, args: varargs[string]): string =
  ## Run a command (no shell: argv passed verbatim), return stdout trimmed;
  ## empty string on any failure. Mirrors the Tcl original's `exec`.
  let exe = findExe(cmd)
  if exe.len == 0: return ""
  try:
    result = execProcess(exe, args = args, options = {}).strip()
  except CatchableError:
    result = ""

proc spawnDetached(cmd: string) =
  ## Fire-and-forget a command (GUI launches) with its stdio nowhere.
  try:
    let p = startProcess(findExe("sh"), args = ["-c", cmd & " >/dev/null 2>&1 & disown"],
                         options = {})
    p.close()   # waits only for the quick-exiting `sh` wrapper
  except CatchableError:
    discard

proc span(color, body: string): string =
  "<span color=\"" & color & "\">" & body & "</span>"

proc xmlEscape(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc jsonEscape(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"' : result.add "\\\""
    of '\n', '\r', '\t': result.add ' '
    else: result.add c

proc i3block(name, fullText: string, minWidth = 0, align = "center"): string =
  # Icon-to-value spacing is a single space in every block; width stability
  # comes from min_width (px) + align, so short values don't shift layout.
  result = "{\"name\":\"" & name & "\",\"instance\":\"" & name &
           "\",\"markup\":\"pango\",\"full_text\":\"" & jsonEscape(fullText) & "\""
  if minWidth > 0:
    result.add ",\"min_width\":" & $minWidth & ",\"align\":\"" & align & "\""
  result.add "}"

proc truncate(s: string, n: int): string =
  ## Cut to exactly n codepoints, using '...' when shortened.
  let rs = toRunes(s)
  if rs.len > n: $(rs[0 .. n - 4]) & "..." else: s

# ------------------------------------------------------------- collectors --

var
  havePrevCpu = false
  prevIdle, prevTotal: uint64

proc cpuPct(): uint64 =
  let line = try: readOrEmpty("/proc/stat").splitLines[0] except CatchableError: ""
  let f = line.splitWhitespace()
  if f.len < 9 or f[0] != "cpu": return 0
  # cpu user nice system idle iowait irq softirq steal guest...
  try:
    let
      u    = parseBiggestUInt(f[1])
      n    = parseBiggestUInt(f[2])
      s    = parseBiggestUInt(f[3])
      idle = parseBiggestUInt(f[4])
      io   = parseBiggestUInt(f[5])
      irq  = parseBiggestUInt(f[6])
      sirq = parseBiggestUInt(f[7])
      st   = parseBiggestUInt(f[8])
      idleSum = idle + io
      total   = u + n + s + idle + io + irq + sirq + st
    result = 0
    if havePrevCpu and total > prevTotal:
      let
        di = if idleSum >= prevIdle: float(idleSum - prevIdle) else: 0.0
        dt = float(total - prevTotal)
      var pct = round(100.0 * (1.0 - di / dt))
      if pct < 0: pct = 0
      if pct > 100: pct = 100
      result = pct.uint64
    prevIdle = idleSum
    prevTotal = total
    havePrevCpu = true
  except ValueError:
    result = 0

proc memStats(): (bool, float, float) =
  ## (ok, used_gb, total_gb)
  var memTotal, memAvail = -1'i64
  for line in readOrEmpty("/proc/meminfo").splitLines:
    let f = line.splitWhitespace
    if f.len >= 2:
      let key = f[0].strip(chars = {':'})
      case key
      of "MemTotal":     memTotal = try: f[1].parseInt except ValueError: -1
      of "MemAvailable": memAvail = try: f[1].parseInt except ValueError: -1
  if memTotal < 0 or memAvail < 0: return (false, 0, 0)
  (true, (memTotal - memAvail).float / 1048576.0, memTotal.float / 1048576.0)

proc cpuTemp(): string =
  ## Hot of the CPU package (k10temp on AMD, coretemp on Intel).
  for k in walkDir("/sys/class/hwmon"):
    let nf = k.path / "name"
    if k.kind in [pcDir, pcLinkToDir] and fileExists(nf) and
       readOrEmpty(nf).strip() in ["k10temp", "coretemp", "zenpower"]:
      let v = readOrEmpty(k.path / "temp1_input").strip()
      if v.len > 0:
        try: return $round(parseFloat(v) / 1000.0).int except ValueError: discard
  ""

# nvidia-smi is comparatively slow — poll at most every 5 seconds.
var
  gpuTs = -100.0
  gpuTempCache, gpuUtilCache: string

proc gpuStats(): (string, string) =
  let now = getTime().toUnixFloat()
  if now - gpuTs >= 5:
    let outp = sh("nvidia-smi",
                  "--query-gpu=temperature.gpu,utilization.gpu",
                  "--format=csv,noheader,nounits")
    var mm: array[2, string]
    if find(outp, re"(\d+)\s*,\s*(\d+)", mm) >= 0:
      gpuTempCache = mm[0]
      gpuUtilCache = mm[1]
    else:
      gpuTempCache = ""
      gpuUtilCache = ""
    gpuTs = now
  (gpuTempCache, gpuUtilCache)

# nmcli SSID lookups are cached for 15 seconds.
var
  ssidTs = -100.0
  ssidCache: string

proc wifiSsid(): string =
  let now = getTime().toUnixFloat()
  if now - ssidTs >= 15:
    ssidCache = ""
    for line in sh("nmcli", "-t", "-f", "active,ssid", "dev", "wifi").splitLines:
      if line.startsWith("yes:"):
        ssidCache = line[4 .. ^1]
        break
    ssidTs = now
  ssidCache

proc netState(): (string, string) =
  ## Returns (kind, label). kind: wired | wifi | none
  var devs: seq[string]
  for k in walkDir("/sys/class/net"):
    if k.kind in [pcFile, pcDir, pcLinkToFile, pcLinkToDir]:
      devs.add k.path.splitPath().tail
  devs.sort()
  for d in devs:
    if d == "lo": continue
    if d.startsWith("virbr") or d.startsWith("docker") or d.startsWith("br-") or
       d.startsWith("veth") or d.startsWith("tun") or d.startsWith("tap"): continue
    let p = "/sys/class/net/" & d
    if readOrEmpty(p / "operstate").strip() == "up" and
       readOrEmpty(p / "carrier").strip() == "1":
      if dirExists(p / "wireless") or fileExists(p / "wireless"):
        var ssid = wifiSsid()
        if ssid.len == 0: ssid = d.toUpper()
        return ("wifi", ssid)
      return ("wired", "ETH")
  ("none", "")

proc volState(): (bool, string) =
  ## Returns (muted, pct); pct is "" when no sink exists.
  # pulse outputs "Muted: yes"; pipewire's pactl wrapper says "Mute: yes"
  let muted = sh("pactl", "get-sink-mute", "@DEFAULT_SINK@").endsWith("yes")
  var pct = ""
  var mm: array[1, string]
  if find(sh("pactl", "get-sink-volume", "@DEFAULT_SINK@"), re"(\d+)%", mm) >= 0:
    pct = mm[0]
  (muted, pct)

proc mediaState(): (bool, bool, string) =
  ## Returns (found, playing, label).
  ## playerctl template: {{status}} {{artist}} {{title}}, tab-separated
  let fmt = "{{status}}\t{{artist}}\t{{title}}"
  let outp = sh("playerctl", "-a", "metadata", "-f", fmt)
  var playingLine, pausedLine: string
  for line in outp.splitLines:
    if playingLine.len == 0 and line.startsWith("Playing\t"): playingLine = line
    if pausedLine.len == 0 and line.startsWith("Paused\t"):   pausedLine = line
  let (line, isPlaying) =
    if playingLine.len > 0: (playingLine, true)
    elif pausedLine.len > 0: (pausedLine, false)
    else: return (false, false, "")
  let parts = line.split('\t')
  let artist = if parts.len > 1: parts[1].strip() else: ""
  let title  = if parts.len > 2: parts[2].strip() else: ""
  if title.len == 0: return (false, false, "")
  let label = if artist.len == 0: title else: artist & " \u2014 " & title
  (true, isPlaying, label)

# ------------------------------------------------------------------ weather --
# wttr.in, re-fetched every 10 minutes (be polite to the public service).
# Location is pinned by coordinates (Walla Walla, WA) — without them wttr.in
# guesses from IP geolocation and lands on Kennewick instead. Last good data
# is kept on failure; the next attempt is still 10 min after this one.

const
  wxUrl = "https://wttr.in/46.0646,-118.3430?format=j1"
  wxIntervalMs = 10 * 60 * 1000

proc wxIcon(code: string): string =
  ## WMO-style weather codes as reported by wttr.in
  case code
  of "113": gSun
  of "116": gPartly
  of "119", "122": gCloud
  of "143", "248": gFog
  of "176", "263", "266", "269", "272", "275", "278", "281", "284", "293",
     "296", "299", "302", "305", "308", "311", "314", "317", "320", "353",
     "356", "359", "362", "368": gRain
  of "179", "225", "227", "230", "329", "332", "335", "338", "350", "365",
     "367": gSnow
  of "200", "386", "389", "392", "395", "398": gStorm
  else: gCloud

# Payload sent over wxChan: "tempF<TAB>icon".
var wxChan: Channel[string]

proc wxWorker() {.thread.} =
  while true:
    try:
      let outp = execProcess(findExe("curl"),
                             args = ["-s", "--max-time", "8", wxUrl], options = {})
      if outp.len > 0:
        let j = outp.parseJson()
        let cur = j["current_condition"][0]
        let temp = cur["temp_F"].getStr("")
        let icon = wxIcon(cur["weatherCode"].getStr(""))
        if temp.len > 0:
          wxChan.send(temp & "\t" & icon)
    except CatchableError:
      discard
    sleep(wxIntervalMs)

# ------------------------------------------------------------------ emit --

proc emit(wxTemp, wxIconChar: string) =
  var blocks: seq[string]

  let (mdOk, playing, label) = mediaState()
  if mdOk:
    let (glyph, icol, lcol) =
      if playing: (gPlay, cAccent, cText)
      else: (gPause, cMuted, cMuted)
    blocks.add i3block("media",
      span(icol, glyph) & " " & span(lcol, xmlEscape(truncate(label, 40))), 384, "left")

  blocks.add i3block("cpu",
    span(cAccent2, gCpu) & " " & span(cText, $cpuPct() & "%"), 64)

  let t = cpuTemp()
  if t.len > 0:
    let col = if t.parseInt >= 75: cUrgent else: cText
    blocks.add i3block("temp", span(cAccent2, gTemp) & " " & span(col, t & DEGREE), 64)

  let (gtemp, gutil) = gpuStats()
  if gtemp.len > 0:
    let col = if gtemp.parseInt >= 80: cUrgent else: cText
    blocks.add i3block("gpu",
      span(cAccent2, gGpu) & " " & span(col, gtemp & DEGREE) &
      " " & span(cMuted, gutil & "%"), 108)

  let (memOk, used, total) = memStats()
  if memOk:
    blocks.add i3block("memory",
      span(cAccent2, gRam) & " " & span(cText, formatFloat(used, ffDecimal, 1) & "G") &
      span(cMuted, "/" & $int(round(total)) & "G"), 104)

  let (kind, netLabel) = netState()
  case kind
  of "wired":
    blocks.add i3block("network", span(cAccent2, gWired) & " " & span(cMuted, netLabel), 76)
  of "wifi":
    blocks.add i3block("network",
      span(cAccent2, gWifi) & " " & span(cMuted, xmlEscape(truncate(netLabel, 12))), 124)
  else:
    blocks.add i3block("network",
      span(cUrgent, gOffline) & " " & span(cUrgent, "offline"), 100)

  let (muted, pct) = volState()
  if muted:
    blocks.add i3block("volume", span(cUrgent, gVoff) & " " & span(cUrgent, "MUTE"), 72)
  elif pct.len == 0:
    blocks.add i3block("volume", span(cMuted, gVoff) & " " & span(cMuted, "--"), 72)
  else:
    let gi = if pct.parseInt < 40: gVlow else: gVhigh
    blocks.add i3block("volume", span(cAccent2, gi) & " " & span(cText, pct & "%"), 72)

  if wxTemp.len > 0:
    blocks.add i3block("weather",
      span(cAccent2, wxIconChar) & " " & span(cText, wxTemp & DEGREE) & "F", 72)

  let nowT = getTime()
  let dateStr = nowT.format("ddd MMM dd")     # %a %b %d
  var timeStr = nowT.format("hh:mm tt")       # %I:%M %p, 12-hour, English AM/PM
  if timeStr.startsWith("0"): timeStr = timeStr[1 .. ^1]   # 09:12 -> 9:12

  blocks.add i3block("date", span(cMuted, gCalendar) & " " & span(cMuted, dateStr), 124)
  blocks.add i3block("clock",
    span(cAccent, gClock) & " <b>" & span(cText, timeStr) & "</b>", 104)

  try:
    stdout.write("[" & blocks.join(",") & "],\n")
    stdout.flushFile()
  except CatchableError:
    quit 0   # the bar went away

# ----------------------------------------------------------------- clicks --

proc findWindow(appId: string): bool =
  ## True when a window with this app_id exists.
  let tree = sh("swaymsg", "-t", "get_tree")
  tree.contains("{\"app_id\":\"" & appId & "\"}") or
    tree.contains("{\"app_id\": \"" & appId & "\"}")

proc openStrawberry() =
  ## Focus the Strawberry window if it exists, otherwise launch it.
  ## Both the pacman and flatpak builds report the Wayland app_id
  ## org.strawberrymusicplayer.strawberry (Qt reads it from the desktop
  ## file); the bare "strawberry" is matched too as a fallback. Strawberry
  ## is single-instance, so a second launch only raises the existing window
  ## anyway; focusing is faster and quieter.
  for id in ["strawberry", strawberryId]:
    if findWindow(id):
      discard sh("swaymsg", "[app_id=\"" & id & "\"] focus")
      return
  if findExe("strawberry").len > 0:
    spawnDetached("strawberry")
  else:
    spawnDetached("flatpak run " & strawberryId)

proc openCalcurse() =
  ## Focus the kitty window running calcurse if it exists, otherwise launch it.
  if findWindow("calcurse"):
    discard sh("swaymsg", "[app_id=\"calcurse\"] focus")
  else:
    spawnDetached("kitty --class calcurse -e calcurse")

# Payload sent over clickChan: one raw swaybar click-event line per message,
# or EOF_MARK when stdin closed (the bar is gone).
const EOF_MARK = "\1\1"
var clickChan: Channel[string]

proc clickReader() {.thread.} =
  var line: string
  while stdin.readLine(line):
    clickChan.send(line)
  clickChan.send(EOF_MARK)

proc handleClick(line: string): bool =
  ## True when something changed and the bar should be redrawn.
  if line == EOF_MARK: quit 0
  var s = line.strip()
  if s.endsWith(","): s = s[0 .. ^2].strip()
  if s.len == 0: return false
  let j = try: s.parseJson() except ValueError, JsonParsingError: return false
  if j.kind != JObject: return false
  let inst = if j.contains("instance"): j["instance"].getStr("") else: ""
  let btn  = if j.contains("button"):  j["button"].getInt(0)        else: 0
  case inst
  of "media":
    case btn
    of 1: openStrawberry()
    of 3: discard sh("playerctl", "play-pause")
    of 4: discard sh("playerctl", "next")
    of 5: discard sh("playerctl", "previous")
    else: discard
    result = true
  of "date":
    if btn == 1: openCalcurse()
    result = true
  of "volume":
    case btn
    of 1: discard sh("pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle")
    of 4: discard sh("pactl", "set-sink-volume", "@DEFAULT_SINK@", "+5%")
    of 5: discard sh("pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%")
    else: discard
    result = true
  else:
    result = false

# ------------------------------------------------------------------- main --

when isMainModule:
  clickChan.open()
  wxChan.open()

  discard cpuPct()   # prime the delta so the first real tick has a number

  # NOTE: swaybar only switches to the i3bar JSON protocol when the header
  # contains "version":1 — without it, it silently falls back to text mode.
  stdout.write("{\"version\":1,\"click_events\":true}\n[\n")
  # The stream after the header is one unbounded JSON array: emit the opening
  # bracket, then one update array per line, each terminated by a comma.
  try: stdout.flushFile() except CatchableError: quit 0

  var tWx: Thread[void]
  createThread(tWx, wxWorker)

  var tClick: Thread[void]
  let wantClicks = not stdin.isatty
  if wantClicks:
    createThread(tClick, clickReader)

  var
    wxT, wxI: string
    lastEmit = 0.0
    first = true

  while true:
    var redraw = first   # first pass emits the initial frame right now
    first = false
    if wantClicks:
      while clickChan.peek() > 0:
        if handleClick(clickChan.recv()): redraw = true
    while wxChan.peek() > 0:
      let v = wxChan.recv()
      let parts = v.split('\t')
      if parts.len == 2:
        wxT = parts[0]; wxI = parts[1]
        redraw = true
    let now = getTime().toUnixFloat()
    if redraw or now - lastEmit >= 1.0:
      emit(wxT, wxI)
      lastEmit = now
    sleep(50)
