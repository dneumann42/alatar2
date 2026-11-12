## StatusNotifierWatcher + item bookkeeping (the host half of the tray).
##
## Implements org.kde/freedesktop.StatusNotifierWatcher as a D-Bus service
## on the bus in dbusd.Bus: apps call RegisterStatusNotifierItem against
## whichever name we own, we fetch their org.kde.StatusNotifierItem
## properties (async, correlated through dbusd.request), keep an ordered
## item table and fire onItemsChanged. Incoming signals (PropertiesChanged,
## NewIcon/Status/..., NameOwnerChanged) keep the table honest; when an
## owning service disappears the item goes with it.
##
## The dbusmenu for each item lives on `TrayItem.menu` (object path) -
## consumed by the UI phase.
import std/[strutils, tables]
import tinydbus
import ./dbusd

{.push gcsafe.}  # the kit's fdwatch contract: host handlers run from a
                  # GC-safe pump callback (see dbusd.nim)

# --- helpers out of the unsafe zone --------------------------------------------

const
  watcherObj = "/StatusNotifierWatcher"
  watcherIfaceKde = "org.kde.StatusNotifierWatcher"
  watcherIfaceFd = "org.freedesktop.StatusNotifierWatcher"
  itemIfaceKde = "org.kde.StatusNotifierItem"
  itemIfaceFd = "org.freedesktop.StatusNotifierItem"
  propsIface = "org.freedesktop.DBus.Properties"
  dbusName = "org.freedesktop.DBus"
  dbusObj = "/org/freedesktop/DBus"
  watcherNames = [watcherIfaceKde, watcherIfaceFd]
  itemIfaces = [itemIfaceKde, itemIfaceFd]

  namePrimaryOwner = 1'u32

type
  Pixmap* = object
    width*, height*: int32
    argb*: seq[uint32] ## repacked from the spec's network-order ARGB

  TrayItem* = ref object
    service*, path*: string ## as registered (well-known or unique name)
    uniqueName*: string     ## resolved sender, for signal matching
    id*, title*, category*, status*: string
    iconName*, iconThemePath*: string
    menu*: string           ## dbusmenu object path ("" = no menu)
    isMenu*: bool           ## ItemIsMenu: left click opens the menu
    pixmaps*: seq[Pixmap]
    loaded*: bool           ## GetAll round trip finished

  Host* = ref object
    bus*: Bus
    items*: OrderedTable[string, TrayItem]
    ownsWatcher*: bool
    onItemsChanged*: proc (host: Host) {.closure, gcsafe.}
    extraSignal*: proc (host: Host; m: Message) {.closure, gcsafe.}
      ## Hook for traffic outside the watcher contract (tray/menu.nim
      ## listens for com.canonical.dbusmenu signals here).

proc key(service, path: string): string = service & " " & path

proc item*(host: Host; service, path: string): TrayItem =
  host.items.getOrDefault(key(service, path))

proc snapshot*(host: Host): seq[TrayItem] =
  for it in host.items.values: result.add it

proc changed(host: Host) =
  if host.onItemsChanged != nil: host.onItemsChanged(host)

# --- incoming property decoding ---------------------------------------------

proc applyProp(item: TrayItem; name, varSig: string; br: var BodyReader) =
  case name
  of "Id":
    if varSig == "s": item.id = br.read[:string]() else: br.skip(varSig)
  of "Title":
    if varSig == "s": item.title = br.read[:string]() else: br.skip(varSig)
  of "Category":
    if varSig == "s": item.category = br.read[:string]() else: br.skip(varSig)
  of "Status":
    if varSig == "s": item.status = br.read[:string]() else: br.skip(varSig)
  of "IconName":
    if varSig == "s": item.iconName = br.read[:string]() else: br.skip(varSig)
  of "IconThemePath":
    if varSig == "s": item.iconThemePath = br.read[:string]() else: br.skip(varSig)
  of "ItemIsMenu":
    if varSig == "b": item.isMenu = br.read[:bool]() else: br.skip(varSig)
  of "Menu":
    if varSig == "o":
      let p = string br.read[:ObjectPath]()
      # ayatana/libdbusmenu exports the Menu property RELATIVE ("Menu"),
      # while the real object lives under the item path (and the path is
      # also given fully-qualified by some apps, or as a bare object path
      # when registering without a service part).
      item.menu =
        if p.len == 0: ""
        elif p.startsWith("/"): p
        elif item.path.len > 0: item.path & "/" & p
        else: "/" & p
    else: br.skip(varSig)
  of "IconPixmap":
    if varSig == "a(iiay)":
      item.pixmaps = @[]
      let arrEnd = br.readArrayBegin("(iiay)")
      while br.readArrayHasMore(arrEnd):
        br.readStructBegin()
        let w = br.read[:int32]()
        let h = br.read[:int32]()
        var bytes: seq[uint8] = @[]
        let dEnd = br.readArrayBegin("y")
        while br.readArrayHasMore(dEnd):
          bytes.add br.read[:uint8]()
        var px = newSeq[uint32](bytes.len div 4)
        for i in 0 ..< px.len:
          let o = i * 4
          px[i] = (uint32(bytes[o]) shl 24) or (uint32(bytes[o+1]) shl 16) or
                  (uint32(bytes[o+2]) shl 8) or uint32(bytes[o+3])
        item.pixmaps.add Pixmap(width: w, height: h, argb: px)
    else:
      br.skip(varSig)
  else:
    # ToolTip "(ss(ia(iiay)))", OverlayIconPixmap, AttentionIconPixmap,
    # DestinationIcon and friends: kept out of the hot table for now.
    br.skip(varSig)

proc readDictFrom(br: var BodyReader;
                  apply: proc (name, varSig: string; br: var BodyReader)
                         {.closure, gcsafe.}) =
  ## Reads an a{sv} dict at the reader's current position. Callers keep
  ## ONE BodyReader over the whole message body: dbus alignment is relative
  ## to the body start, so the buffer must never be sliced and re-parsed.
  let arrEnd = br.readArrayBegin("{sv}")
  while br.readArrayHasMore(arrEnd):
    br.readStructBegin()
    let name = br.read[:string]()
    let varSig = br.readVariantSignature()
    apply(name, varSig, br)

# --- requests out -------------------------------------------------------------

proc fetchAll(host: Host; item: TrayItem) =
  proc handler(bus: Bus; reply: Message) =
    if reply.kind == MethodReturn:
      var br = initBodyReader(reply.body, reply.signature)
      readDictFrom(br) do (name, varSig: string; b: var BodyReader):
        applyProp(item, name, varSig, b)
      item.loaded = true
      host.changed()
  propertiesGetAll(host.bus, item.service, item.path, itemIfaceKde, handler)

proc norm(raw, sender: string): (string, string) =
  ## Split a Register argument into (service, path). Apps may pass just a
  ## path (service = the caller) or service & path joined; a service with
  ## no path means the spec default /StatusNotifierItem.
  if raw.startsWith("/"):
    (sender, raw)
  else:
    let cut = raw.find('/')
    if cut < 0: (raw, "/StatusNotifierItem")
    elif cut == raw.len - 1: (raw[0 ..< cut], "/StatusNotifierItem")
    else: (raw[0 ..< cut], raw[cut ..< raw.len])

proc register(host: Host; raw, sender: string) =
  let (service, path) = norm(raw, sender)
  if service.len == 0 or path.len == 0: return
  if host.item(service, path) != nil: return
  let item = TrayItem(service: service, path: path)
  host.items[key(service, path)] = item
  # Signals only ever carry unique names; when an app registers under a
  # well-known name, resolve it for sender matching.
  if service.startsWith(":"):
    item.uniqueName = service
  else:
    proc handler(bus: Bus; reply: Message) =
      if reply.kind == MethodReturn:
        var br = initBodyReader(reply.body, reply.signature)
        item.uniqueName = br.read[:string]()
    var m = methodCall(dbusName, dbusObj, dbusName, "GetNameOwner")
    var b = initBodyBuilder()
    b.add service
    m.setBody(b)
    host.bus.request(m, handler)
  var b = initBodyBuilder()
  b.add (service & path)
  host.bus.emit(watcherObj, watcherIfaceKde,
                "StatusNotifierItemRegistered", b)
  host.fetchAll(item)
  host.changed()

proc unregister(host: Host; raw, sender: string) =
  let (service, path) = norm(raw, sender)
  var gone: TrayItem = nil
  for k, item in host.items:
    if item.service == service and (path.len == 0 or item.path == path):
      host.items.del(k)
      gone = item
      break
  if gone != nil:
    var b = initBodyBuilder()
    b.add (gone.service & gone.path)
    host.bus.emit(watcherObj, watcherIfaceKde,
                  "StatusNotifierItemUnregistered", b)
    host.changed()

# --- watcher service replies ----------------------------------------------------

proc addWatcherProp(host: Host; b: var BodyBuilder; name: string) =
  case name
  of "IsStatusNotifierHostRegistered":
    b.addVariant("b") do (bb: var BodyBuilder): bb.add true
  of "ProtocolVersion":
    b.addVariant("i") do (bb: var BodyBuilder): bb.add 0'i32
  of "RegisteredStatusNotifierItems":
    b.addVariant("as") do (bb: var BodyBuilder):
      let ab = bb.addArrayBegin("s")
      for item in host.items.values:
        bb.add item.service & item.path
      ab.finish()
  else: discard

const watcherXml = """
<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="UnregisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  </interface>
</node>
"""

proc handleCall(host: Host; m: Message) =
  case m.iface
  of watcherIfaceKde, watcherIfaceFd:
    case m.member
    of "RegisterStatusNotifierItem":
      if m.signature == "s":
        var br = initBodyReader(m.body, m.signature)
        host.register(br.read[:string](), m.sender)
        host.bus.reply(m)
      else:
        host.bus.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs",
                            "expected s")
    of "UnregisterStatusNotifierItem":
      if m.signature == "s":
        var br = initBodyReader(m.body, m.signature)
        host.unregister(br.read[:string](), m.sender)
        host.bus.reply(m)
      else:
        host.bus.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs",
                            "expected s")
    else:
      host.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod",
                          m.member)
  of propsIface:
    case m.member
    of "Get":
      if m.signature == "ss":
        var br = initBodyReader(m.body, m.signature)
        discard br.read[:string]() # interface name: we only serve the watcher
        let propName = br.read[:string]()
        var b = initBodyBuilder()
        host.addWatcherProp(b, propName)
        if b.sig.len == 0:
          host.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownProperty",
                              propName)
        else:
          host.bus.reply(m, b) # reply signature "v": the variant stands alone
      else:
        host.bus.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs",
                            "expected ss")
    of "GetAll":
      var b = initBodyBuilder()
      let ab = b.beginDict()
      for propName in ["IsStatusNotifierHostRegistered", "ProtocolVersion",
                       "RegisteredStatusNotifierItems"]:
        b.addStructBegin()
        b.add propName
        host.addWatcherProp(b, propName)
        b.addStructEnd()
      ab.finish()
      host.bus.reply(m, b)
    else:
      host.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod",
                          m.member)
  of "org.freedesktop.DBus.Introspectable":
    var b = initBodyBuilder()
    b.add watcherXml
    host.bus.reply(m, b)
  of "org.freedesktop.DBus.Peer":
    if m.member == "Ping":
      host.bus.reply(m)
    else:
      host.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod",
                          m.member)
  else:
    host.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod",
                        m.member)

# --- signals ---------------------------------------------------------------------

proc findItemBySender(host: Host; sender: string): TrayItem =
  for item in host.items.values:
    if item.uniqueName == sender or item.service == sender:
      return item

proc handleSignal(host: Host; m: Message) =
  if host.extraSignal != nil: host.extraSignal(host, m)
  case m.iface
  of dbusName:
    if m.member == "NameOwnerChanged":
      # (s name, s old_owner, s new_owner)
      var br = initBodyReader(m.body, m.signature)
      let name = br.read[:string]()
      let oldOwner = br.read[:string]()
      let newOwner = br.read[:string]()
      if name in watcherNames and newOwner == host.bus.uniqueName:
        host.ownsWatcher = true # queued activation promoted us
      elif oldOwner.len > 0 and newOwner.len == 0:
        # an item's bus died (drop it), or the watcher we queued behind
        # went away (the daemon promotes us; the line above confirms)
        var dropped = false
        for k, item in host.items:
          if item.uniqueName == oldOwner or item.service == oldOwner:
            host.items.del(k)
            dropped = true
            break
        if dropped: host.changed()
  of propsIface:
    if m.member == "PropertiesChanged" and m.signature.startsWith("s"):
      # body: (s interface, a{sv} changed, as invalidated)
      var br = initBodyReader(m.body, m.signature)
      let changedIface = br.read[:string]()
      if changedIface in itemIfaces:
        let item = host.findItemBySender(m.sender)
        if item != nil:
          readDictFrom(br) do (name, varSig: string; b: var BodyReader):
            applyProp(item, name, varSig, b)
          host.changed()
  of itemIfaceKde, itemIfaceFd:
    case m.member
    of "NewIcon", "NewStatus", "NewTitle", "NewAttentionIcon":
      let item = host.findItemBySender(m.sender)
      if item != nil: host.fetchAll(item)
    else: discard
  else: discard

# --- setup --------------------------------------------------------------------------

proc claimWatcherNames(host: Host) =
  for nm in watcherNames:
    let name = nm # fresh binding per iteration: handlers capture it
    proc handler(bus: Bus; reply: Message) =
      if reply.kind == MethodReturn and reply.body.len >= 4:
        var br = initBodyReader(reply.body, reply.signature)
        let outcome = br.read[:uint32]()
        if outcome == namePrimaryOwner and name == watcherIfaceKde:
          host.ownsWatcher = true
      # InQueue (2): the NameOwnerChanged handler promotes us when the
      # current owner dies. Nothing else to do.
    # allow-replacement: takes over from a host that permits it (and from
    # swaybar the moment its tray is configured away, via the queue).
    host.bus.requestName(name, 1'u32, handler)

proc newHost*(bus: Bus): Host =
  result = Host(bus: bus, items: initOrderedTable[string, TrayItem]())
  let host = result
  bus.onCall =
    proc (b: Bus; m: Message) = host.handleCall(m)
  bus.onSignal =
    proc (b: Bus; m: Message) = host.handleSignal(m)
  bus.addMatch("type='signal',sender='" & dbusName &
               "',interface='" & dbusName & "',member='NameOwnerChanged'")
  bus.addMatch("type='signal',interface='" & propsIface &
               "',member='PropertiesChanged'")
  bus.addMatch("type='signal',interface='" & itemIfaceKde & "'")
  bus.addMatch("type='signal',interface='" & itemIfaceFd & "'")
  host.claimWatcherNames()
