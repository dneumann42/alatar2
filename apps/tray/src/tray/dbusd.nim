## Single-connection D-Bus driver over tinydbus.
##
## tinydbus has no non-blocking receive and its socket fd is a private
## field, which rules out both common designs:
##
##  * a reader thread - method returns for requests sent on the main
##    thread arrive on the same socket, so a second consumer of the fd
##    steals every reply (and syncall()/wait() cannot be used at all);
##  * thread-owned connection + job queue - the queue cannot wake a
##    thread blocked in recv() without... the fd.
##
## So: one connection, main thread only, and we call receive() exactly
## when poll() says the socket is readable. Blocking recvAll inside
## receive() then completes single messages without stalling the loop
## (the dbus daemon never holds a half-written message). The fd is
## recovered with a layout cast - BusConnection is (fd, nextSerial,
## pending) in tinydbus 0.5.2, which the nimble pin freezes; sanity is
## checked on startup. A future tinydbus `getFd()` accessor replaces
## this (worth an upstream PR), and newBus keeps one echo line where
## the cast lives so the swap is one place.
##
## Replies, signals and incoming method calls all funnel through pump();
## requests register a serial-keyed handler in `pending` instead of
## blocking in syncall.
import std/[posix, tables]
import tinydbus

{.push gcsafe.}  # the driver runs inside the kit's GC-safe fd callbacks

type
  InMsg* = Message ## received traffic: tinydbus's Message is already a
                   ## plain field record (ref, but same-thread only)

  ReplyHandler* = proc (bus: Bus; reply: InMsg) {.closure, gcsafe.}
    ## Runs on the main thread from pump() when the reply with this serial
    ## arrives; `reply.kind` is MethodReturn or Error. Handlers may call
    ## request()/oneWay()/reply()/emit() reentrantly on the same bus.
    ## gcsafe: the kit's fdwatch callbacks must be GC-safe, and pump()
    ## performs the indirect call through onCall/onSignal.

  Bus* = ref object
    conn: BusConnection
    fd: posix.SocketHandle
    uniqueName*: string
    pending: Table[uint32, ReplyHandler]
    onCall*: proc (bus: Bus; call: InMsg) {.closure, gcsafe.}
      ## Incoming MethodCall addressed to us (by well-known or unique name).
    onSignal*: proc (bus: Bus; sig: InMsg) {.closure, gcsafe.}
      ## Incoming Signal after the AddMatch rules we installed.
    broke*: bool ## socket died; pump stops

  ## Layout mirror of tinydbus BusConnection (0.5.2), for the fd read only.
  ConnLayout = object
    fd: posix.SocketHandle
    nextSerial: uint32
    pending: Table[uint32, Message]

const
  pollTimeoutMs* = 500 ## idle wake-up budget for pump; loop callers reuse it

proc readFd(conn: var BusConnection): posix.SocketHandle =
  # The one place that knows tinydbus's private layout. Swap for an
  # upstream getFd() accessor when available.
  cast[ptr ConnLayout](conn.addr).fd

{.push gcsafe off.}  # startup touches the environment (getEnv, tinydbus connect)
proc newBus*(): Bus =
  var (conn, unique) = openSessionBus()
  let fd = conn.readFd()
  # Sanity: the cast must land on a live socket. getpeername on an AF_UNIX
  # dbus connection succeeds; on garbage it does not.
  var addrLen = SockLen(sizeof(SockAddr_storage))
  var sa: SockAddr_storage
  if getpeername(fd, cast[ptr SockAddr](sa.addr), addrLen.addr) != 0.cint:
    raise newException(
      Defect, "tinydbus 0.5.2 layout cast found no socket - pin mismatch?")
  Bus(conn: conn, fd: fd, uniqueName: unique,
      pending: initTable[uint32, ReplyHandler]())
{.pop.}  # gcsafe off -> back to the module default

proc uniqueNameOf*(bus: Bus): string = bus.uniqueName

proc fd*(bus: Bus): int32 =
  ## The socket descriptor for event-loop integration (ellipse `watchFd`).
  cast[int32](bus.fd)

proc fdReady*(bus: Bus; timeoutMs = 0): bool =
  # Nim 2.4's std/posix exposes POLLIN/POLLHUP as booleans, so keep the
  # raw Linux ABI values for the bit test (poll.h: POLLIN 0x0001,
  # POLLHUP 0x0010).
  const
    inMask = 0x0001'i16   # POLLIN
    hupMask = 0x0010'i16  # POLLHUP
  var pf = TPollFd(fd: cast[cint](bus.fd), events: inMask, revents: 0'i16)
  discard poll(pf.addr, 1.cuint, timeoutMs.cint)
  (int(pf.revents) and int(inMask or hupMask)) != 0

proc pump*(bus: Bus) =
  ## Drain every readable message once (receive() completes each frame on
  ## its own once poll() said readable).
  while not bus.broke and bus.fdReady():
    var msg: Message
    try:
      msg = bus.conn.receive()
    except CatchableError:
      bus.broke = true
      return
    if msg.replySerial != 0:
      var handler: ReplyHandler
      if bus.pending.pop(msg.replySerial, handler):
        handler(bus, msg)
    elif msg.kind == MethodCall:
      if bus.onCall != nil: bus.onCall(bus, msg)
    elif msg.kind == Signal:
      if bus.onSignal != nil: bus.onSignal(bus, msg)

proc run*(bus: Bus; onWake: proc (bus: Bus) {.closure.}) =
  ## Blocking driver loop for console tools: pump on readable + call
  ## onWake on the idle timeout. The ellipse app instead wires fdwatch
  ## to fdReady and pumps per frame; it never enters this.
  while not bus.broke:
    if bus.fdReady(pollTimeoutMs):
      bus.pump()
    else:
      onWake(bus)

proc sendNow(bus: Bus; msg: Message) =
  # `call` sends and returns an unwaited PendingCall: fire-and-forget for
  # method returns, signals, one-way calls. send() assigns msg.serial in
  # place (Message is a ref), which is how request() correlates replies.
  # bus.conn is passed as a view - BusConnection is move-only, the field
  # must never be copied or moved (verified: repeated call()/receive() on
  # the same field keep the socket alive, same pattern tinydbus' wait()
  # uses on its `var` argument).
  discard bus.conn.call(msg)

proc request*(bus: Bus; msg: Message; handler: ReplyHandler) =
  bus.sendNow(msg)
  bus.pending[msg.serial] = handler

proc oneWay*(bus: Bus; msg: Message) =
  bus.sendNow(msg)

proc methodCall*(destination, path, iface, member: string): Message =
  initMethodCallMsg(destination, path, iface, member)

proc reply*(bus: Bus; call: InMsg; builder: BodyBuilder = initBodyBuilder()) =
  ## Empty return by default; pass a builder for a body.
  var stub = call # sender/serial headers are all initMethodReturnMsg reads
  var msg = initMethodReturnMsg(stub)
  let (sig, body) = builder.finish()
  msg.signature = sig
  msg.body = body
  bus.sendNow msg

proc replyError*(bus: Bus; call: InMsg; name, detail: string) =
  var stub = call
  var msg = initErrorMsg(stub, name)
  var b = initBodyBuilder()
  b.add detail
  msg.setBody(b)
  bus.sendNow msg

proc emit*(bus: Bus; path, iface, member: string; builder: BodyBuilder) =
  var msg = initSignalMsg(path, iface, member)
  let (sig, body) = builder.finish()
  msg.signature = sig
  msg.body = body
  bus.sendNow msg

proc addMatch*(bus: Bus; rule: string) =
  ## Session-daemon match rules are one-way (reply is void; we ignore it -
  ## an error here would only surface via a later unmatched silence).
  var m = methodCall("org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus", "AddMatch")
  var b = initBodyBuilder()
  b.add rule
  m.setBody(b)
  bus.oneWay m

proc requestName*(bus: Bus; name: string; flags: uint32;
                  handler: ReplyHandler) =
  var m = methodCall("org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus", "RequestName")
  var b = initBodyBuilder()
  b.add name
  b.add flags
  m.setBody(b)
  bus.request(m, handler)

proc propertiesGet*(bus: Bus; dest, path, iface, propName: string;
                    handler: ReplyHandler) =
  var m = methodCall(dest, path, "org.freedesktop.DBus.Properties", "Get")
  var b = initBodyBuilder()
  b.add iface
  b.add propName
  m.setBody(b)
  bus.request(m, handler)

proc propertiesGetAll*(bus: Bus; dest, path, iface: string;
                       handler: ReplyHandler) =
  var m = methodCall(dest, path, "org.freedesktop.DBus.Properties", "GetAll")
  var b = initBodyBuilder()
  b.add iface
  m.setBody(b)
  bus.request(m, handler)

proc beginDict*(b: var BodyBuilder): ArrayBuilder =
  ## a{sv} array entry helper: each entry is a struct-aligned (s v) pair,
  ## and the writer's automatic alignment makes addStructBegin the
  ## per-entry aligner.
  b.addArrayBegin("{sv}")
