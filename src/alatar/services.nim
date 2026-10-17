import std/[os, osproc, posix, streams, strutils]

type
  ServiceKind* = enum
    service
    timer
    target

  ServiceSpec* = object
    unitName*: string   # e.g. "wallpaper.service"
    kind*: ServiceKind
    sourcePath*: string

  ServiceError* = object of CatchableError

const
  sessionTargetSuffix = "-session.target"
    # Targets activated by a compositor session (sway-session.target,
    # graphical-session.target, ...). Units tied to one only work while that
    # session is running.

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

proc isSessionTarget*(svc: ServiceSpec): bool =
  ## A target that a compositor session activates rather than the login
  ## default.target, e.g. "sway-session.target".
  svc.kind == target and svc.unitName.endsWith(sessionTargetSuffix)

proc needsSession*(svc: ServiceSpec): bool =
  ## Whether a unit only works inside a running graphical session: it is a
  ## `*-session.target`, or one of its (non-comment) [Unit] relationships
  ## names one - wallpaper.service and polkit-gnome.service point at
  ## sway-session.target that way.
  if svc.isSessionTarget:
    return true
  if not fileExists(svc.sourcePath):
    return false
  try:
    for line in readFile(svc.sourcePath).splitLines:
      let entry = line.strip
      if entry.len == 0 or entry[0] == '#' or entry[0] == ';':
        continue # systemd comments: only real directives count
      if sessionTargetSuffix in entry:
        return true
  except CatchableError:
    discard
  return false

proc sessionLive*(): bool {.raises: [ServiceError].} =
  ## Whether a Wayland compositor has published itself to the user manager.
  ## sway does that on startup (scripts/start-session-services.sh runs
  ## `systemctl --user import-environment WAYLAND_DISPLAY` before it activates
  ## the session target), so the variable is the signal that session-bound
  ## units have a compositor to talk to. Read from the manager, not from this
  ## process's environment: alatar may run over SSH or from a TTY.
  var display, runtimeDir = ""
  for line in systemctlCapture(@["show-environment"]).splitLines:
    let eq = line.find('=')
    if eq <= 0: continue
    let value = line[eq + 1 ..< line.len].strip
    case line[0 ..< eq]
    of "WAYLAND_DISPLAY": display = value
    of "XDG_RUNTIME_DIR": runtimeDir = value
    else: discard
  if display.len == 0:
    return false
  if runtimeDir.len == 0:
    runtimeDir = getEnv("XDG_RUNTIME_DIR", "/run/user/" & $getuid())
  # Nothing unsets WAYLAND_DISPLAY when sway exits, so the variable alone can
  # outlive the compositor: insist on the socket it points at. Without that,
  # `alatar install` on a TTY after logging out of sway would still start the
  # session units (and watch them fail).
  let socket = runtimeDir / display
  access(socket.cstring, F_OK) == 0

proc loadServices*(moduleDir: string): seq[ServiceSpec] {.raises: [OSError].} =
  ## Finds '<name>.service.toml', '<name>.timer.toml' and '<name>.target.toml'
  ## files in a module directory. The '.toml' suffix is stripped for the
  ## installed unit name.
  for walkKind, path in walkDir(moduleDir):
    if walkKind != pcFile: continue
    let tail = path.lastPathPart
    if tail.endsWith(".service.toml") or tail.endsWith(".timer.toml") or
        tail.endsWith(".target.toml"):
      let unitName = tail[0 ..< tail.len - ".toml".len]
      let kind =
        if unitName.endsWith(".service"): service
        elif unitName.endsWith(".timer"): timer
        else: target
      result.add ServiceSpec(unitName: unitName, kind: kind, sourcePath: path)

proc isActive(svc: ServiceSpec): bool {.raises: [ServiceError].} =
  systemctlCapture(@["is-active", svc.unitName]) == "active"

proc unitFileDiffers(svc: ServiceSpec): bool {.raises: [ServiceError].} =
  ## Whether the installed unit file is missing or differs from the module
  ## source. Comparing before writing matters: re-copying an identical file
  ## would bump its mtime and make every install look like a change.
  let dest = userUnitDir() / svc.unitName
  if not fileExists(dest):
    return true
  if not fileExists(svc.sourcePath):
    return false
  try:
    result = readFile(dest) != readFile(svc.sourcePath)
  except CatchableError as e: # OSError, IOError
    raise newException(ServiceError,
      "Failed to compare unit '" & svc.unitName & "': " & e.msg, e)

proc installServices*(svcs: seq[ServiceSpec]): seq[ServiceSpec] {.
    raises: [ServiceError].} =
  ## Installs and enables a module's units, and returns the session-bound ones
  ## for the caller to start once the whole module tree is in place
  ## (see `startSessionUnits`).
  ##
  ## Nothing that needs a compositor is started here: `alatar install` usually
  ## runs on a TTY or over SSH, where awww-daemon and the polkit agent have no
  ## Wayland socket to connect to and would crash-loop until sway shows up.
  ## Enabling is enough - sway activates sway-session.target, which pulls the
  ## units in via their WantedBy= lines.
  if svcs.len == 0: return
  let dir = userUnitDir()
  var failures: seq[string]
  var sessionRestart: seq[ServiceSpec]
  var wroteAny = false
  for svc in svcs:
    let dest = dir / svc.unitName
    var differs = false
    try:
      differs = unitFileDiffers(svc)
    except ServiceError as e:
      failures.add e.msg
      continue
    if differs:
      # A changed unit file only takes effect on a running service after a
      # restart. Session services are bounced (stateless: the wallpaper is
      # redrawn, the agent re-registers); for the rest alatar says so instead,
      # because restarting e.g. the emacs daemon would destroy state nobody
      # asked to lose. Targets are never bounced: stopping one stops whatever
      # is bound to it.
      if svc.kind != target:
        try:
          if isActive(svc):
            if svc.needsSession:
              sessionRestart.add svc
            else:
              echo "alatar: ", svc.unitName,
                " unit file changed - restart it to apply"
        except ServiceError as e:
          failures.add e.msg
      try:
        createDir(dest.parentDir)
        copyFile(svc.sourcePath, dest)
        wroteAny = true
      except CatchableError as e: # OSError, IOError
        failures.add "Failed to install unit '" & svc.unitName & "': " & e.msg
  if wroteAny:
    try:
      systemctlCheck(@["daemon-reload"])
    except ServiceError as e:
      failures.add e.msg
  var sessionUnits: seq[ServiceSpec]
  for svc in svcs:
    try:
      if svc.needsSession:
        # Services and timers get enabled so the session target pulls them in;
        # the target itself is static (no [Install] section) - sway activates
        # it, so there is nothing to enable and nothing to start out of session.
        if svc.kind != target:
          systemctlCheck(@["enable", svc.unitName])
        sessionUnits.add svc
      elif svc.kind == target:
        # Targets that are not tied to a session have nothing to enable; they
        # are pulled in by other units' WantedBy or pulled up here.
        systemctlCheck(@["start", svc.unitName])
      else:
        systemctlCheck(@["enable", "--now", svc.unitName])
    except ServiceError as e:
      failures.add e.msg
  for svc in sessionRestart:
    # After the enable pass, so a unit that was only just enabled is not
    # started and restarted in two goes.
    try:
      systemctlCheck(@["restart", svc.unitName])
    except ServiceError as e:
      failures.add e.msg
  if failures.len > 0:
    raise newException(ServiceError, "Service installation failed:\n" & failures.join("\n"))
  result = sessionUnits

proc startSessionUnits*(svcs: seq[ServiceSpec]) {.raises: [ServiceError].} =
  ## Starts the session-bound units collected by `installServices`, but only
  ## while a compositor is actually running; outside a session they stay
  ## enabled and inert until sway activates its target.
  ##
  ## Call this after the full module tree is installed: a unit's ExecStart or
  ## ExecStartPost may name a script that only exists once a (sub)module's
  ## symlinks are linked, and a target that is already active will not pull in
  ## units enabled later - which is why the services are also asked for by
  ## name.
  if svcs.len == 0: return
  if not sessionLive():
    return
  var failures: seq[string]
  for svc in svcs:
    # Targets first, so the services find the session they belong to.
    if svc.kind == target:
      try:
        systemctlCheck(@["--no-block", "start", svc.unitName])
      except ServiceError as e:
        failures.add e.msg
  for svc in svcs:
    if svc.kind != target:
      try:
        systemctlCheck(@["--no-block", "start", svc.unitName])
      except ServiceError as e:
        failures.add e.msg
  if failures.len > 0:
    raise newException(ServiceError,
      "Starting session units failed:\n" & failures.join("\n"))

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
  # Session-bound units only run inside the compositor session, so outside one
  # being enabled is all alatar can verify. With a live session they must also
  # be running - that is what catches "no wallpaper when I start sway".
  if svc.needsSession and not sessionLive():
    return true
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
      case svc.kind
      of service, timer:
        systemctlCheck(@["disable", "--now", svc.unitName])
      of target:
        systemctlCheck(@["stop", svc.unitName])
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
