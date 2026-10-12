import std/[os, osproc, streams, strutils]

type
  ServiceKind* = enum
    service
    timer

  ServiceSpec = object
    unitName*: string   # e.g. "wallpaper.service"
    kind*: ServiceKind
    sourcePath*: string

  ServiceError* = object of CatchableError

proc userUnitDir(): string {.raises: [].} =
  (getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "systemd" / "user")

proc systemctlCmd(args: seq[string]): int {.raises: [ServiceError].} =
  try:
    let p = startProcess(command = "systemctl", args = @["--user"] & args,
                         options = {poUsePath, poParentStreams})
    try:
      result = p.waitForExit()
    finally:
      close(p)
  except CatchableError as e:
    raise newException(ServiceError,
      "Failed to run 'systemctl --user " & args.join(" ") & "': " & e.msg, e)

proc systemctlCheck(args: seq[string]) {.raises: [ServiceError].} =
  let exitCode = systemctlCmd(args)
  if exitCode != 0:
    raise newException(ServiceError,
      "'systemctl --user " & args.join(" ") & "' failed with exit code " & $exitCode)

proc systemctlCapture(args: seq[string]): string {.raises: [ServiceError].} =
  ## Returns trimmed stdout of `systemctl --user <args>`. Failed or unknown
  ## units print to stderr, so empty output here means "not installed".
  try:
    let p = startProcess(command = "systemctl", args = @["--user"] & args,
                         options = {poUsePath})
    var output = ""
    while not p.outputStream.atEnd():
      output.add p.outputStream.readLine()
      output.add '\n'
    discard p.waitForExit()
    close(p)
    result = output.strip
  except CatchableError as e:
    raise newException(ServiceError,
      "Failed to run 'systemctl --user " & args.join(" ") & "': " & e.msg, e)

proc loadServices*(moduleDir: string): seq[ServiceSpec] {.raises: [OSError].} =
  ## Finds '<name>.service.toml' and '<name>.timer.toml' files in a module
  ## directory. The '.toml' suffix is stripped for the installed unit name.
  for walkKind, path in walkDir(moduleDir):
    if walkKind != pcFile: continue
    let tail = path.lastPathPart
    if tail.endsWith(".service.toml") or tail.endsWith(".timer.toml"):
      let unitName = tail[0 ..< tail.len - ".toml".len]
      let kind = if unitName.endsWith(".service"): service else: timer
      result.add ServiceSpec(unitName: unitName, kind: kind, sourcePath: path)

proc installServices*(svcs: seq[ServiceSpec]) {.raises: [ServiceError].} =
  if svcs.len == 0: return
  let dir = userUnitDir()
  var failures: seq[string]
  for svc in svcs:
    let dest = dir / svc.unitName
    try:
      createDir(dest.parentDir)
      copyFile(svc.sourcePath, dest)
    except CatchableError as e: # OSError, IOError
      failures.add "Failed to install unit '" & svc.unitName & "': " & e.msg
  try:
    systemctlCheck(@["daemon-reload"])
  except ServiceError as e:
    failures.add e.msg
  for svc in svcs:
    try:
      systemctlCheck(@["enable", "--now", svc.unitName])
    except ServiceError as e:
      failures.add e.msg
  if failures.len > 0:
    raise newException(ServiceError, "Service installation failed:\n" & failures.join("\n"))

proc isInstalled*(svc: ServiceSpec): bool {.raises: [ServiceError].} =
  ## A unit counts as installed when its unit file is in place and matches
  ## the module source, and the unit is enabled (or statically triggered, as
  ## timer-activated services are) and active.
  let dest = userUnitDir() / svc.unitName
  if not fileExists(dest):
    return false
  try:
    if readFile(dest) != readFile(svc.sourcePath):
      return false
  except CatchableError as e: # OSError, IOError
    raise newException(ServiceError,
      "Failed to compare unit '" & svc.unitName & "': " & e.msg, e)
  let enabled = systemctlCapture(@["is-enabled", svc.unitName])
  if enabled notin ["enabled", "enabled-runtime", "static", "alias"]:
    return false
  let active = systemctlCapture(@["is-active", svc.unitName])
  active == "active"

proc uninstallServices*(svcs: seq[ServiceSpec]) {.raises: [ServiceError].} =
  if svcs.len == 0: return
  var failures: seq[string]
  var removedAny = false
  for svc in svcs:
    let dest = userUnitDir() / svc.unitName
    if not fileExists(dest):
      continue
    removedAny = true
    try:
      systemctlCheck(@["disable", "--now", svc.unitName])
    except ServiceError as e:
      failures.add e.msg # keep going; the unit may be stopped already
    try:
      removeFile(dest)
    except CatchableError as e: # OSError, IOError
      failures.add "Failed to remove unit '" & svc.unitName & "': " & e.msg
  if removedAny:
    try:
      systemctlCheck(@["daemon-reload"])
    except ServiceError as e:
      failures.add e.msg
  if failures.len > 0:
    raise newException(ServiceError, "Service removal failed:\n" & failures.join("\n"))
