# ============================================================================
# System-state collectors: cpu, memory, temperatures, GPU, network, volume,
# media. Each keeps its own cache/delta state privately; all are safe to call
# every second (slower sources are polled on their own intervals).
# ============================================================================

import std/[os, strutils, times, algorithm, math]
import std/unicode except splitWhitespace
import ./util

var
  havePrevCpu = false
  prevIdle, prevTotal: uint64

proc cpuPct*(): uint64 =
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

proc memStats*(): (bool, float, float) =
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

proc cpuTemp*(): string =
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

proc gpuStats*(): (string, string) =
  let now = getTime().toUnixFloat()
  if now - gpuTs >= 5:
    let outp = sh("nvidia-smi",
                  "--query-gpu=temperature.gpu,utilization.gpu",
                  "--format=csv,noheader,nounits")
    let (temp, usage) = csvIntPair(outp)
    gpuTempCache = temp
    gpuUtilCache = usage
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

proc netState*(): (string, string) =
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

proc volState*(): (bool, string) =
  ## Returns (muted, pct); pct is "" when no sink exists.
  # pulse outputs "Muted: yes"; pipewire's pactl wrapper says "Mute: yes"
  let muted = sh("pactl", "get-sink-mute", "@DEFAULT_SINK@").endsWith("yes")
  let pct = percentValue(sh("pactl", "get-sink-volume", "@DEFAULT_SINK@"))
  (muted, pct)

proc mediaState*(): (bool, bool, string) =
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
