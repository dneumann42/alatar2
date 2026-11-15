## sway IPC client: GET_TREE + GET_WORKSPACES + the workspace/mode event
## subscription, over a non-blocking AF_UNIX socket, drained from the frame
## loop (and woken by `fdwatch` in bar.nim). The i3-ipc wire format: the
## literal "i3-ipc", a u32 LE payload length, a u32 LE message type, then
## the payload; events carry the 0x80000000 bit. A workspace event re-asks
## for both replies rather than diffing the event's node: they are small,
## and one code path covers every change sway reports (rename, move to
## other output, focus, ...). The tree gives list membership and order;
## get_workspaces gives the focused/visible/urgent flags - sway's tree does
## NOT set them on the workspace node once focus sits inside one of its
## windows, which is why the pills take the flags from this reply.

import std/[posix, os, oserrors, strutils, json, monotimes, tables]

{.push gcsafe.}

const
  i3RunCommand = 0'u32
  i3GetWorkspaces = 1'u32  ## swaymsg -t get_workspaces: the authoritative
                           ## focused/visible/urgent flags. Sway's tree does
                           ## NOT mark the workspace node focused when focus
                           ## sits inside one of its windows, so pills derive
                           ## their state from this reply, keyed by name, and
                           ## merely use the tree for list membership+order.
  i3GetTree = 4'u32
  i3Subscribe = 2'u32
  eventMask = 0x80000000'u32
  evWorkspace = 0'u32
  evMode = 2'u32         ## i3/sway: 0 workspace, 1 output, 2 mode
  evShutdown = 7'u32
  reconnectNs = 2_000_000_000'i64

type
  Worksp* = ref object
    name*: string
    num*: int
    output*: string
    focused*, visible*, urgent*: bool

  WsFlag = object
    focused, visible, urgent: bool

  Ipc* = ref object
    fd: SocketHandle
    rbuf: string          ## bytes of the not-yet-complete frame
    modeName*: string     ## sway's current binding mode ("default" plain)
    workspaces*: seq[Worksp]
    wsFlags: Table[string, WsFlag]
    alive*: bool
    lastTry: int64        ## monoNs of the last connect attempt

proc u32le(x: uint32): string =
  result = newString(4)
  result[0] = char(x and 0xFF)
  result[1] = char((x shr 8) and 0xFF)
  result[2] = char((x shr 16) and 0xFF)
  result[3] = char((x shr 24) and 0xFF)

proc readU32le(s: string, at: int): uint32 =
  (uint32(s[at].uint8) or uint32(s[at+1].uint8) shl 8 or
    uint32(s[at+2].uint8) shl 16 or uint32(s[at+3].uint8) shl 24)

proc monoNs*(): int64 =
  ## Monotonic nanoseconds: the clock the pacer itself runs on.
  getMonoTime().ticks

proc swaySocketPath(): string =
  getEnv("SWAYSOCK", "")

proc sendMsg(ipc: Ipc; msgType: uint32; payload: string) =
  if not ipc.alive: return
  var msg = "i3-ipc" & u32le(payload.len.uint32) & u32le(msgType) & payload
  var sent = 0
  while sent < msg.len:
    let n = posix.send(ipc.fd, addr msg[sent], msg.len - sent, 0.cint)
    if n <= 0:
      if osLastError() == OSErrorCode(EAGAIN) or osLastError() == OSErrorCode(EINTR): continue
      ipc.alive = false
      return
    sent += n.int

proc refresh*(ipc: Ipc) =
  ## Ask for the two replies the pills are built from: the tree (which
  ## workspaces belong to which output, in sway's order) and the workspace
  ## flags (which of them are focused/visible/urgent).
  ipc.sendMsg(i3GetTree, "")
  ipc.sendMsg(i3GetWorkspaces, "")

proc connect(ipc: Ipc): bool =
  let path = swaySocketPath()
  if path.len == 0: return false
  var sa: SockAddr_un
  sa.sun_family = uint16(AF_UNIX)    # TSa_Family: 16-bit on glibc
  if path.len > sizeof(sa.sun_path) - 1: return false
  for i in 0 ..< path.len: sa.sun_path[i] = path[i]
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if cast[cint](fd) < 0: return false
  if posix.connect(fd, cast[ptr SockAddr](addr sa),
      sizeof(sa).SockLen) != 0.cint:
    discard close(fd)
    return false
  discard fcntl(fd, F_SETFL, O_NONBLOCK)
  ipc.fd = fd
  ipc.alive = true
  ipc.rbuf.setLen(0)
  ipc.sendMsg(i3Subscribe, """["workspace","mode"]""")
  ipc.refresh()
  true

proc walk(node: JsonNode; outp: var seq[Worksp]) =
  if node.kind == JObject:
    let t = node.getOrDefault("type")
    if t != nil and t.kind == JString and t.str == "workspace":
      var w = Worksp()
      let nm = node.getOrDefault("name")
      if nm != nil and nm.kind == JString: w.name = nm.str
      let nu = node.getOrDefault("num")
      if nu != nil and nu.kind == JInt: w.num = nu.num.int
      let op = node.getOrDefault("output")
      if op != nil and op.kind == JString: w.output = op.str
      let fc = node.getOrDefault("focused")
      if fc != nil and fc.kind == JBool: w.focused = fc.bval
      let vi = node.getOrDefault("visible")
      if vi != nil and vi.kind == JBool: w.visible = vi.bval
      let ur = node.getOrDefault("urgent")
      if ur != nil and ur.kind == JBool: w.urgent = ur.bval
      outp.add w
    for key, child in node.pairs:
      if key in ["nodes", "floating_nodes"]:
        if child.kind == JArray:
          for c in child: walk(c, outp)

proc parseWorkspaces(payload: string): seq[Worksp] =
  result = @[]
  try:
    walk(payload.parseJson, result)
  except CatchableError:
    discard

proc parseFlags(payload: string): Table[string, WsFlag] =
  ## name -> flags, from the get_workspaces array: sway marks focus on the
  ## container that holds it, so the tree's workspace node cannot answer
  ## "which workspace is current" - this reply can.
  try:
    let j = payload.parseJson
    if j.kind != JArray: return
    for e in j:
      if e.kind != JObject: continue
      let nm = e.getOrDefault("name")
      if nm == nil or nm.kind != JString: continue
      template flag(key: string): bool =
        let n = e.getOrDefault(key)
        n != nil and n.kind == JBool and n.bval
      result[nm.str] = WsFlag(focused: flag("focused"),
                              visible: flag("visible"),
                              urgent: flag("urgent"))
  except CatchableError:
    discard

proc applyFlags(ipc: Ipc) =
  for w in ipc.workspaces.items:
    let f = ipc.wsFlags.getOrDefault(w.name)
    w.focused = f.focused
    w.visible = f.visible
    w.urgent = f.urgent

proc handleFrame(ipc: Ipc; msgType: uint32; payload: string): bool =
  ## True when app-visible state changed.
  if (msgType and eventMask) != 0:
    case msgType and not eventMask
    of evWorkspace:
      ipc.refresh()                   # both replies carry the new state
    of evMode:
      try:
        let j = payload.parseJson
        let ch = j.getOrDefault("change")
        ipc.modeName = if ch != nil and ch.kind == JString: ch.str else: "default"
        result = true
      except CatchableError: discard
    of evShutdown: ipc.alive = false
    else: discard
  elif msgType == i3GetTree:
    ipc.workspaces = parseWorkspaces(payload)
    applyFlags(ipc)
    result = true
  elif msgType == i3GetWorkspaces:
    ipc.wsFlags = parseFlags(payload)
    applyFlags(ipc)
    result = true
  else:
    discard                           # RUN_COMMAND replies and friends

proc drainFrames(ipc: Ipc): bool =
  var buf = newString(8192)
  while true:
    let n = posix.recv(ipc.fd, addr buf[0], buf.len, 0.cint)
    if n <= 0:
      if n == 0.cint or (n < 0 and osLastError() != OSErrorCode(EAGAIN) and osLastError() != OSErrorCode(EINTR)):
        ipc.alive = false             # sway closed / restarted
      return
    ipc.rbuf.add(buf[0 ..< n.int])
    # frame the buffer: "i3-ipc" + len + type + payload, repeatedly
    while true:
      if ipc.rbuf.len < 14: return
      if ipc.rbuf[0 .. 5] != "i3-ipc":
        # desynchronised (should not happen on a fresh connection): drop it
        ipc.alive = false
        return
      let plen = ipc.rbuf.readU32le(6).int
      let ptype = ipc.rbuf.readU32le(10)
      if ipc.rbuf.len < 14 + plen: return
      let payload = ipc.rbuf[14 ..< 14 + plen]
      ipc.rbuf = ipc.rbuf[14 + plen ..^ 1]
      if ipc.handleFrame(ptype, payload): result = true

proc poll*(ipc: Ipc): bool =
  ## Drain the socket; (re)connect when the compositor went away. Call every
  ## frame and from the fdwatch callback; true = the bar should repaint.
  if not ipc.alive:
    let now = monoNs()
    if now - ipc.lastTry < reconnectNs: return false
    ipc.lastTry = now
    result = ipc.connect()
    return
  drainFrames(ipc)

proc runCommand*(ipc: Ipc; cmd: string) =
  ipc.sendMsg(i3RunCommand, cmd)

proc newIpc*(): Ipc =
  Ipc(fd: SocketHandle(-1), modeName: "default", alive: false, lastTry: 0)

proc fd*(ipc: Ipc): int32 =
  ## The socket descriptor for `fdwatch`; -1 while disconnected.
  if ipc.alive: ipc.fd.int32 else: -1
