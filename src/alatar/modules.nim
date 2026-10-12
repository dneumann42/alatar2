import std/[os, strutils, sequtils]

import alatar/[packages, services]

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

proc installOwn*(module: Module, dir: string) {.raises: [PackageError, ServiceError, IOError, OSError].} =
  ## Installs only this module's own packages and units; no dependency or
  ## submodule resolution (use the registry procs for that).
  for path in packageFiles(dir):
    installAll(loadSpecFile(path))
  # Units need their packages, so services come last.
  installServices(loadServices(dir))

proc install*(module: Module, moduleDir: string) {.raises: [PackageError, ServiceError, IOError, OSError].} =
  ## Tree install without dependency resolution. Modules listed in
  ## `dependencies` files are NOT installed here; prefer
  ## `install*(reg: ModuleRegistery, ...)`, which resolves them.
  let dir = moduleDir / module.name
  for subModule in module.subModules:
    subModule.install(dir)
  module.installOwn(dir)

proc install*(reg: ModuleRegistery, moduleName: string) {.raises: [ModuleError].} =
  var done, pending: seq[string]

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
      # 2. Submodules next; each resolves its own dependencies recursively.
      for sub in m.subModules:
        installResolved(ResolvedModule(found: true, module: sub, parentDir: res.parentDir / m.name))
      # 3. Own packages, then own units.
      m.installOwn(res.parentDir / m.name)
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

proc uninstall*(module: Module, moduleDir: string) {.raises: [PackageError, ServiceError, IOError, OSError].} =
  let dir = moduleDir / module.name
  # Reverse of install: stop this module's units first, then remove its
  # packages, then recurse into submodules. Dependencies (other modules) are
  # intentionally left alone; they may still be in use.
  uninstallServices(loadServices(dir))
  for path in packageFiles(dir):
    uninstallAll(loadSpecFile(path))
  for subModule in module.subModules:
    subModule.uninstall(dir)

proc uninstall*(reg: ModuleRegistery, moduleName: string) {.raises: [ModuleError].} =
  let res = reg.findModule(moduleName)
  if not res.found:
    raise newException(ModuleError, "Unknown module: " & moduleName)
  try:
    res.module.uninstall(res.parentDir)
  except CatchableError as e:
    raise newException(ModuleError, "Failed to uninstall module '" & moduleName & "': " & e.msg, e)

proc status*(reg: ModuleRegistery, moduleName: string): ModuleStatus =
  var total, installed = 0
  var done, pending: seq[string]

  proc visit(res: ResolvedModule) {.raises: [ModuleError, PackageError, ServiceError, IOError, OSError].} =
    let m = res.module
    if m.name in done:
      return # count each module once, even with diamond dependencies
    if m.name in pending:
      raise newException(ModuleError,
        "Dependency cycle detected at module: " & m.name)
    pending.add m.name
    try:
      let dir = res.parentDir
      for path in packageFiles(dir / m.name):
        for spec in loadSpecFile(path):
          inc total
          if spec.isInstalled():
            inc installed
      for svc in loadServices(dir / m.name):
        inc total
        if svc.isInstalled():
          inc installed
      for sub in m.subModules:
        visit(ResolvedModule(found: true, module: sub, parentDir: dir / m.name))
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
      return Error
    visit(res)
  except CatchableError:
    return Error
  if installed == total:
    Installed
  elif installed == 0:
    NotInstalled
  else:
    Error # partially installed
