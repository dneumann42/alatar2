import std/[os, osproc, strutils, sugar, posix, terminal]

import parsetoml

type
  PackageSource* = enum
    arch
    aur
    flatpak

  PackageSpec = object
    name: string
    source: PackageSource
    before = false
    tags: seq[string]

  PackageError* = object of CatchableError

# Read-only accessors: fields stay private so specs cannot be mutated from
# outside (e.g. by the CLI), but can be inspected.
proc name*(pkg: PackageSpec): string = pkg.name
proc source*(pkg: PackageSpec): PackageSource = pkg.source
proc before*(pkg: PackageSpec): bool = pkg.before
proc tags*(pkg: PackageSpec): seq[string] = pkg.tags

proc fromStr*(T: typedesc[PackageSource], str: string): T {.raises: [PackageError].} =
  for s in low(T) .. high(T):
    if str == $s:
      return s
  raise newException(PackageError, "Unknown package source: " & str)

proc load*(T: typedesc[PackageSpec], tbl: TomlValueRef): T {.raises: [PackageError, ValueError].} =
  let tags = block:
    let ts = tbl.getOrDefault("tags")
    if ts.isNil:
      newSeq[string]()
    else:
      collect(for ti in 0 ..< ts.len: ts[ti].getStr())
  result = T(
    name: tbl["name"].getStr(),
    source: PackageSource.fromStr tbl["source"].getStr(),
    before: tbl.getOrDefault("before").getBool(false),
    tags: tags
  )

proc loadSpecFile*(path: string): seq[PackageSpec] {.raises: [IOError, PackageError].} =
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  if not path.endsWith("packages.toml"):
    raise newException(PackageError, "Spec files have .packages.toml extensions")
  let content = readFile(path)
  try:
    let table = parsetoml.parseString(content)
    let packages = table.getOrDefault("package")
    if packages.isNil:
      return # empty / package-less spec file
    for i in 0 ..< packages.len:
      result.add(PackageSpec.load(packages[i]))
  except Exception:
    raise newException(PackageError, "Failed to parse '" & path & "': " & getCurrentExceptionMsg())

proc runCmd(cmd: string, args: seq[string], workingDir = "", quiet = false): int {.raises: [PackageError].} =
  var options: set[ProcessOption] = {poUsePath}
  if not quiet: options.incl poParentStreams
  try:
    let p = startProcess(command = cmd, workingDir = workingDir, args = args, options = options)
    try:
      result = p.waitForExit()
    finally:
      close(p)
  except CatchableError as e:
    raise newException(PackageError, "Failed to run '" & cmd & " " & args.join(" ") & "': " & e.msg, e)

proc checkCmd(cmd: string, args: seq[string], workingDir = "") {.raises: [PackageError].} =
  let exitCode = runCmd(cmd, args, workingDir)
  if exitCode != 0:
    raise newException(PackageError, "'" & cmd & " " & args.join(" ") & "' failed with exit code " & $exitCode)

var
  elevationTool = "" # memoised privilegedHelper() result; "none" when neither exists
  sudoAuthKeepAlive: Process # nil unless the keep-alive loop is running

proc hasExe(name: string): bool =
  ## findExe raises when the environment cannot be read; for a presence
  ## check "unknown" simply means "not usable as an option".
  try: findExe(name).len > 0 except OSError: false

proc privilegedHelper(): string {.raises: [PackageError].} =
  ## The tool alatar escalates through: "sudo" or "pkexec".
  ##
  ## sudo wins whenever we have a terminal to prompt on: sudo caches
  ## credentials per tty (timestamp_type default), so the password typed
  ## once covers every later sudo call in the run - including the ones
  ## paru makes internally. pkexec re-opens a polkit agent dialog on every
  ## invocation, which is exactly the repeated prompting we want to avoid.
  ## pkexec is the fallback when sudo is missing or there is no terminal
  ## (alatar launched from a GUI), where the agent dialog is the only way
  ## to ask for a password.
  if elevationTool.len > 0:
    if elevationTool == "none":
      raise newException(PackageError,
        "No way to run commands as root: neither sudo nor pkexec found")
    return elevationTool
  let
    haveSudo = hasExe("sudo")
    havePkexec = hasExe("pkexec")
  result =
    if haveSudo and isatty(stdin): "sudo"
    elif havePkexec: "pkexec"
    elif haveSudo: "sudo"
    else: ""
  if result.len == 0:
    elevationTool = "none"
    raise newException(PackageError,
      "No way to run commands as root: neither sudo nor pkexec found")
  elevationTool = result

proc ensureSudoAuth() {.raises: [PackageError].} =
  ## Ask for the sudo password once up front, then keep the timestamp alive
  ## in the background for the rest of the run. Without the keep-alive,
  ## sudo's five-minute cache lapses in the middle of a long AUR build and
  ## the password has to be typed again. The loop renews the timestamp every
  ## minute while alatar lives (kill -0 $PPID) and ends on its own as soon
  ## as sudo stops honouring the cache, so a crashed alatar never leaves a
  ## permanently warm sudo behind.
  checkCmd("sudo", @["-v"])
  if sudoAuthKeepAlive.isNil:
    try:
      sudoAuthKeepAlive = startProcess(
        command = "sh",
        args = @["-c", "while kill -0 $PPID 2>/dev/null && " &
          "sudo -n true >/dev/null 2>&1; do sleep 60; done"],
        options = {poUsePath})
    except OSError, IOError:
      raise newException(PackageError,
        "Failed to start the sudo keep-alive loop: " & getCurrentExceptionMsg())

proc stopSudoAuthKeepAlive*() =
  ## Ends the keep-alive loop (see ensureSudoAuth). The sudo timestamp
  ## itself is left in place, just as a normal sudo session would.
  if not sudoAuthKeepAlive.isNil:
    sudoAuthKeepAlive.terminate()
    close(sudoAuthKeepAlive)
    sudoAuthKeepAlive = nil

proc runPrivileged*(cmd: string, args: seq[string]) {.raises: [PackageError].} =
  # Elevate through the sudo/pkexec helper unless we already are root. Fresh
  # installs may not have polkit yet (it is itself installed by a module),
  # but sudo comes in from setup either way, and privilegedHelper reports a
  # clear error if neither tool is around.
  if geteuid() == 0:
    checkCmd(cmd, args)
    return
  let exe =
    try:
      findExe(cmd)
    except OSError as e:
      raise newException(PackageError, "Required program not found: " & cmd, e)
  if exe.len == 0:
    raise newException(PackageError, "Required program not found: " & cmd)
  let helper = privilegedHelper()
  if helper == "sudo":
    ensureSudoAuth()
  checkCmd(helper, @[exe] & args)

proc installAurFromSource(name: string) {.raises: [PackageError].} =
  # Bootstrap path for AUR packages marked before = true: paru may not be
  # installed yet, so build from the AUR git repo with makepkg and hand the
  # resulting package file to pacman.
  let dir = getTempDir() / ("alatar-aur-" & name)
  try:
    checkCmd("git", @["clone", "--depth", "1", "https://aur.archlinux.org/" & name & ".git", dir])
    checkCmd("makepkg", @["-sc", "--noconfirm"], workingDir = dir)
    var pkgFiles: seq[string]
    for kind, path in walkDir(dir):
      if kind == pcFile and ".pkg.tar." in path.lastPathPart:
        pkgFiles.add path
    if pkgFiles.len == 0:
      raise newException(PackageError, "makepkg produced no package file for AUR package '" & name & "'")
    runPrivileged("pacman", @["-U", "--noconfirm"] & pkgFiles)
  except OSError as e:
    raise newException(PackageError, "Failed to inspect build directory for AUR package '" & name & "': " & e.msg, e)
  finally:
    try:
      removeDir(dir)
    except OSError, IOError:
      discard

proc isInstalled*(pkg: PackageSpec): bool {.raises: [PackageError].} =
  case pkg.source
  of arch, aur:
    # Anything installed from the repos or via makepkg/pacman ends up in the
    # local pacman database.
    runCmd("pacman", @["-Q", "--", pkg.name], quiet = true) == 0
  of flatpak:
    # 'flatpak info <id>' exits 0 only when the app/runtime is present.
    runCmd("flatpak", @["info", pkg.name], quiet = true) == 0

proc ensureFlathub() {.raises: [PackageError].} =
  # Fresh systems have no flatpak remotes; installs name the flathub remote
  # explicitly, so add it once (idempotent) before the first install.
  runPrivileged("flatpak",
    @["remote-add", "--if-not-exists", "flathub",
      "https://flathub.org/repo/flathub.flatpakrepo"])

proc install*(pkg: PackageSpec) {.raises: [PackageError].} =
  ## Installs the package unless it is already present (see isInstalled).
  ## The makepkg path especially needs this: pacman -U would otherwise
  ## rebuild and reinstall e.g. paru from source on every run.
  if pkg.isInstalled():
    return
  case pkg.source
  of arch:
    if pkg.before:
      runPrivileged("pacman", @["-S", "--needed", "--noconfirm", "--", pkg.name])
    else:
      checkCmd("paru", @["-S", "--needed", "--noconfirm", "--skipreview", "--noprovides", "--useask", "--assume-installed", "scenefx0.5", "--assume-installed", "mopidy=4.0.0", "--", pkg.name])
  of aur:
    if pkg.before:
      installAurFromSource(pkg.name)
    else:
      checkCmd("paru", @["-S", "--needed", "--noconfirm", "--skipreview", "--noprovides", "--useask", "--assume-installed", "scenefx0.5", "--assume-installed", "mopidy=4.0.0", "--", pkg.name])
  of flatpak:
    ensureFlathub()
    runPrivileged("flatpak", @["install", "-y", "flathub", pkg.name])

proc installAll*(specs: seq[PackageSpec]) {.raises: [PackageError].} =
  # Already-installed packages are skipped before anything is dispatched,
  # so a re-run costs one `pacman -Q` per package instead of AUR rebuilds.
  # What is missing is then batched per manager, bootstrap
  # (before = true) first via pacman / git+makepkg, then everything else
  # through paru (which covers both arch and AUR) and flatpak.
  var
    pacmanPkgs, paruPkgs, aurBootPkgs, flatpakPkgs: seq[string]
  var failures: seq[string]
  for spec in specs:
    var missing = true
    try:
      missing = not spec.isInstalled()
    except PackageError as e:
      failures.add "Could not verify '" & spec.name & "', installing anyway: " & e.msg
    if not missing:
      continue
    if spec.source == flatpak:
      flatpakPkgs.add spec.name
    elif spec.before:
      if spec.source == aur: aurBootPkgs.add spec.name
      else: pacmanPkgs.add spec.name
    else:
      paruPkgs.add spec.name

  template step(body: untyped) =
    try:
      body
    except PackageError as e:
      failures.add e.msg

  if pacmanPkgs.len > 0:
    step runPrivileged("pacman", @["-S", "--needed", "--noconfirm", "--"] & pacmanPkgs)
  for name in aurBootPkgs:
    step installAurFromSource(name)
  if paruPkgs.len > 0:
    step checkCmd("paru", @["-S", "--needed", "--noconfirm", "--skipreview", "--noprovides", "--useask", "--assume-installed", "scenefx0.5", "--assume-installed", "mopidy=4.0.0", "--"] & paruPkgs)
  if flatpakPkgs.len > 0:
    step ensureFlathub()
    step runPrivileged("flatpak", @["install", "-y", "flathub"] & flatpakPkgs)

  if failures.len > 0:
    raise newException(PackageError, "Package installation failed:\n" & failures.join("\n"))

proc uninstallAll*(specs: seq[PackageSpec]) {.raises: [PackageError].} =
  # Reverse of installAll: tear down non-bootstrap packages first, leave the
  # before = true bootstrap packages for last.
  var
    pacmanPkgs, paruPkgs, flatpakPkgs: seq[string]
  var failures: seq[string]
  for spec in specs:
    var installed = false
    try:
      installed = spec.isInstalled()
    except PackageError as e:
      failures.add e.msg
      continue
    if not installed:
      continue
    if spec.source == flatpak:
      flatpakPkgs.add spec.name
    elif spec.before:
      pacmanPkgs.add spec.name
    else:
      paruPkgs.add spec.name

  template step(body: untyped) =
    try:
      body
    except PackageError as e:
      failures.add e.msg

  if flatpakPkgs.len > 0:
    step runPrivileged("flatpak", @["uninstall", "-y"] & flatpakPkgs)
  if paruPkgs.len > 0:
    step checkCmd("paru", @["-Rns", "--noconfirm", "--"] & paruPkgs)
  if pacmanPkgs.len > 0:
    step runPrivileged("pacman", @["-Rns", "--noconfirm", "--"] & pacmanPkgs)

  if failures.len > 0:
    raise newException(PackageError, "Package removal failed:\n" & failures.join("\n"))

discard """
let p = startProcess(
  "pkexec",
  args = @["/usr/bin/id", "-u"],
  options = {poParentStreams}
)
let exitCode = waitForExit(p)
close(p)

if exitCode != 0:
  quit("Privileged command failed or was cancelled", exitCode)
"""
