# ============================================================================
# Click handling: swaybar click events arrive on stdin, are forwarded by a
# reader thread over clickChan, and mapped to actions here.
#
#   media     left  open/focus Strawberry (flatpak, floats via window-rules)
#             right play/pause      wheel  previous / next
#   date      left  open/focus kitty running calcurse (floats via window-rules)
#   volume    left  mute toggle     wheel  volume down / up
#   bar bg    middle  jump back to previous workspace (bound in bar.conf)
# ============================================================================

import std/[os, strutils, json]
import ./palette, ./util

proc openStrawberry*() =
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

proc openCalcurse*() =
  ## Focus the kitty window running calcurse if it exists, otherwise launch it.
  if findWindow("calcurse"):
    discard sh("swaymsg", "[app_id=\"calcurse\"] focus")
  else:
    spawnDetached("kitty --class calcurse -e calcurse")

# Payload sent over clickChan: one raw swaybar click-event line per message,
# or EOF_MARK when stdin closed (the bar is gone).
const EOF_MARK* = "\1\1"
var clickChan*: Channel[string]

proc clickReader*() {.thread.} =
  var line: string
  while stdin.readLine(line):
    clickChan.send(line)
  clickChan.send(EOF_MARK)

proc handleClick*(line: string): bool =
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
