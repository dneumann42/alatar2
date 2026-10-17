import std/[os, posix, strutils]

import parsetoml

import alatar/packages

const
  defaultMirrorList = "/etc/pacman.d/mirrorlist"

type
  RepoSpec = object
    name: string
    includeFile: string
    server: string

  RepoError* = object of CatchableError

proc name*(repo: RepoSpec): string = repo.name
proc includeFile*(repo: RepoSpec): string = repo.includeFile
proc server*(repo: RepoSpec): string = repo.server

proc pacmanConf*(): string =
  getEnv("ALATAR_PACMAN_CONF", "/etc/pacman.conf")

proc validName(name: string): bool =
  result = true
  if name.len == 0 or name.len > 64:
    return false
  for c in name:
    if not (c in 'a' .. 'z' or c in 'A' .. 'Z' or c in '0' .. '9' or
            c in {'-', '_', '.', '+'}):
      return false

proc load(T: typedesc[RepoSpec], tbl: TomlValueRef): T {.
    raises: [RepoError].} =
  let name = tbl.getOrDefault("name").getStr("").strip
  if not name.validName:
    raise newException(RepoError,
      "Invalid repository name '" & name &
      "' (expected letters, digits, '-', '_', '.', '+')")
  result = T(
    name: name,
    includeFile: tbl.getOrDefault("include").getStr(defaultMirrorList).strip,
    server: tbl.getOrDefault("server").getStr("").strip
  )

proc loadRepoSpecs*(path: string): seq[RepoSpec] {.
    raises: [IOError, RepoError].} =
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  # Only the parse itself is wrapped: an invalid repo name must surface as the
  # clear "Invalid repository name" error, not as a bogus parse failure.
  let table =
    try:
      parsetoml.parseString(readFile(path))
    except Exception as e:
      raise newException(RepoError, "Failed to parse '" & path & "': " & e.msg, e)
  let repos = table.getOrDefault("repo")
  if repos.isNil:
    return # empty / repo-less spec file
  for i in 0 ..< repos.len:
    result.add RepoSpec.load(repos[i])

proc repoFiles*(dir: string): seq[string] {.raises: [OSError].} =
  ## Files in a module directory that declare pacman repositories.
  for kind, path in walkDir(dir):
    if kind == pcDir: continue
    if path.endsWith("repos.toml"):
      result.add path

proc loadRepos*(dir: string): seq[RepoSpec] {.
    raises: [IOError, OSError, RepoError].} =
  ## Every repository declared by a module directory.
  for path in repoFiles(dir):
    for repo in loadRepoSpecs(path):
      result.add repo

proc sectionOf(line: string): (bool, string) =
  let t = line.strip
  if t.startsWith("["):
    let close = t.find(']')
    if close > 0: return (false, t[1 ..< close].strip)
  elif t.startsWith("#["):
    let close = t.find(']')
    if close > 2: return (true, t[2 ..< close].strip)
  return (false, "")

proc directiveOf(line: string): (bool, string) =
  var t = line.strip
  var commented = false
  if t.startsWith("#"):
    commented = true
    t = t[1 ..< t.len].strip
  let eq = t.find('=')
  return (commented, (if eq > 0: t[0 ..< eq] else: t).strip.toLowerAscii)

proc uncomment(line: string): string =
  let idx = line.find('#')
  if idx < 0: line else: line[0 ..< idx] & line[idx + 1 ..< line.len]

proc mirrorLine(repo: RepoSpec): string =
  if repo.server.len > 0: "Server = " & repo.server
  else: "Include = " & repo.includeFile

proc sectionRange(lines: seq[string], name: string): (int, bool) =
  for i, line in lines:
    let (commented, sec) = sectionOf(line)
    if sec.len > 0 and sec.cmpIgnoreCase(name) == 0:
      return (i, commented)
  (-1, false)

proc repoEnabled*(content, name: string): bool =
  let lines = content.splitLines
  let (header, commented) = lines.sectionRange(name)
  if header < 0 or commented:
    return false
  for i in header + 1 ..< lines.len:
    let (c, sec) = sectionOf(lines[i])
    if sec.len > 0 and not c:
      return false # reached the next real section: this one has no mirrors
    let (dc, key) = directiveOf(lines[i])
    if not dc and key in ["include", "server"]:
      return true
  return false

proc enableRepo*(content: string, repo: RepoSpec): string =
  if repoEnabled(content, repo.name):
    return content
  var lines = content.splitLines
  let (header, commented) = lines.sectionRange(repo.name)

  if header >= 0:
    if commented:
      lines[header] = uncomment(lines[header])
    var mirrors = false
    var i = header + 1
    while i < lines.len:
      let (c, sec) = sectionOf(lines[i])
      if sec.len > 0:
        break # another section, commented or not: its lines are not ours
      let (dc, key) = directiveOf(lines[i])
      if key in ["include", "server"]:
        if dc:
          lines[i] = uncomment(lines[i])
        mirrors = true
        break
      inc i
    if not mirrors:
      # No mirror line to reuse (stock file, or a hand-edited one): add ours.
      lines.insert(repo.mirrorLine, header + 1)
  else:
    if lines.len > 0 and lines[^1].strip.len > 0:
      lines.add("")
    lines.add("[" & repo.name & "]")
    lines.add(repo.mirrorLine)

  result = lines.join("\n")
  if not result.endsWith("\n"): # the stock file ends with a newline
    result.add("\n")

proc isInstalled*(repo: RepoSpec): bool {.raises: [RepoError].} =
  ## Whether the repository is enabled and usable in pacman.conf.
  let conf = pacmanConf()
  if not fileExists(conf):
    raise newException(RepoError, "Missing pacman configuration: " & conf)
  try:
    return repoEnabled(readFile(conf), repo.name)
  except IOError as e:
    raise newException(RepoError, "Cannot read '" & conf & "': " & e.msg, e)

proc writableByUs(path: string): bool =
  ## Can the current process write this file? True for the ALATAR_PACMAN_CONF
  ## test copy and when alatar runs as root; false for /etc/pacman.conf as a
  ## normal user, which is when we escalate instead of failing.
  access(path.cstring, W_OK) == 0

proc writeBackup(conf, content: string) {.raises: [RepoError, PackageError].} =
  ## Keeps the configuration as it was before alatar first touched it, so the
  ## user can always diff or restore it.
  let backup = conf & ".alatar"
  if fileExists(backup):
    return # only the very first change is worth keeping
  try:
    writeFile(backup, content)
  except CatchableError:
    # No permission (the usual case for /etc): let root copy it instead. The
    # escalated copy is what reports a real failure.
    runPrivileged("cp", @[conf, backup])

proc writeConf(conf, content: string) {.raises: [RepoError, PackageError].} =
  ## Puts `content` in place of the pacman configuration, escalating to
  ## sudo/pkexec when we may not write it ourselves.
  if writableByUs(conf):
    try:
      writeFile(conf, content) # keeps the existing file's mode
    except CatchableError as e:
      raise newException(RepoError, "Cannot write '" & conf & "': " & e.msg, e)
    return
  let tmp = getTempDir() / ("alatar-pacman-" & $getCurrentProcessId() & ".conf")
  try:
    writeFile(tmp, content)
    runPrivileged("cp", @[tmp, conf]) # cp onto an existing file keeps its mode
  except IOError as e:
    raise newException(RepoError, "Cannot stage '" & conf & "': " & e.msg, e)
  except PackageError as e:
    raise newException(RepoError, "Cannot write '" & conf & "': " & e.msg, e)
  finally:
    try: removeFile(tmp) except CatchableError: discard

proc ensureRepos*(repos: seq[RepoSpec]) {.raises: [RepoError, PackageError].} =
  if repos.len == 0:
    return
  let conf = pacmanConf()
  var content =
    try:
      readFile(conf)
    except IOError as e:
      raise newException(RepoError, "Cannot read '" & conf & "': " & e.msg, e)
    except OSError as e:
      raise newException(RepoError, "Cannot read '" & conf & "': " & e.msg, e)

  var patched = content
  var added: seq[string]
  for repo in repos:
    let next = enableRepo(patched, repo)
    if next != patched:
      patched = next
      added.add repo.name
  if added.len == 0:
    return # nothing missing: no root prompt, no database refresh

  writeBackup(conf, content)
  writeConf(conf, patched)
  echo "alatar: enabled pacman repo(s): ", added.join(", ")

  if conf == "/etc/pacman.conf":
    try:
      runPrivileged("pacman", @["-Sy", "--noconfirm"])
    except PackageError as e:
      raise newException(RepoError,
        "Enabled " & added.join(", ") & " in " & conf &
        ", but the database refresh failed (run 'sudo pacman -Sy' yourself): " &
        e.msg, e)
