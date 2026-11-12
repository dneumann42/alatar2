## com.canonical.dbusmenu client: the menus behind every SNI item.
##
## Layouts arrive as `i(ia{sv}av)` - a revision plus a self-describing
## recursive tree; we flatten it to rows carrying a `depth` (submenus render
## indented under their parent for now: one window, no flyouts). Item clicks
## travel back as EventReceived(id, "clicked", variant, timestamp), and any
## LayoutChanged / ItemPropertiesChanged signal from the open item's menu
## triggers a refetch (the dialog child wires its own onSignal).
import tinydbus
import ./dbusd

{.push gcsafe.}  # handlers run from the GC-safe pump callback (dbusd.nim)

const menuIface = "com.canonical.dbusmenu"

var debug* = false  ## set by `tray --menu`: trace replies on stdout

type
  MenuEntry* = object
    id*: int32
    label*: string
    enabled*, visible*: bool
    toggleType*, toggleState*: string
    depth*: int

proc parseProps(br: var BodyReader; e: var MenuEntry) =
  let endPos = br.readArrayBegin("{sv}")
  while br.readArrayHasMore(endPos):
    br.readStructBegin()  # dict entries are 8-aligned structs; without
                          # this the second entry of a non-empty dict
                          # parses from the wrong offset (layout dicts
                          # arrive EMPTY for steam/electron, which is how
                          # this hid)
    let rawKey = br.read[:string]()
    let vs = br.readVariantSignature()
    # the dbusmenu docs list CamelCase keys; libdbusmenu actually puts
    # lowercase dashed ones on the wire (`label`, `toggle-type`). Accept
    # both by normalising.
    var key = ""
    for c in rawKey:
      if c == '-': continue
      key.add(if c in 'A' .. 'Z': chr(ord(c) + 32) else: c)
    case key
    of "label":
      if vs == "s": e.label = br.read[:string]() else: br.skip(vs)
    of "enabled":
      if vs == "b": e.enabled = br.read[:bool]() else: br.skip(vs)
    of "visible":
      if vs == "b": e.visible = br.read[:bool]() else: br.skip(vs)
    of "toggletype":
      if vs == "s": e.toggleType = br.read[:string]() else: br.skip(vs)
    of "togglestate":
      if vs == "i":
        e.toggleState = case br.read[:int32]()
                        of 0: "off"
                        of 1: "on"
                        else: "mixed"
      elif vs == "s":
        # electron sends ToggleState as a string ("on"/"off") despite `i`
        e.toggleState = br.read[:string]()
      else: br.skip(vs)
    else:
      # type, children-display, icon-* etc: not modelled yet
      br.skip(vs)

proc parseNode(br: var BodyReader; depth: int; outp: var seq[MenuEntry]) =
  ## At a body position holding the struct (ia{sv}av) of one menu node.
  var e = MenuEntry(depth: depth, enabled: true, visible: true)
  br.readStructBegin()  # (ia{sv}av) struct boundary before the id
  e.id = br.read[:int32]()
  br.parseProps(e)
  # Keep every child node even when its props are empty (Steam/electron
  # send labels only in GetGroupProperties); the root itself is dropped.
  if depth > 0:
    outp.add e
  let kids = br.readArrayBegin("v")
  while br.readArrayHasMore(kids):
    let vs = br.readVariantSignature()
    if vs == "(ia{sv}av)":
      parseNode(br, depth + 1, outp)
    else:
      br.skip(vs)

proc mergeGroups(entries: var seq[MenuEntry]; reply: Message) =
  ## GetGroupProperties reply. Steam/libdbusmenu answers the compact
  ## `a(ia{sv})` form and leaves GetLayout's property dicts EMPTY - the
  ## groups are where the labels live. The spec's wider `a(ii)a{sv}av)`
  ## shape (children repeated per group) is not handled: our layout pass
  ## already asked for full depth, so compact-only works for every item
  ## seen so far.
  var br = initBodyReader(reply.body, reply.signature)
  if br.sig != "a(ia{sv})":
    if debug: echo "[groups] unexpected signature: ", br.sig
    return
  let groups = br.readArrayBegin("(ia{sv})")
  var dbgN = 0
  while br.readArrayHasMore(groups):
    inc dbgN
    if dbgN > 40:
      if debug: echo "[groups] STUCK after 40, pos=", "…", " end=", groups
      raise newException(ValueError, "mergeGroups runaway")
    br.readStructBegin()
    var g = MenuEntry(depth: -1, enabled: true, visible: true)
    g.id = br.read[:int32]()
    br.parseProps(g)
    if debug: echo "[groups] #", dbgN, " id=", g.id, " label=", g.label[0 ..< min(20, g.label.len)]
    for e in entries.mitems:
      if e.id == g.id:
        if g.label.len > 0: e.label = g.label
        e.enabled = g.enabled
        e.visible = g.visible
        if g.toggleType.len > 0: e.toggleType = g.toggleType
        if g.toggleState.len > 0: e.toggleState = g.toggleState
        break

proc fetchLayout*(bus: Bus; service, menuPath: string;
                  done: proc (entries: seq[MenuEntry]) {.closure, gcsafe.}) =
  if menuPath.len == 0: return
  var entries: seq[MenuEntry]
  proc withGroups(bus: Bus; reply: Message) =
    if debug:
      echo "[groups] kind=", $reply.kind, " sig=", reply.signature,
           " err=", reply.errorName
    if reply.kind == MethodReturn:
      mergeGroups(entries, reply)
    done(entries)
  proc handler(bus: Bus; reply: Message) =
    entries = @[]
    if debug:
      echo "[layout] kind=", $reply.kind, " sig=", reply.signature,
           " err=", reply.errorName
      if reply.kind == Error and reply.body.len > 0:
        var er = initBodyReader(reply.body, reply.signature)
        echo "        detail: ", er.read[:string]()
    if reply.kind == MethodReturn and reply.signature[1 ..< reply.signature.len] ==
        "(ia{sv}av)":
      var br = initBodyReader(reply.body, reply.signature)
      discard br.read[:int32]()      # layout revision
      parseNode(br, 0, entries)      # the root node: children only
    if debug:
      echo "[layout] parsed rows: ", entries.len,
           " first ids: ", (if entries.len > 0: $entries[0].id else: "-")
    if entries.len == 0:
      done(entries)
      return
    var m2 = methodCall(service, menuPath, menuIface,
                        "GetGroupProperties")
    var b2 = initBodyBuilder()
    let ia = b2.addArrayBegin("i")
    for e in entries:
      b2.add e.id
    ia.finish()
    let sa = b2.addArrayBegin("s")
    for p in ["label", "enabled", "visible", "toggle-type", "toggle-state",
              "type", "children-display"]:
      b2.add p
    sa.finish()
    m2.setBody(b2)
    bus.request(m2, withGroups)
  var m = methodCall(service, menuPath, menuIface, "GetLayout")
  var b = initBodyBuilder()
  b.add 0'i32            # parentId: root
  b.add (-1'i32)         # recursionDepth: everything
  let ab = b.addArrayBegin("s")
  for p in ["Label", "Enabled", "Visible", "ToggleType", "ToggleState"]:
    b.add p
  ab.finish()
  m.setBody(b)
  bus.request(m, handler)

proc aboutToShow*(bus: Bus; service, menuPath: string; after: proc () {.closure, gcsafe.}) =
  var m = methodCall(service, menuPath, menuIface, "AboutToShow")
  var b = initBodyBuilder()
  b.add 0'i32
  m.setBody(b)
  proc handler(bus: Bus; reply: Message) = after()
  bus.request(m, handler)

proc fetchMenu*(bus: Bus; service, menuPath: string;
                done: proc (entries: seq[MenuEntry]) {.closure, gcsafe.}) =
  ## AboutToShow first (the app builds the model lazily), then GetLayout.
  proc step2() =
    fetchLayout(bus, service, menuPath, done)
  aboutToShow(bus, service, menuPath, step2)

proc eventReceived*(bus: Bus; service, menuPath: string; id: int32;
                    eventId = "clicked") =
  var m = methodCall(service, menuPath, menuIface, "EventReceived")
  var b = initBodyBuilder()
  b.add id
  b.add eventId
  b.addVariant("i") do (bb: var BodyBuilder): bb.add 0'i32
  b.add 0'u32 # timestamp: the daemon does not rate events for us
  m.setBody(b)
  proc done(bus: Bus; reply: Message) = discard
  bus.request(m, done)

proc activateItem*(bus: Bus; service, menuPath: string; e: MenuEntry) =
  ## Menu-activation protocol: report the press, then a toggle for
  ## checkables, then let the host refresh the labels.
  if e.toggleType == "checkmark" or e.toggleType == "radio":
    eventReceived(bus, service, menuPath, e.id, "toggle-state")
  eventReceived(bus, service, menuPath, e.id, "clicked")

proc isOurSignal*(m: Message; service, unique, menuPath: string): bool =
  ## dbusmenu chatter from this item's menu service, at this menu path.
  m.iface == menuIface and m.path == menuPath and
      (m.sender == service or (unique.len > 0 and m.sender == unique))
