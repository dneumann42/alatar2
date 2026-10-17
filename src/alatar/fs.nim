import std/[os, strutils]

import parsetoml

type
  FsKind* = enum
    fsDirectory
    fsFile

  FsSpec* = object
    kind*: FsKind
    path*: string   ## absolute path, `~` and $VAR expanded
    content*: string ## file entries only; written when the file is missing

  FsError* = object of CatchableError

proc expandPath*(s: string): string {.raises: [FsError].} =
  ## Expands a leading `~` to the home directory and substitutes $NAME and
  ## ${NAME} with the respective environment variable. Unset variables are an
  ## error: a path into nowhere is worse than failing the install.
  var t = s
  if t == "~" or t.startsWith("~/"):
    let rest = if t == "~": "" else: t[2 ..< t.len]
    t = if rest.len > 0: getHomeDir() / rest else: getHomeDir()
  result = newStringOfCap(t.len)
  var i = 0
  while i < t.len:
    if t[i] != '$':
      result.add t[i]
      inc i
      continue
    var j = i + 1
    var braced = false
    if j < t.len and t[j] == '{':
      braced = true
      inc j
    var name = ""
    while j < t.len and (if braced: t[j] != '}' else: t[j] in IdentChars):
      name.add t[j]
      inc j
    if braced:
      if j >= t.len:
        raise newException(FsError, "Unbalanced '${' in path: " & s)
      inc j # skip '}'
    if name.len == 0:
      result.add '$' # literal $
      inc i
      continue
    let val = getEnv(name)
    if val.len == 0:
      raise newException(FsError,
        "Environment variable '" & name & "' is not set (needed by path: " & s & ")")
    result.add val
    i = j

proc loadPath(entry: TomlValueRef, key, path: string): string {.
    raises: [FsError].} =
  let value = entry.getOrDefault("path")
  if value.isNil or value.kind != TomlValueKind.String:
    raise newException(FsError,
      "fs entry '" & key & "' in '" & path & "' needs a string field 'path'")
  let expanded = expandPath(value.getStr().strip)
  if expanded.len == 0 or not expanded.isAbsolute():
    raise newException(FsError,
      "fs entry '" & key & "' in '" & path &
      "' must expand to an absolute path, got: " & expanded)
  expanded

proc collectEntries(table: TomlValueRef, arrName: string, kind: FsKind,
                    specPath: string): seq[FsSpec] {.raises: [FsError].} =
  let entries = table.getOrDefault(arrName)
  if entries.isNil:
    return
  for i in 0 ..< entries.len:
    let entry = entries[i]
    var spec = FsSpec(
      kind: kind,
      path: loadPath(entry, arrName & "[" & $i & "]", specPath))
    if kind == fsFile:
      let content = entry.getOrDefault("content")
      if not content.isNil:
        if content.kind != TomlValueKind.String:
          raise newException(FsError, "fs file '" & spec.path & "' in '" & specPath &
            "': 'content' must be a string")
        spec.content = content.getStr()
    result.add spec

proc loadFsFile*(path: string): seq[FsSpec] {.raises: [IOError, FsError].} =
  ## Reads a module's `fs.toml`: `[[directory]]` tables need a string field
  ## `path`, `[[file]]` tables additionally take an optional string `content`.
  ## Paths expand `~` and $VAR and must resolve to absolute. Installation
  ## creates what is missing and never rewrites or deletes what exists.
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  let table =
    try:
      parseString(readFile(path))
    except Exception as e:
      raise newException(FsError, "Failed to parse '" & path & "': " & e.msg, e)
  result.add table.collectEntries("directory", fsDirectory, path)
  result.add table.collectEntries("file", fsFile, path)

proc fsFiles*(dir: string): seq[string] {.raises: [OSError].} =
  ## Files in a module directory that declare directories and files to create.
  for kind, path in walkDir(dir):
    if kind == pcDir: continue
    if path.endsWith("fs.toml"):
      result.add path

proc fsSpecs*(moduleDir: string): seq[FsSpec] {.
    raises: [IOError, OSError, FsError].} =
  ## Every directory and file a module's fs.toml files declare.
  for path in fsFiles(moduleDir):
    for spec in loadFsFile(path):
      result.add spec

proc installFs*(specs: seq[FsSpec]) {.raises: [FsError].} =
  ## Creates each entry that does not exist yet. What already exists is left
  ## exactly as it is - these are user data paths, alatar only seeds them.
  var failures: seq[string]
  for spec in specs:
    try:
      case spec.kind
      of fsDirectory:
        # createDir is recursive and quiet about an existing directory.
        createDir(spec.path)
      of fsFile:
        if dirExists(spec.path):
          raise newException(FsError,
            "A directory sits where the file '" & spec.path & "' belongs")
        elif not fileExists(spec.path):
          createDir(spec.path.parentDir)
          writeFile(spec.path, spec.content)
    except CatchableError as e: # FsError, IOError, OSError
      failures.add "Failed to create '" & spec.path & "': " & e.msg
  if failures.len > 0:
    raise newException(FsError,
      "Filesystem entry creation failed:\n" & failures.join("\n"))

proc isInstalled*(spec: FsSpec): bool =
  ## Existence is the whole contract: the content is only written when the
  ## file was missing, so an existing file counts as installed even if the
  ## user edited it.
  case spec.kind
  of fsDirectory: dirExists(spec.path)
  of fsFile: fileExists(spec.path)
