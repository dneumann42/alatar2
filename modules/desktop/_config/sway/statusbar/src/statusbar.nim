# ============================================================================
# Swaybar status line — i3bar/sway JSON protocol with click support.
# Nim port of the former scripts/status.tcl.
#
# Modules (statusbar/):
#   palette     colors, Font Awesome glyphs, weather emoji, shared consts
#   util        process/file helpers, pango spans, i3bar block JSON
#   collectors  cpu | temp | gpu | ram | network | volume | media sampling
#   weather     wttr.in fetch thread + channel
#   blocks      per-second render of the full block line
#   clicks      stdin click-event reader thread + action handlers
#
# Threading model (vs. the Tcl original's fileevent loop):
#   main thread   — 50 ms poll loop; emits one JSON array per second and
#                   immediately after click actions / fresh weather data.
#   click reader  — blocks on stdin, forwards click-event lines over a channel.
#   weather       — fetches wttr.in with curl every 10 minutes over a channel,
#                   so a slow endpoint can never stall the 1 s refresh tick.
#
# 12-hour clock. After editing: swaymsg reload
# ============================================================================

import std/[os, times, strutils, terminal]
import statusbar/[blocks, clicks, collectors, weather]

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
