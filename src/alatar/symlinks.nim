import std/[os, strutils]

import parsetoml
# Pure-Nim regex engine: std/re dlopens libpcre at program start, which would
# make alatar itself unrunnable on a fresh system before any module (with pcre)
# had a chance to install it.
import regex
import std/syncio

type
  SymlinkSpec* = object
    key*: string    ## table name in symlink.toml: a regex (ERE syntax,
                    ## pure-Nim engine) matched against paths relative
                    ## to the modules root
    source*: string ## resolved absolute path the link points at
    dest*: string   ## absolute path of the link itself, env vars expanded

  SymlinkError* = object of CatchableError

proc xdgDefault(name: string): string =
  ## XDG Base Directory spec fallbacks for when the variable is not set.
  case name
  of "XDG_CONFIG_HOME": getHomeDir() / ".config"
  of "XDG_DATA_HOME": getHomeDir() / ".local" / "share"
  of "XDG_STATE_HOME": getHomeDir() / ".local" / "state"
  of "XDG_CACHE_HOME": getHomeDir() / ".local" / "cache"
  else: ""

proc expandVars*(s: string): string {.raises: [SymlinkError].} =
  ## Substitutes $NAME and ${NAME} with the respective environment variable.
  ## Unset XDG_* variables fall back to their spec defaults; other unset
  ## variables are an error.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] != '$':
      result.add s[i]
      inc i
      continue
    var j = i + 1
    var braced = false
    if j < s.len and s[j] == '{':
      braced = true
      inc j
    var name = ""
    while j < s.len and (if braced: s[j] != '}' else: s[j] in IdentChars):
      name.add s[j]
      inc j
    if braced:
      if j >= s.len:
        raise newException(SymlinkError, "Unbalanced '${' in path: " & s)
      inc j # skip '}'
    if name.len == 0:
      result.add '$' # literal $
      inc i
      continue
    if name.allCharsInSet(Digits):
      # $0..$9 are capture references for regex keys, not env vars.
      result.add "$" & name
      i = j
      continue
    let val =
      if getEnv(name).len > 0: getEnv(name)
      elif xdgDefault(name).len > 0: xdgDefault(name)
      else:
        raise newException(SymlinkError,
          "Environment variable '" & name & "' is not set (needed by path: " & s & ")")
    result.add val
    i = j

proc staticDirPrefix(pattern: string): string =
  ## Longest directory prefix of `pattern` free of regex metacharacters;
  ## the directory whose entries a pattern is matched against.
  var lastSlash = -1
  var i = 0
  while i < pattern.len and pattern[i] notin
      {'^', '$', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '|', '\\'}:
    if pattern[i] == '/':
      lastSlash = i
    inc i
  if lastSlash >= 0: pattern[0 ..< lastSlash] else: ""

proc substituteCaptures(s: string, caps: openArray[string]): string =
  ## Replaces $0..$9 and ${0}..${9} with the capture group texts.
  result = s
  for i in countdown(9, 0):
    let val = if i < caps.len: caps[i] else: ""
    result = result.replace("$" & $i, val).replace("${" & $i & "}", val)

proc loadSymlinkFile*(path, modulesRoot: string): seq[SymlinkSpec] {.
    raises: [IOError, SymlinkError, OSError].} =
  ## Reads a module's `symlink.toml`. Each table is named by a regular
  ## expression (ERE-like syntax, matched by the pure-Nim regex engine, so
  ## alatar needs no system pcre) against paths relative to the modules root
  ## - quote keys containing `/`. Plain paths work as literals. The pattern is
  ## matched against the direct entries of its longest metacharacter-free
  ## directory prefix, so `desktop/_config/(.*)` links each config dir below
  ## `desktop/_config` individually. Every entry needs a string field `to`:
  ## the link destination, with $VAR environment substitution plus $0..$9
  ## capture references; it must resolve to an absolute path.
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  let table =
    try:
      parseString(readFile(path))
    except Exception:
      raise newException(SymlinkError,
        "Failed to parse '" & path & "': " & getCurrentExceptionMsg())
  for key, entry in pairs(table.getTable[]):
    let to = entry.getOrDefault("to")
    if to.isNil or to.kind != TomlValueKind.String:
      raise newException(SymlinkError,
        "Symlink entry '" & key & "' in '" & path & "' needs a string field 'to'")
    let rx =
      try:
        re2(key)
      except CatchableError as e:
        raise newException(SymlinkError,
          "Invalid regex in symlink entry '" & key & "': " & e.msg)
    let base = staticDirPrefix(key)
    let baseDir = modulesRoot / base
    if not dirExists(baseDir):
      raise newException(SymlinkError, "Symlink pattern '" & key &
        "': no such directory '" & baseDir & "'")
    var matched = 0
    for kind, found in walkDir(baseDir):
      if kind notin {pcDir, pcFile}:
        continue
      let name = found.lastPathPart
      let relPath = if base.len > 0: base / name else: name
      var m: RegexMatch2
      # Whole-string match: anchored at 0 and spanning the whole path.
      # m.captures holds the group slices ($1..); $0 is the whole path.
      if relPath.match(rx, m):
        inc matched
        var groups = newSeq[string](m.captures.len + 1)
        groups[0] = relPath
        for ci in 0 ..< m.captures.len:
          # nonCapture (-1 .. -2): the group did not participate, counts
          # as an empty capture, like with std/re.
          let bounds = m.captures[ci]
          groups[ci + 1] = if bounds.a >= 0: relPath[bounds] else: ""
        let dest = substituteCaptures(expandVars(to.getStr()), groups)
        if not dest.isAbsolute():
          raise newException(SymlinkError, "Symlink destination for '" & key &
            "' must be absolute after expansion, got: " & dest)
        # Store absolute link targets: a relative symlink would resolve
        # against whichever directory alatar happens to run from.
        let source =
          try:
            absolutePath(modulesRoot / relPath)
          except CatchableError: # OSError, ValueError from cwd/path resolution
            raise newException(SymlinkError,
              "Cannot resolve module path '" & modulesRoot / relPath & "'")
        result.add SymlinkSpec(key: key, source: source, dest: dest)
    if matched == 0:
      raise newException(SymlinkError, "Symlink pattern '" & key &
        "' matched no entries in '" & baseDir & "'")

proc symlinkSpecs*(moduleDir, modulesRoot: string): seq[SymlinkSpec] {.
    raises: [IOError, SymlinkError, OSError].} =
  ## A module's symlink entries, or none when it has no `symlink.toml`.
  let path = moduleDir / "symlink.toml"
  if fileExists(path): loadSymlinkFile(path, modulesRoot) else: @[]

proc isInstalled*(spec: SymlinkSpec): bool =
  symlinkExists(spec.dest) and expandSymlink(spec.dest) == spec.source

proc confirmReplace(dest, source: string): bool =
  ## Ask whether to delete the real file/directory at `dest` and link in
  ## `source` instead. EOF or anything unparseable counts as "no".
  stderr.write("alatar: '" & dest & "' already exists and is not a link to '" &
    source & "'. Replace it with the symlink? [y/N] ")
  flushFile(stderr)
  var line = ""
  while readLine(stdin, line):
    case line.strip.toLowerAscii
    of "y", "yes":
      return true
    of "n", "no", "":
      break
    else:
      stderr.write("Please answer y or n: ")
  stderr.write("Keeping '" & dest & "'.\n")
  false

proc installSymlink(spec: SymlinkSpec) {.raises: [SymlinkError, IOError, OSError].} =
  if not (fileExists(spec.source) or dirExists(spec.source)):
    raise newException(SymlinkError,
      "Symlink source '" & spec.source & "' does not exist")
  if symlinkExists(spec.dest):
    if expandSymlink(spec.dest) == spec.source:
      return # already linked correctly
    removeFile(spec.dest) # stale or foreign symlink, safe to swap
  elif fileExists(spec.dest) or dirExists(spec.dest):
    # A real file or directory sits where the config should be.
    if not confirmReplace(spec.dest, spec.source):
      return
    if dirExists(spec.dest): removeDir(spec.dest) else: removeFile(spec.dest)
  createDir(spec.dest.parentDir)
  createSymlink(spec.source, spec.dest)

proc installSymlinks*(specs: seq[SymlinkSpec]) {.raises: [SymlinkError].} =
  var failures: seq[string]
  for spec in specs:
    try:
      installSymlink(spec)
    except CatchableError as e: # SymlinkError, IOError, OSError
      failures.add "Failed to link '" & spec.dest & "': " & e.msg
  if failures.len > 0:
    raise newException(SymlinkError,
      "Symlink installation failed:\n" & failures.join("\n"))

proc uninstallSymlinks*(specs: seq[SymlinkSpec]) {.raises: [SymlinkError].} =
  ## Removes the links this module created. Anything that is not a symlink
  ## at the destination (a directory the user chose to keep, for instance)
  ## is left untouched - we never delete real data on uninstall.
  var failures: seq[string]
  for spec in specs:
    if symlinkExists(spec.dest):
      try:
        removeFile(spec.dest)
      except OSError as e:
        failures.add "Failed to remove symlink '" & spec.dest & "': " & e.msg
  if failures.len > 0:
    raise newException(SymlinkError,
      "Symlink removal failed:\n" & failures.join("\n"))
