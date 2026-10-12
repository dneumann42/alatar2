# ============================================================================
# Rendering: assemble the per-second i3bar JSON array from the collectors.
# Field widths are fixed via min_width (px) + align, so blocks never resize
# as values change.
# ============================================================================

import std/[strutils, times, math]
import ./palette, ./util, ./collectors

proc emit*(wxTemp, wxIconChar: string) =
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
