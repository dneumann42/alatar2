# ============================================================================
# Small shared helpers: process/file IO, pango spans, i3bar block JSON.
# ============================================================================

import std/[os, osproc, strutils]
import std/unicode except splitWhitespace

proc readOrEmpty*(path: string): string =
  ## File contents, or "" when the path is unreadable.
  try: readFile(path) except CatchableError: ""

proc sh*(cmd: string, args: varargs[string]): string =
  ## Run a command (no shell: argv passed verbatim), return stdout trimmed;
  ## empty string on any failure. Mirrors the Tcl original's `exec`.
  let exe = findExe(cmd)
  if exe.len == 0: return ""
  try:
    result = execProcess(exe, args = args, options = {}).strip()
  except CatchableError:
    result = ""

proc isUnsignedInt*(s: string): bool =
  ## Non-empty run of ASCII digits. Deliberately not `std/re`: the bar must
  ## start even when no PCRE1 (`libpcre.so`) can be dlopened - see the
  ## bootstrap contract in README.org.
  if s.len == 0: return false
  for c in s:
    if c < '0' or c > '9': return false
  true

proc csvIntPair*(s: string): (string, string) =
  ## First line of `s` whose first two comma-separated fields are unsigned
  ## integers: nvidia-smi's `--format=csv,noheader,nounits` row "57, 43" ->
  ## ("57", "43"). ("", "") when there is none.
  for line in s.splitLines:
    let cols = line.split(',')
    if cols.len >= 2:
      let (a, b) = (cols[0].strip, cols[1].strip)
      if isUnsignedInt(a) and isUnsignedInt(b):
        return (a, b)
  ("", "")

proc percentValue*(s: string): string =
  ## The first "NN%" run in `s` ("45"), "" when absent - pactl prints the sink
  ## volume as a percentage among hex/dec volume fields.
  var i = 0
  while i < s.len:
    if s[i] in '0' .. '9':
      var j = i
      while j < s.len and s[j] in '0' .. '9': inc j
      if j < s.len and s[j] == '%': return s[i ..< j]
      i = j
    else:
      inc i
  ""

proc spawnDetached*(cmd: string) =
  ## Fire-and-forget a command (GUI launches) with its stdio nowhere.
  try:
    let p = startProcess(findExe("sh"), args = ["-c", cmd & " >/dev/null 2>&1 & disown"],
                         options = {})
    p.close()   # waits only for the quick-exiting `sh` wrapper
  except CatchableError:
    discard

proc span*(color, body: string): string =
  "<span color=\"" & color & "\">" & body & "</span>"

proc xmlEscape*(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc jsonEscape(s: string): string =
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"' : result.add "\\\""
    of '\n', '\r', '\t': result.add ' '
    else: result.add c

proc i3block*(name, fullText: string, minWidth = 0, align = "center"): string =
  # Icon-to-value spacing is a single space in every block; width stability
  # comes from min_width (px) + align, so short values don't shift layout.
  result = "{\"name\":\"" & name & "\",\"instance\":\"" & name &
           "\",\"markup\":\"pango\",\"full_text\":\"" & jsonEscape(fullText) & "\""
  if minWidth > 0:
    result.add ",\"min_width\":" & $minWidth & ",\"align\":\"" & align & "\""
  result.add "}"

proc truncate*(s: string, n: int): string =
  ## Cut to exactly n codepoints, using '...' when shortened.
  let rs = toRunes(s)
  if rs.len > n: $(rs[0 .. n - 4]) & "..." else: s

proc findWindow*(appId: string): bool =
  ## True when a window with this app_id exists.
  let tree = sh("swaymsg", "-t", "get_tree")
  tree.contains("{\"app_id\":\"" & appId & "\"}") or
    tree.contains("{\"app_id\": \"" & appId & "\"}")
