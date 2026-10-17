import std/[os, strutils, sequtils]
import terminal

import alatar/[modules, packages, repos, services, symlinks]

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
  ## Entries in a module's symlink.toml are linked last, before its units.
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
  ## left alone; other modules may still use them.
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
      (cmdInfo, cmdName = "info", help = {"dir": dirHelp}))
  except:
    quit "alatar: " & getCurrentExceptionMsg(), 1

when isMainModule:
  start()
