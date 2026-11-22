## The status line: the same `statusbar` binary swaybar drove, now spawned
## as a child whose stdout (the i3bar JSON stream) and stdin (click events)
## the bar wires up directly. stdout is read non-blocking from the frame
## loop, so the protocol's own rhythm - header, `[\n` resets, one update
## array per line - survives untouched; clicks are synthesised in the exact
## swaybar shape (block-relative x/y) so clicks.nim's handlers behave.
##
## `full_text` is pango markup (tray of `<span color>`, `<b>`, entities):
## a deliberately small parser turns it into styled runs. `<b>` maps to the
## renderer's MonoFont slot, which bar.nim points at the Nerd Font's bold
## face; weather emoji get Nerd Font equivalents (the kit renders one font
## per run, no pango fallback chain).

import std/[os, strutils, json, posix]
import ellipse_ui
import ./palette
import "../../../../modules/desktop/_config/sway/statusbar/src/statusbar/palette" as statusColors

{.push gcsafe.}

type
  Run* = object
    text*: string
    color*: Color
    bold*: bool

  Block* = ref object
    name*, instance*, fullText*: string
    minWidth*: int
    align*: string        ## "left" | "center" | "right"
    runs*: seq[Run]       ## parsed lazily per frame; cheap for 12 blocks

  StatusLine* = ref object
    pid: cint           ## the statusbar child (-1 when none)
    outFd, inFd: cint   ## our ends of its stdout/stdin pipes
    rbuf: string        ## undivided stdout tail
    blocks*: seq[Block]

const
  maxDrain = 65536

proc pipeC(fds: ptr array[2, cint]): cint {.
  importc: "pipe", header: "<unistd.h>", sideEffect.}
proc dup2C(fd1, fd2: cint): cint {.
  importc: "dup2", header: "<unistd.h>", sideEffect.}
proc forkC(): cint {.
  importc: "fork", header: "<unistd.h>", sideEffect.}
proc execvC(path: cstring, argv: pointer): cint {.
  importc: "execv", header: "<unistd.h>", sideEffect.}
proc exitChild(status: cint) {.
  importc: "_exit", header: "<unistd.h>", noReturn.}

# --- colour + entity helpers --------------------------------------------------

proc spanColor(value: string; p: palette.Palette): Color =
  let fallback = hexColor(value)
  case value
  of statusColors.cAccent: p.get("accent", fallback)
  of statusColors.cAccent2: p.get("accent2", fallback)
  of statusColors.cText: p.get("text", fallback)
  of statusColors.cMuted: p.get("muted", fallback)
  of statusColors.cUrgent: p.get("urgent", fallback)
  else: fallback

proc unescape(s: string): string =
  result = s.replace("&lt;", "<")
  result = result.replace("&gt;", ">")
  result = result.replace("&quot;", "\"")
  result = result.replace("&apos;", "'")
  result = result.replace("&amp;", "&")

# weather emoji (statusbar/palette.nim) -> Font Awesome 5 solid codepoints,
# so they render in the same Nerd Font as everything else.
const
  emojiMap = [
    ("🌞", "\uF185"),   # fa-sun
    ("🌤️", "\uF6C4"),  # fa-cloud-sun
    ("🌦️", "\uF75C"),   # fa-cloud-sun-rain
    ("☁️", "\uF0C2"),    # fa-cloud
    ("🌧️", "\uF73E"),   # fa-cloud-showers-heavy
    ("🌨️", "\uF1DC"),   # fa-snowflake
    ("🌩️", "\uF0E7"),   # fa-bolt
    ("🌫️", "\uF6C3"),   # fa-smog
  ]

proc nerdify*(s: string): string =
  result = s
  for (em, glyph) in emojiMap:
    if em in result: result = result.replace(em, glyph)

# --- pango subset -> runs -----------------------------------------------------

proc parseRuns*(text: string; defCol: Color; p: palette.Palette): seq[Run] =
  var colorStack = @[defCol]
  var cur = defCol
  var bold = 0
  var i = 0
  var lit = ""
  template flush() =
    if lit.len > 0:
      result.add Run(text: lit, color: cur, bold: bold > 0)
      lit = ""
  while i < text.len:
    if text[i] == '<':
      let close = text.find('>', i)
      if close < 0:
        lit.add text[i .. ^1]; break
      let tag = text[i + 1 ..< close]
      flush()
      if tag.len == 0:
        discard
      elif tag[0] == '/':
        case tag[1 .. ^1]
        of "span":
          if colorStack.len > 1:
            colorStack.setLen(colorStack.len - 1)
            cur = colorStack[^1]
        of "b":
          if bold > 0: dec bold
        else: discard
      elif tag == "b":
        inc bold
      elif tag.startsWith("span"):
        var col = cur
        let q = tag.find("color=\"")
        if q >= 0:
          let s = q + 7
          let e = tag.find('"', s)
          if e > s: col = spanColor(tag[s ..< e], p)
        colorStack.add col
        cur = col
      else:
        discard   # unknown tag: ignore the markup, keep the text
      i = close + 1
    else:
      let nxt = text.find('<', i)
      let stop = if nxt < 0: text.len else: nxt
      lit.add unescape(text[i ..< stop])
      i = stop
  flush()

# --- the subprocess -----------------------------------------------------------

proc readStatusbarPath*(): string =
  let base = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  result = base / "sway" / "statusbar" / "bin" / "statusbar"

proc spawn(sl: StatusLine): bool =
  ## fork/exec the status line with two pipes wired to its stdio. The
  ## child path between fork and execv stays async-signal-safe (dup2,
  ## close, execv, _exit): the bar is a GC'd SDL app, so osproc's own
  ## fork dance applies - but we need the raw fds for non-blocking reads.
  let bin = readStatusbarPath()
  if not fileExists(bin): return false
  var outP, inP: array[2, cint]
  if pipeC(addr outP) != 0: return false
  if pipeC(addr inP) != 0:
    discard close(outP[0]); discard close(outP[1])
    return false
  var binC = bin.cstring
  var argv = [binC, cast[cstring](nil)]
  let pid = forkC()
  if pid < 0:
    for f in [outP[0], outP[1], inP[0], inP[1]]: discard close(f)
    return false
  if pid == 0:
    discard dup2C(inP[0], 0)         # child: stdin = our writes (clicks)
    discard dup2C(outP[1], 1)         #        stdout = our reads (JSON)
    discard close(outP[0]); discard close(outP[1])
    discard close(inP[0]); discard close(inP[1])
    discard execvC(binC, addr argv[0])
    exitChild(127)
  sl.pid = pid
  sl.outFd = outP[0]
  sl.inFd = inP[1]
  discard close(outP[1]); discard close(inP[0])
  discard fcntl(sl.outFd, F_SETFL, O_NONBLOCK)
  sl.rbuf.setLen(0)
  true

proc newStatusLine*(): StatusLine =
  ## Start the statusbar child right away; `feed` and `restartIfNeeded`
  ## keep it alive across crashes and sway reloads.
  result = StatusLine(pid: -1, outFd: -1, inFd: -1)
  discard result.spawn()

# --- stream framing ------------------------------------------------------------

proc feed*(sl: StatusLine): bool =
  ## Drain stdout; true when the block list changed.
  if sl.pid < 0: return false
  var buf = newString(maxDrain)
  while true:
    let n = read(sl.outFd, addr buf[0], buf.len)
    if n <= 0: break        # EAGAIN (non-blocking) or the child closed
    sl.rbuf.add(buf[0 ..< n])
    if n < maxDrain: break
  # whole lines only; the protocol writes exactly one JSON thing per line
  result = false
  while true:
    let nl = sl.rbuf.find('\n')
    if nl < 0: break
    var line = sl.rbuf[0 ..< nl]
    sl.rbuf = sl.rbuf[nl + 1 .. ^1]
    line = line.strip
    if line.len == 0 or line.startsWith("{\"version\""): continue
    if line == "[":
      if sl.blocks.len > 0:
        sl.blocks = @[]
        result = true
      continue
    var body = line
    if body.endsWith(","): body.setLen(body.len - 1)
    try:
      let j = body.parseJson
      if j.kind != JArray: continue
      var blocks: seq[Block] = @[]
      for e in j:
        if e.kind != JObject: continue
        var b = Block(name: "", instance: "", fullText: "", minWidth: 0,
                      align: "center")
        template fld(key: string, dst: untyped) =
          let n = e.getOrDefault(key)
          if n != nil and n.kind == JString: dst = n.str
        fld("name", b.name)
        fld("instance", b.instance)
        fld("full_text", b.fullText)
        fld("align", b.align)
        let mw = e.getOrDefault("min_width")
        if mw != nil and mw.kind == JInt: b.minWidth = mw.num.int
        blocks.add b
      sl.blocks = blocks
      result = true
    except CatchableError: discard

proc alive*(sl: StatusLine): bool =
  ## WNOHANG waitpid doubles as the zombie reaper: once the child is gone
  ## this answers false (and has reaped it), `restartIfNeeded` spawns next.
  if sl.pid < 0: return false
  var status: cint
  waitpid(sl.pid, status, WNOHANG) != sl.pid

proc restartIfNeeded*(sl: StatusLine) =
  if not sl.alive():
    if sl.pid >= 0:
      discard close(sl.outFd); discard close(sl.inFd)
      sl.pid = -1
    discard sl.spawn()

proc sendClick*(sl: StatusLine; b: Block; x, y, button: int) =
  ## One swaybar-shaped click event (block-relative coords).
  if not sl.alive(): return
  let j = %* {"x": x, "y": y, "width": 1, "height": 1, "name": b.name,
              "instance": b.instance, "button": button, "clicks": 1,
              "modifiers": newJArray()}
  var msg = $j & "\n"
  discard write(sl.inFd, addr msg[0], msg.len)
