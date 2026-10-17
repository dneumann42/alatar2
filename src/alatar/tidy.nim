import std/[algorithm, envvars, os, osproc, streams, strutils, strtabs, syncio]

import parsetoml
import regex

import alatar/symlinks

type
  TidyRule* = object
    name*: string
    exts*: seq[string]
    pattern*: string
    rx*: Regex2
    hasRx*: bool
    to*: string
    sh*: string

  Placement* = object
    source*: string
    destDir*: string

  TidyError* = object of CatchableError

proc normExt(s: string): string =
  var t = s.strip.toLowerAscii
  if t.startsWith("."):
    t = t[1 ..< t.len]
  t

proc fieldOf(tbl: TomlValueRef, key: string): string =
  tbl.getOrDefault(key).getStr("").strip

proc extsOf(tbl: TomlValueRef, key, path: string): seq[string] {.
    raises: [TidyError].} =
  let value = tbl.getOrDefault(key)
  if value.isNil:
    return
  case value.kind
  of TomlValueKind.String:
    result.add value.getStr().normExt
  of TomlValueKind.Array:
    for i in 0 ..< value.len:
      let item = value[i]
      if item.kind != TomlValueKind.String:
        raise newException(TidyError,
          "In '" & path & "': 'ext' items must be strings")
      result.add item.getStr().normExt
  else:
    raise newException(TidyError, "In '" & path &
      "': 'ext' must be a string or an array of strings")

proc loadTidyFile*(path: string): seq[TidyRule] {.raises: [IOError, TidyError].} =
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  let table =
    try:
      parsetoml.parseString(readFile(path))
    except Exception as e:
      raise newException(TidyError,
        "Failed to parse '" & path & "': " & e.msg, e)
  let entries = table.getOrDefault("rule")
  if entries.isNil:
    return
  for i in 0 ..< entries.len:
    let entry = entries[i]
    var rule = TidyRule(
      name: entry.fieldOf("name"),
      exts: entry.extsOf("ext", path),
      pattern: entry.fieldOf("match"),
      to: entry.fieldOf("to"),
      sh: entry.fieldOf("sh"))
    if rule.name.len == 0:
      rule.name = "rule[" & $i & "]"
    if rule.pattern.len > 0:
      try:
        rule.rx = re2(rule.pattern)
      except CatchableError as e:
        raise newException(TidyError,
          "Invalid regex in " & rule.name & ": " & e.msg)
      rule.hasRx = true
    if rule.to.len == 0 and rule.sh.len == 0:
      raise newException(TidyError,
        "In '" & path & "': " & rule.name & " needs a 'to' or a 'sh' field")
    result.add rule

proc homeExpanded(path: string): string =
  if path == "~": getHomeDir()
  elif path.startsWith("~/"): getHomeDir() / path[2 ..< path.len]
  else: path

proc runSh(cmd, file: string): string {.raises: [TidyError].} =
  var env = newStringTable()
  for key, value in envPairs():
    env[key] = value
  let sf = splitFile(file)
  env["FILE"] = file
  env["FILENAME"] = sf.name & sf.ext
  env["FILE_DIR"] = sf.dir
  try:
    let p = startProcess(command = "sh", args = @["-c", cmd], env = env,
                         options = {poUsePath})
    try:
      let output = p.outputStream.readAll().strip
      let errors = p.errorStream.readAll()
      if errors.len > 0:
        stderr.write(errors)
      if p.waitForExit() != 0 or output.len == 0:
        return
      for line in output.splitLines:
        if line.strip.len > 0:
          return line.strip
    finally:
      close(p)
  except CatchableError as e:
    raise newException(TidyError,
      "Shell rule '" & cmd & "' failed: " & e.msg)

proc expandDest(rule: TidyRule, groups: openArray[string]): string {.
    raises: [TidyError].} =
  try:
    substituteCaptures(expandVars(homeExpanded(rule.to)), groups)
  except SymlinkError as e:
    raise newException(TidyError, rule.name & ": " & e.msg)

proc destDirOf(rule: TidyRule, file: string,
               groups: openArray[string]): string {.raises: [TidyError].} =
  proc checked(cand: string): string {.raises: [TidyError].} =
    result = joinPath(homeExpanded(cand))
    if not result.isAbsolute:
      raise newException(TidyError, rule.name & ": destination must be absolute, got: " &
        result)
  if rule.sh.len > 0:
    let outp = runSh(rule.sh, file)
    if outp.len > 0:
      return checked(outp)
    if rule.to.len > 0:
      return checked(rule.expandDest(groups))
  elif rule.to.len > 0:
    return checked(rule.expandDest(groups))

proc matchFile(rule: TidyRule, name: string, groups: var seq[string]): bool =
  if rule.exts.len > 0 and name.splitFile.ext.normExt notin rule.exts:
    return false
  if rule.hasRx:
    var m: RegexMatch2
    if not name.match(rule.rx, m):
      return false
    groups = newSeq[string](m.captures.len + 1)
    groups[0] = name
    for ci in 0 ..< m.captures.len:
      let bounds = m.captures[ci]
      groups[ci + 1] = if bounds.a >= 0: name[bounds] else: ""
  else:
    groups = @[name]
  true

proc placementFor(rules: openArray[TidyRule],
                  file: string): Placement {.raises: [TidyError].} =
  let name = file.lastPathPart
  for rule in rules:
    var groups: seq[string]
    if not rule.matchFile(name, groups):
      continue
    let destDir = rule.destDirOf(file, groups)
    if destDir.len == 0:
      continue
    if destDir != joinPath(file.parentDir):
      return Placement(source: file, destDir: destDir)
    return

proc visible(relPath: string): bool =
  var rest = relPath
  while rest.len > 0:
    let (head, tail) = rest.splitPath
    if tail.startsWith("."):
      return false
    rest = head
  true

proc scanFiles(dir: string, recursive: bool): seq[string] {.
    raises: [OSError, ValueError].} =
  if recursive:
    for path in walkDirRec(dir):
      if visible(relativePath(path, dir)):
        result.add path
  else:
    for kind, path in walkDir(dir, relative = true):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if visible(path):
        result.add dir / path
  result = result.sorted()

proc plan*(rules: openArray[TidyRule], dir: string,
           recursive = false): seq[Placement] {.
    raises: [OSError, ValueError, TidyError].} =
  let root = absolutePath(dir)
  for file in scanFiles(root, recursive):
    let placement = placementFor(rules, file)
    if placement.source.len > 0:
      result.add placement

proc planFile*(rules: openArray[TidyRule],
               file: string): seq[Placement] {.
    raises: [OSError, ValueError, TidyError].} =
  let placement = placementFor(rules, absolutePath(file))
  if placement.source.len > 0:
    result.add placement

proc targetOf*(p: Placement): string =
  p.destDir / p.source.lastPathPart

proc confirmMove(source, dest: string): bool {.raises: [IOError].} =
  stderr.write("alatar: move '" & source & "' to '" & dest & "'? [y/N] ")
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
  false

proc uniquePath(dir, name: string): string =
  let sf = splitFile(name)
  result = dir / name
  var i = 1
  while fileExists(result) or dirExists(result):
    result = dir / (sf.name & " (" & $i & ")" & sf.ext)
    inc i

proc applyMoves*(plans: seq[Placement], ask = false) =
  var failures: seq[string]
  for p in plans:
    if ask and not confirmMove(p.source, p.targetOf):
      continue
    try:
      createDir(p.destDir)
      let dest = uniquePath(p.destDir, p.source.lastPathPart)
      moveFile(p.source, dest)
      echo "moved ", p.source, " -> ", dest
    except CatchableError as e:
      failures.add "Failed to move '" & p.source & "': " & e.msg
  if failures.len > 0:
    raise newException(TidyError, "File moves failed:\n" & failures.join("\n"))
