import std/[os, osproc, strutils, sugar, posix]

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

proc runPrivileged(cmd: string, args: seq[string]) {.raises: [PackageError].} =
  # Elevate through pkexec unless we already are root.
  if geteuid() == 0:
    checkCmd(cmd, args)
  else:
    let exe =
      try:
        findExe(cmd)
      except OSError as e:
        raise newException(PackageError, "Required program not found: " & cmd, e)
    if exe.len == 0:
      raise newException(PackageError, "Required program not found: " & cmd)
    checkCmd("pkexec", @[exe] & args)

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
      checkCmd("paru", @["-S", "--needed", "--noconfirm", "--", pkg.name])
  of aur:
    if pkg.before:
      installAurFromSource(pkg.name)
    else:
      checkCmd("paru", @["-S", "--needed", "--noconfirm", pkg.name])
  of flatpak:
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
    step checkCmd("paru", @["-S", "--needed", "--noconfirm", "--"] & paruPkgs)
  if flatpakPkgs.len > 0:
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
