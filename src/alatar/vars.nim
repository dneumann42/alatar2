import std/[os, strutils, tables, osproc, algorithm, streams, sequtils]

import parsetoml
import terminal

## Module variables: personal facts a module needs but cannot know itself
## (an email address, a machine nickname). A module lists them in
## `vars.toml`; `alatar install` resolves each one through, in order:
##
##   1. the process environment (override for one run),
##   2. the systemd user environment (`systemctl --user show-environment`) -
##      the live answer to "does systemd know this yet",
##   3. ~/.config/environment.d/50-alatar-vars.conf, the drop-in alatar
##      writes when it prompts, which is what makes the value survive a
##      reboot (the user manager reads environment.d at login),
##   4. an interactive prompt on a TTY.
##
## A prompted value goes back through both stores (3) and (2), so after the
## one prompt systemd - and every session unit, every later alatar run, and
## every other module that names the same var - knows it. fs.toml `content`
## strings are templates expanded against the resolved values.

const
  dropInName = "50-alatar-vars.conf"
    # "50-" sorts after the usual 10-/20- prefixes and before 99- overrides
    # (99-ollama-keepalive.conf), so an explicitly numbered user drop-in can
    # still win over an alatar value.

type
  VarSpec* = object
    name*: string
    prompt*: string
    default*: string   ## used when the prompt is answered with an empty line

  VarError* = object of CatchableError

proc dropInPath(): string {.raises: [VarError].} =
  try:
    let configHome = getEnv("XDG_CONFIG_HOME")
    let base =
      if configHome.len > 0: configHome
      else: getHomeDir() / ".config"
    base / "environment.d" / dropInName
  except CatchableError as e:
    raise newException(VarError, "Cannot locate the environment.d drop-in: " & e.msg)

proc isVarName(name: string): bool =
  ## Same rule systemd applies to environment variable names: letters,
  ## digits and underscores, not starting with a digit (dots rejected too).
  if name.len == 0: return false
  for i, c in name:
    if c in Letters + {'_'} or (i > 0 and c in Digits):
      continue
    return false
  true

proc loadVarsFile(path: string): seq[VarSpec] {.raises: [IOError, VarError].} =
  ## Reads a module's `vars.toml`: `[[var]]` tables need string fields `name`
  ## (a valid environment variable identifier) and `prompt`; an optional
  ## string `default` is the empty-answer fallback.
  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)
  let table =
    try:
      parseString(readFile(path))
    except Exception as e:
      raise newException(VarError, "Failed to parse '" & path & "': " & e.msg)
  let entries = table.getOrDefault("var")
  if entries.isNil:
    return
  for i in 0 ..< entries.len:
    let entry = entries[i]
    let name = entry.getOrDefault("name")
    if name.isNil or name.kind != TomlValueKind.String or not isVarName(name.getStr()):
      raise newException(VarError,
        "var entry [" & $i & "] in '" & path & "' needs a string field 'name' " &
        "that is a valid environment variable identifier")
    let prompt = entry.getOrDefault("prompt")
    if prompt.isNil or prompt.kind != TomlValueKind.String:
      raise newException(VarError,
        "var '" & name.getStr() & "' in '" & path & "' needs a string field 'prompt'")
    let dflt = entry.getOrDefault("default")
    var default = ""
    if not dflt.isNil:
      if dflt.kind != TomlValueKind.String:
        raise newException(VarError,
          "var '" & name.getStr() & "' in '" & path & "': 'default' must be a string")
      default = dflt.getStr()
    result.add VarSpec(name: name.getStr(), prompt: prompt.getStr(), default: default)

proc varFiles*(dir: string): seq[string] {.raises: [OSError].} =
  ## Files in a module directory that declare variables. Sorted: walkDir
  ## order is not, and a duplicate name should resolve identically on every
  ## machine reading the same tree.
  for kind, path in walkDir(dir):
    if kind == pcDir: continue
    if path.endsWith("vars.toml"):
      result.add path
  sort(result)

proc readDropIn(): Table[string, string] {.raises: [VarError, OSError, IOError].} =
  result = initTable[string, string]()
  let path = dropInPath()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let entry = line.strip()
    if entry.len == 0 or entry[0] == '#':
      continue
    let eq = entry.find('=')
    if eq <= 0:
      continue
    result[entry[0 ..< eq].strip()] = entry[eq + 1 ..< entry.len]

proc systemdValue(name: string): string =
  ## The live user-manager environment's value for `name`, or "" when systemd
  ## does not know it (or cannot be asked: no user session running).
  try:
    let p = startProcess(command = "systemctl",
                         args = @["--user", "show-environment", name],
                         options = {poUsePath, poStderrToStdout})
    let output = p.outputStream.readAll()
    discard p.waitForExit()
    close(p)
    # "NAME=value" on success; empty (or an error line) when unset.
    let line = output.strip()
    let prefix = name & "="
    if line.startsWith(prefix): line[prefix.len ..< line.len] else: ""
  except CatchableError:
    ""

proc writeDropIn(vars: Table[string, string]) {.
    raises: [VarError, OSError, IOError].} =
  let path = dropInPath()
  createDir(path.parentDir)
  var lines = @[
    "# Generated by alatar - personal module variables resolved at install",
    "# time (the last ones it prompted for). The systemd user manager reads",
    "# this at login; `systemctl --user set-environment` has already applied",
    "# the values live. Edit by hand only if you know what is prompting you.",
  ]
  var keys = toSeq(vars.keys)
  sort(keys)
  for key in keys:
    lines.add(key & "=" & vars.getOrDefault(key))
  writeFile(path, lines.join("\n") & "\n")

proc applyLive(name, value: string) =
  ## Best-effort: make the running user manager know the value now. Fails
  ## quietly off-session (a TTY before login, an SSH session without a user
  ## manager) - the drop-in then covers the next login.
  try:
    let p = startProcess(command = "systemctl",
                         args = @["--user", "set-environment", name & "=" & value],
                         options = {poUsePath, poStderrToStdout})
    discard p.waitForExit()
    close(p)
  except CatchableError:
    discard

proc askUser(spec: VarSpec): string {.raises: [VarError, IOError].} =
  if not stdin.isatty:
    # A declared default is a legitimate non-interactive answer; without one
    # the install must not guess.
    if spec.default.len > 0:
      stdout.write(spec.name & ": no TTY, using default '" & spec.default & "'\n")
      return spec.default
    raise newException(VarError,
      spec.name & " is unknown (prompt needs a TTY). Set it for this run with " &
      "'export " & spec.name & "=...', or add '" & spec.name & "=<value>' to " &
      dropInPath() & ".")
  stdout.write(spec.name & " - " & spec.prompt)
  if spec.default.len > 0:
    stdout.write(" [default: " & spec.default & "]")
  stdout.write(": ")
  stdout.flushFile()
  var answer = ""
  discard readLine(stdin, answer)
  answer = answer.strip()
  if answer.len == 0:
    answer = spec.default
  if answer.len == 0 or answer.contains('\n'):
    raise newException(VarError, spec.name & ": an answer is required")
  answer

proc resolveVars*(dir: string): Table[string, string] {.
    raises: [IOError, OSError, VarError].} =
  ## Every variable the module (and only this module - not its submodules)
  ## declares in vars.toml, resolved through env, systemd user environment,
  ## the alatar drop-in, and finally a prompt. Prompted answers are persisted
  ## to the drop-in and pushed into the live systemd user environment, so
  ## each question is asked exactly once per machine.
  result = initTable[string, string]()
  var dropIn: Table[string, string]
  var dropInLoaded = false
  var prompted = false
  for path in varFiles(dir):
    for spec in loadVarsFile(path):
      if result.hasKey(spec.name):
        continue
      let fromEnv = getEnv(spec.name)
      if fromEnv.len > 0:
        result[spec.name] = fromEnv
        continue
      let fromSystemd = systemdValue(spec.name)
      if fromSystemd.len > 0:
        result[spec.name] = fromSystemd
        continue
      if not dropInLoaded:
        dropIn = readDropIn()
        dropInLoaded = true
      let fromFile = dropIn.getOrDefault(spec.name)
      if fromFile.len > 0:
        result[spec.name] = fromFile
        continue
      let answer = askUser(spec)
      result[spec.name] = answer
      dropIn[spec.name] = answer
      prompted = true
      applyLive(spec.name, answer)
  if prompted:
    writeDropIn(dropIn)

proc expandVars*(s: string, vars: Table[string, string]): string {.
    raises: [VarError].} =
  ## Substitutes $NAME and ${NAME} for names present in `vars`; anything
  ## else is written through unchanged. A lone '$' stays literal (same rule
  ## as the path and symlink expanders).
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
        raise newException(VarError, "Unbalanced '${' in template: " & s)
      inc j # skip '}'
    if name.len == 0 or not vars.hasKey(name):
      result.add '$' # not a declared var: literal dollar, rest unchanged
      inc i
      continue
    result.add vars.getOrDefault(name)
    i = j
