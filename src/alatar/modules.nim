import std/[os, strutils, sequtils]

import alatar/[packages, repos, services, symlinks]

type
  ModuleStatus* = enum Installed, Error, NotInstalled
  Module* = object
    name*: string
    dependencies*: seq[string]
    subModules*: seq[Module]

  ModuleRegistery* = object
    moduleDir*: string
    modules*: seq[Module]

  ResolvedModule* = object
    found*: bool
    module*: Module
    parentDir*: string ## directory *containing* the module directory

  ModuleError* = object of CatchableError

proc loadModules*(moduleDir: string): seq[Module] {.raises: [IOError, OSError].} =
  for kind, path in walkDir(moduleDir):
    if kind != pcDir:
      continue
    # Directories starting with "_" hold the module's own files (e.g. dotfiles
    # in desktop/_config), not submodules.
    if lastPathPart(path).startsWith("_"):
      continue
    var module = Module()
    module.name = lastPathPart(path)
    module.subModules = loadModules(path)
    let deps = path / "dependencies"
    if fileExists(deps):
      module.dependencies =
        readFile(deps).splitLines().filterIt(it.strip.len > 0).mapIt(it.strip)
    result.add module

proc load*(reg: var ModuleRegistery, moduleDir: string) {.raises: [IOError, OSError].} =
  reg.moduleDir = moduleDir
  reg.modules = loadModules(moduleDir)

proc findInTree(modules: seq[Module], moduleDir: string, name: string): ResolvedModule =
  ## Searches top-level modules first, then descends into submodules.
  ## Module names are assumed to be unique within the tree.
  for m in modules:
    if m.name == name:
      return ResolvedModule(found: true, module: m, parentDir: moduleDir)
  for m in modules:
    result = findInTree(m.subModules, moduleDir / m.name, name)
    if result.found:
      return result

proc findModule*(reg: ModuleRegistery, name: string): ResolvedModule =
  ## Resolution result with `found == false` when no module matches.
  reg.modules.findInTree(reg.moduleDir, name)

proc packageFiles(dir: string): seq[string] {.raises: [OSError].} =
  ## Files in a module directory that hold package specs (skips
  ## submodules, services and the dependencies file).
  for kind, path in walkDir(dir):
    if kind == pcDir: continue
    if path.endsWith("packages.toml"):
      result.add path

proc installOwn*(module: Module, dir, modulesRoot: string): seq[ServiceSpec] {.
    raises: [PackageError, RepoError, ServiceError, SymlinkError,
             IOError, OSError].} =
  ## Installs only this module's own repositories, packages, symlinks and
  ## units; no dependency or submodule resolution (use the registry procs for
  ## that). Returns the session-bound units, which the caller starts once the
  ## whole module tree is in place (see `startSessionUnits`).
  # Repositories before packages: a package listed below can live in one of
  # them (steam needs [multilib], which archinstall leaves disabled).
  ensureRepos(loadRepos(dir))
  for path in packageFiles(dir):
    installAll(loadSpecFile(path))
  # Config symlinks before units: a unit may exec a script that only exists
  # once it is linked into place.
  installSymlinks(symlinkSpecs(dir, modulesRoot))
  # Units need their packages, so services come last.
  result = installServices(loadServices(dir))

proc installTree(module: Module, moduleDir, modulesRoot: string,
                 sessionUnits: var seq[ServiceSpec]) {.
    raises: [PackageError, RepoError, ServiceError, SymlinkError,
             IOError, OSError].} =
  let dir = moduleDir / module.name
  # Parent before children: a submodule's unit can need a package this module
  # installs (awww <-> theming/wallpaper.service) or bind to a target defined
  # here (sway-session.target <-> the session services below it).
  sessionUnits.add module.installOwn(dir, modulesRoot)
  for subModule in module.subModules:
    installTree(subModule, dir, modulesRoot, sessionUnits)

proc install*(module: Module, moduleDir, modulesRoot: string) {.
    raises: [PackageError, RepoError, ServiceError, SymlinkError,
             IOError, OSError].} =
  ## Tree install without dependency resolution. Modules listed in
  ## `dependencies` files are NOT installed here; prefer
  ## `install*(reg: ModuleRegistery, ...)`, which resolves them.
  var sessionUnits: seq[ServiceSpec]
  module.installTree(moduleDir, modulesRoot, sessionUnits)
  startSessionUnits(sessionUnits)

proc install*(reg: ModuleRegistery, moduleName: string) {.raises: [ModuleError].} =
  var done, pending: seq[string]
  var sessionUnits: seq[ServiceSpec]

  proc installResolved(res: ResolvedModule) {.raises: [ModuleError].} =
    let m = res.module
    if m.name in done:
      return # already installed in this run (diamond dependency)
    if m.name in pending:
      raise newException(ModuleError,
        "Dependency cycle detected at module: " & m.name)
    pending.add m.name

    try:
      # 1. Everything this module depends on, fully, before its own files.
      for dep in m.dependencies:
        let r = reg.findModule(dep)
        if not r.found:
          raise newException(ModuleError,
            "Unknown dependency module '" & dep & "' of '" & m.name & "'")
        installResolved(r)
      # 2. Own packages, symlinks and units - before the submodules, which may
      #    need this module's binaries or bind to its session target.
      sessionUnits.add m.installOwn(res.parentDir / m.name, reg.moduleDir)
      # 3. Submodules next; each resolves its own dependencies recursively.
      for sub in m.subModules:
        installResolved(ResolvedModule(found: true, module: sub, parentDir: res.parentDir / m.name))
    except CatchableError as e:
      raise newException(ModuleError,
        "Failed to install module '" & m.name & "': " & e.msg, e)
    finally:
      pending.setLen(pending.len - 1)

    done.add m.name

  let res = reg.findModule(moduleName)
  if not res.found:
    raise newException(ModuleError, "Unknown module: " & moduleName)
  installResolved(res)
  # 4. Last: bring up the units that need a compositor, but only if one is
  #    actually running. From a TTY or an SSH session they stay enabled and
  #    inert, and sway's session script starts them on the next login.
  try:
    startSessionUnits(sessionUnits)
  except ServiceError as e:
    raise newException(ModuleError,
      "Failed to start session units of module '" & moduleName & "': " & e.msg, e)

proc uninstall*(module: Module, moduleDir, modulesRoot: string) {.
    raises: [PackageError, ServiceError, SymlinkError, IOError, OSError].} =
  let dir = moduleDir / module.name
  # Reverse of install: submodules first (their units depend on this module's
  # packages and target), then this module's units, symlinks and packages.
  # Dependencies (other modules) are intentionally left alone; they may still
  # be in use.
  for subModule in module.subModules:
    subModule.uninstall(dir, modulesRoot)
  uninstallServices(loadServices(dir))
  uninstallSymlinks(symlinkSpecs(dir, modulesRoot))
  for path in packageFiles(dir):
    uninstallAll(loadSpecFile(path))

proc uninstall*(reg: ModuleRegistery, moduleName: string) {.raises: [ModuleError].} =
  let res = reg.findModule(moduleName)
  if not res.found:
    raise newException(ModuleError, "Unknown module: " & moduleName)
  try:
    res.module.uninstall(res.parentDir, reg.moduleDir)
  except CatchableError as e:
    raise newException(ModuleError, "Failed to uninstall module '" & moduleName & "': " & e.msg, e)

proc statusDetail*(reg: ModuleRegistery, moduleName: string): (ModuleStatus, seq[string]) =
  ## Status of a module plus human-readable reasons when the status is
  ## Error: which items are missing or unverifiable, or what config problem
  ## (cycle, unknown dependency, broken spec file) was found. Reasons are
  ## empty for Installed and NotInstalled.
  var total, installed = 0
  var missing, unverifiable: seq[string]
  var done, pending: seq[string]

  proc visit(res: ResolvedModule) {.raises: [ModuleError, PackageError, RepoError,
      ServiceError, SymlinkError, IOError, OSError].} =
    let m = res.module
    if m.name in done:
      return # count each module once, even with diamond dependencies
    if m.name in pending:
      raise newException(ModuleError,
        "Dependency cycle detected at module: " & m.name)
    pending.add m.name
    try:
      let dir = res.parentDir / m.name
      for repo in loadRepos(dir):
        inc total
        let item = m.name & ": repo '" & repo.name & "' [pacman.conf]"
        try:
          if repo.isInstalled(): inc installed
          else: missing.add item & " is not enabled"
        except RepoError as e:
          unverifiable.add item & " cannot be verified: " & e.msg
      for path in packageFiles(dir):
        for spec in loadSpecFile(path):
          inc total
          let item = m.name & ": package '" & spec.name & "' [" & $spec.source & "]"
          try:
            if spec.isInstalled(): inc installed
            else: missing.add item & " is not installed"
          except PackageError as e:
            unverifiable.add item & " cannot be verified: " & e.msg
      for svc in loadServices(dir):
        inc total
        let item = m.name & ": unit '" & svc.unitName & "'"
        try:
          if svc.isInstalled(): inc installed
          else: missing.add item & " is not installed, enabled or running"
        except ServiceError as e:
          unverifiable.add item & " cannot be verified: " & e.msg
      for spec in symlinkSpecs(dir, reg.moduleDir):
        inc total
        let item = m.name & ": symlink '" & spec.dest & "'"
        if spec.isInstalled(): inc installed
        else: missing.add item & " is not installed"
      for sub in m.subModules:
        visit(ResolvedModule(found: true, module: sub, parentDir: dir))
      for dep in m.dependencies:
        let r = reg.findModule(dep)
        if not r.found:
          raise newException(ModuleError,
            "Unknown dependency module '" & dep & "' of '" & m.name & "'")
        visit(r)
    finally:
      pending.setLen(pending.len - 1)
    done.add m.name

  try:
    let res = reg.findModule(moduleName)
    if not res.found:
      return (Error, @["Unknown module: " & moduleName])
    visit(res)
  except CatchableError as e:
    return (Error, @[e.msg])
  if installed == total:
    (Installed, @[])
  elif installed == 0 and unverifiable.len > 0:
    # Nothing could be confirmed; too risky to claim NotInstalled.
    (Error, unverifiable)
  elif installed == 0:
    (NotInstalled, @[])
  else:
    (Error, missing & unverifiable) # partially installed

proc status*(reg: ModuleRegistery, moduleName: string): ModuleStatus =
  reg.statusDetail(moduleName)[0]
