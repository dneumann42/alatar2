import std/[os, strutils, sequtils]
import terminal

import alatar/[appimages, controls, fs, modules, packages, repos, services, symlinks, tidy]

import cligen

const
  alatarDoc = "alatar: declarative system module manager " &
    "(packages + systemd user units).\n"
  alatarUsage = "$doc\nUsage:\n" &
    "  $command {SUBCMD}  [sub-command options & parameters]\n" &
    "where {SUBCMD} is one of:\n$subcmds\n\n" &
    "$command {-h|--help} or with no args at all prints this message.\n" &
    "$command --help-syntax gives general cligen syntax help.\n" &
    "Run \"$command {help SUBCMD|SUBCMD --help}\" for just SUBCMD.\n" &
    "Run \"$command help\" to get *comprehensive* help.$ifVersion"
  dirHelp = "modules directory [env: ALATAR_MODULES_DIR; default: modules]"

proc defaultModulesDir(): string =
  ## Read at call time so ALATAR_MODULES_DIR works at runtime, not compile
  ## time (the proc default `dir = defaultModulesDir()` is evaluated per
  ## dispatch).
  getEnv("ALATAR_MODULES_DIR", "modules")

proc loadRegistry(dir: string): ModuleRegistery =
  try:
    result.load(dir)
  except CatchableError as e:
    quit "alatar: cannot load module tree from '" & dir & "': " & e.msg, 1

proc padEnd(s: string, width: int): string =
  ## Local shim: this Nim snapshot's strutils lacks pad*.
  if s.len >= width: s
  else: s & spaces(width - s.len)

proc colorEnabled(): bool =
  not existsEnv("NO_COLOR") and isatty(stdout)

proc paint(colorCode: int, text: string): string =
  if colorEnabled(): "\x1b[" & $colorCode & "m" & text & "\x1b[0m"
  else: text

proc cmdInstall(names: seq[string], dir = defaultModulesDir()) =
  ## Install one or more modules (or "all" for every top-level module). Each
  ## module's dependencies - including dependencies of its submodules - are
  ## installed first, in dependency order. Bootstrap packages (before = true)
  ## go through pacman / git+makepkg; everything else through paru and flatpak.
  ## Entries in a module's fs.toml are created (missing dirs/files only) before
  ## its symlink.toml entries are linked, which in turn come before its units.
  let reg = loadRegistry(dir)
  defer: stopSudoAuthKeepAlive()
  var targets = names
  if "all" in targets:
    targets = targets.filterIt(it != "all")
    for m in reg.modules:
      if m.name notin targets:
        targets.add m.name
  for name in targets:
    try:
      reg.install(name)
      echo "installed ", name, "."
    except ModuleError as e:
      quit "alatar: " & e.msg, 1

proc cmdUninstall(names: seq[string], dir = defaultModulesDir()) =
  ## Stop and remove a module's systemd user units, symlinks and packages
  ## (submodules included). Modules that this one merely depends on are
  ## left alone; other modules may still use them. fs.toml entries are kept:
  ## they hold user data, alatar only seeds them.
  if names.len != 1:
    quit "alatar: uninstall expects exactly one module name", 2
  let name = names[0]
  let reg = loadRegistry(dir)
  defer: stopSudoAuthKeepAlive()
  try:
    reg.uninstall(name)
    echo "uninstalled ", name, "."
  except ModuleError as e:
    quit "alatar: " & e.msg, 1

proc cmdStatus(names: seq[string] = @[], dir = defaultModulesDir(),
               reasons = 5) =
  ## Show install status. Without names, all top-level modules are listed.
  ## On Error, the missing or unverifiable items are printed underneath,
  ## capped by --reasons (0 = no cap). Exit code is 1 if any module is in
  ## Error (partially installed, broken config, or unverifiable), 0
  ## otherwise.
  let reg = loadRegistry(dir)
  var targets = names
  if targets.len == 0:
    targets = reg.modules.mapIt(it.name)
  if targets.len == 0:
    echo "no modules found"
    return
  let width = max(7, targets.mapIt(it.len).max)
  var anyError = false
  for name in targets:
    if not reg.findModule(name).found:
      quit "alatar: unknown module '" & name & "'", 1
    let (status, why) = reg.statusDetail(name)
    case status
    of Installed:
      echo name.padEnd(width), "  ", paint(32, "Installed")
    of NotInstalled:
      echo name.padEnd(width), "  ", paint(2, "NotInstalled")
    of Error:
      echo name.padEnd(width), "  ", paint(31, "Error")
      anyError = true
      for i, reason in why:
        if reasons > 0 and i >= reasons:
          echo spaces(width + 2),
            paint(2, "(and " & $(why.len - i) & " more; --reasons=0 shows all)")
          break
        echo spaces(width + 2), paint(31, "!"), " ", reason
  if anyError:
    quit 1

proc cmdModules(dir = defaultModulesDir()) =
  ## List the module tree, with inter-module dependencies.
  let reg = loadRegistry(dir)
  proc show(m: Module, depth: int) =
    var line = spaces(depth * 2) & m.name
    if m.dependencies.len > 0:
      line.add " <- " & m.dependencies.join(", ")
    echo line
    for sub in m.subModules:
      show(sub, depth + 1)
  for m in reg.modules:
    show(m, 0)

proc cmdInfo(names: seq[string], dir = defaultModulesDir()) =
  ## Show a module's dependencies, packages and systemd user units, each
  ## marked with its current install state.
  if names.len != 1:
    quit "alatar: info expects exactly one module name", 2
  let name = names[0]
  let reg = loadRegistry(dir)
  let res = reg.findModule(name)
  if not res.found:
    quit "alatar: unknown module '" & name & "'", 1
  proc mark(state: bool): string =
    if state: paint(32, "ok     ") else: paint(31, "missing")
  proc show(m: Module, parentDir: string, depth: int) =
    let indent = spaces(depth * 2)
    echo indent, m.name, ":"
    if m.dependencies.len > 0:
      echo indent, "  depends on: ", m.dependencies.join(", ")
    let mdir = parentDir / m.name
    try:
      for repo in loadRepos(mdir):
        let state =
          try:
            mark repo.isInstalled()
          except RepoError:
            paint(2, "unknown")
        echo indent, "  ", state, "  repo ", repo.name, " [pacman.conf]"
    except IOError, RepoError:
      discard
    let specPath = mdir / "packages.toml"
    if fileExists(specPath):
      for spec in loadSpecFile(specPath):
        let state =
          try:
            mark spec.isInstalled()
          except PackageError:
            paint(2, "unknown")
        echo indent, "  ", state, "  ", spec.name,
          " [", $spec.source, (if spec.before: ", before" else: ""), "]"
    for svc in loadServices(mdir):
      let state =
        try:
          mark svc.isInstalled()
        except ServiceError:
          paint(2, "unknown")
      echo indent, "  ", state, "  unit: ", svc.unitName
    let entries =
      try:
        fsSpecs(mdir)
      except CatchableError:
        @[]
    for spec in entries:
      echo indent, "  ", mark spec.isInstalled(),
        (if spec.kind == fsDirectory: "  dir:  " else: "  file: "), spec.path
    let links =
      try:
        symlinkSpecs(mdir, reg.moduleDir)
      except CatchableError:
        @[]
    for spec in links:
      echo indent, "  ", mark spec.isInstalled(), "  link: ", spec.dest,
        " -> ", spec.source
    for sub in m.subModules:
      show(sub, mdir, depth + 1)
  show(res.module, res.parentDir, 0)

proc defaultTidyConfig(): string =
  try:
    getEnv("ALATAR_TIDY_CONFIG",
      expandVars("$XDG_CONFIG_HOME/alatar/tidy.toml"))
  except CatchableError:
    getEnv("ALATAR_TIDY_CONFIG",
      getHomeDir() / ".config" / "alatar" / "tidy.toml")

proc cmdTidy(targets: seq[string], config = defaultTidyConfig(),
             dry = false, ask = false, recursive = false) =
  if targets.len == 0:
    quit "alatar: tidy expects at least one file or directory", 2
  let rules =
    try:
      loadTidyFile(config)
    except CatchableError as e:
      quit "alatar: " & e.msg, 1
  var plans: seq[Placement]
  for target in targets:
    if dirExists(target):
      try:
        plans.add plan(rules, target, recursive)
      except CatchableError as e:
        quit "alatar: " & e.msg, 1
    elif fileExists(target) or symlinkExists(target):
      try:
        plans.add planFile(rules, target)
      except CatchableError as e:
        quit "alatar: " & e.msg, 1
    else:
      quit "alatar: no such file or directory '" & target & "'", 1
  if plans.len == 0:
    echo "everything in place."
    return
  if dry:
    for p in plans:
      echo p.source, "  ->  ", p.targetOf
    quit 1
  try:
    applyMoves(plans, ask)
  except TidyError as e:
    quit "alatar: " & e.msg, 1

proc cmdAppImages(dirs: seq[string], dry = false) =
  ## Ensure every AppImage in a directory can be launched from the desktop:
  ## chmod +x the ones that lack the execute bit and create the missing
  ## .desktop entries (extracted from the AppImages themselves, icons
  ## included), which is what wofi and friends list. Default DIR is the
  ## AppImage home.
  var targets = dirs
  if targets.len == 0:
    targets = @[appImageHome()]
  var broken = 0
  for dir in targets:
    try:
      broken += integrateDir(dir, dry)
    except AppImageError as e:
      quit "alatar: " & e.msg, 1
    except CatchableError as e:
      quit "alatar: " & e.msg, 1
  if broken == 0:
    echo "every AppImage integrated."
    return
  if dry:
    quit 1

template withControls(body: untyped) =
  try:
    body
  except ControlError as e:
    quit "alatar: " & e.msg, 1

proc stepArg(arguments: seq[string], index: int, default: int): int =
  if arguments.len > index and arguments[index].len > 0:
    try: return parseInt(arguments[index])
    except ValueError: discard
  default

proc reportNode(node: AudioNode) =
  echo (if node.preferred: "* " else: "  "), node.description, "  ",
    node.volume, "%", (if node.muted: " muted" else: ""), "  ", node.name

proc cmdAudioNode(node: AudioNode, arguments: seq[string]) =
  let sameKind = if node.kind == sink: sinks() else: sources()
  if arguments.len == 0:
    for device in sameKind:
      if device.name == node.name:
        echo device.volume, "%", (if device.muted: " muted" else: ""), "  ",
          device.description
        return
    return
  case arguments[0]
  of "status": cmdAudioNode(node, @[])
  of "up":
    nudgeVolume(node, stepArg(arguments, 1, 5))
    cmdAudioNode(node, @[])
  of "down":
    nudgeVolume(node, -stepArg(arguments, 1, 5))
    cmdAudioNode(node, @[])
  of "set":
    setVolume(node, stepArg(arguments, 1, 0))
    cmdAudioNode(node, @[])
  of "mute":
    setMuted(node, true)
    cmdAudioNode(node, @[])
  of "unmute":
    setMuted(node, false)
    cmdAudioNode(node, @[])
  of "toggle": echo (if toggleMuted(node): "muted" else: "unmuted")
  of "devices":
    for device in sameKind:
      reportNode(device)
  of "use":
    if arguments.len < 2: quit "alatar: use needs a device name", 2
    for device in sameKind:
      if device.name == arguments[1] or device.description == arguments[1]:
        setPreferred(device)
        echo "default ", $device.kind, ": ", device.description
        return
    quit "alatar: no audio device '" & arguments[1] & "'", 1
  else: quit "alatar: unknown audio verb '" & arguments[0] & "'", 2

proc cmdSound(arguments: seq[string]) =
  ## Control the default audio output (sink).
  withControls:
    cmdAudioNode(defaultSink(), arguments)

proc cmdMic(arguments: seq[string]) =
  ## Control the default audio input (source).
  withControls:
    cmdAudioNode(defaultSource(), arguments)

proc cmdWifi(arguments: seq[string]) =
  ## Control the Wi-Fi radio and connections.
  withControls:
    let action = if arguments.len > 0: arguments[0] else: "status"
    case action
    of "status":
      if not wifiEnabled():
        echo "Wi-Fi is off"; return
      for network in wifiNetworks():
        if network.connected:
          echo "connected to ", network.ssid, " (", network.signal, "%)"
          return
      echo "Wi-Fi is on, not connected"
    of "on", "off":
      setWifiEnabled(action == "on")
    of "toggle":
      setWifiEnabled(not wifiEnabled())
    of "networks":
      for network in wifiNetworks():
        echo (if network.connected: "* " else: "  "), network.ssid, "  ",
          network.signal, "%"
    of "connect":
      if arguments.len < 2: quit "alatar: connect needs an SSID", 2
      connectWifi(arguments[1 .. ^1].join(" "))
    else: quit "alatar: unknown wifi verb '" & action & "'", 2

proc cmdWired(arguments: seq[string]) =
  ## Control the wired connection.
  withControls:
    let action = if arguments.len > 0: arguments[0] else: "status"
    case action
    of "status":
      let connection = wiredConnection()
      if connection.device.len == 0: echo "No wired device"
      elif connection.name.len > 0: echo "connected: ", connection.name
      else: echo "disconnected: ", connection.device
    of "on", "off":
      setWiredEnabled(action == "on")
    of "toggle":
      setWiredEnabled(wiredConnection().name.len == 0)
    else: quit "alatar: unknown wired verb '" & action & "'", 2

proc cmdBluetooth(arguments: seq[string]) =
  ## Control the Bluetooth adapter and devices.
  withControls:
    let action = if arguments.len > 0: arguments[0] else: "status"
    case action
    of "status":
      if not bluetoothAvailable():
        echo "Bluetooth daemon is not running"
      elif bluetoothEnabled():
        echo "Bluetooth is on"
      else:
        echo "Bluetooth is off"
    of "on", "off":
      setBluetoothEnabled(action == "on")
    of "toggle":
      setBluetoothEnabled(not bluetoothEnabled())
    of "devices":
      for device in bluetoothDevices():
        echo (if device.connected: "* " else: "  "), device.name, "  ",
          device.address, (if device.battery > 0: "  " & $device.battery & "%"
                           else: "")
    of "connect", "disconnect":
      if arguments.len < 2: quit "alatar: " & action & " needs an address", 2
      if action == "connect": connectBluetooth(arguments[1])
      else: disconnectBluetooth(arguments[1])
    else: quit "alatar: unknown bluetooth verb '" & action & "'", 2

proc start*() {.raises: [].} =
  try:
    dispatchMulti(
      ("multi", cmdName = "alatar", doc = alatarDoc, usage = alatarUsage),
      (cmdInstall, cmdName = "install", help = {"dir": dirHelp}),
      (cmdUninstall, cmdName = "uninstall", help = {"dir": dirHelp}),
      (cmdStatus, cmdName = "status", positional = "names",
       help = {"dir": dirHelp,
               "reasons": "max Error reasons to print per module (0 = all)"}),
      (cmdModules, cmdName = "modules", help = {"dir": dirHelp}),
      (cmdInfo, cmdName = "info", help = {"dir": dirHelp}),
      (cmdTidy, cmdName = "tidy", positional = "targets",
       doc = "Sort files into their homes per tidy.toml rules; --dry reports " &
         "what is out of place (exit 1 if anything is) and moves nothing.",
       help = {"config": "rules file [env: ALATAR_TIDY_CONFIG; default: " &
                "$XDG_CONFIG_HOME/alatar/tidy.toml]",
                "dry": "list misplaced files and exit 1, move nothing",
                "ask": "confirm every move with y/N",
                "recursive": "sort files in subdirectories too"}),
       (cmdAppImages, cmdName = "appimages", positional = "dirs",
        doc = "Make the AppImages in DIR launchable from wofi: chmod +x and " &
          "create missing .desktop entries; --dry reports (exit 1 if any) " &
          "and fixes nothing.",
        help = {"dirs": "AppImage directories [env: APPIMAGE_DIR; default: " &
                 "~/.local/bin]",
                 "dry": "list un-integrated AppImages and exit 1, fix nothing"}),
      (cmdSound, cmdName = "sound", positional = "arguments",
       doc = "Control the default audio output: [status] | up|down [STEP] | " &
         "set N | mute|unmute|toggle | devices | use NAME.",
       help = {"arguments": "verb plus optional parameter, e.g. 'up 10'"}),
      (cmdMic, cmdName = "mic", positional = "arguments",
       doc = "Control the default audio input: [status] | up|down [STEP] | " &
         "set N | mute|unmute|toggle | devices.",
       help = {"arguments": "verb plus optional parameter, e.g. 'mute'"}),
      (cmdWifi, cmdName = "wifi", positional = "arguments",
       doc = "Control Wi-Fi: [status] | on|off|toggle | networks | " &
         "connect SSID...",
       help = {"arguments": "verb plus optional parameter, e.g. " &
                "'connect My Network'"}),
      (cmdWired, cmdName = "wired", positional = "arguments",
       doc = "Control the wired connection: [status] | on|off|toggle.",
       help = {"arguments": "verb, e.g. 'off'"}),
      (cmdBluetooth, cmdName = "bluetooth", positional = "arguments",
       doc = "Control Bluetooth: [status] | on|off|toggle | devices | " &
         "connect|disconnect ADDRESS.",
       help = {"arguments": "verb plus optional parameter, e.g. " &
                "'connect 80:EA:9C:00:00:00'"}))
  except:
    quit "alatar: " & getCurrentExceptionMsg(), 1

when isMainModule:
  start()
