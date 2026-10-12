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
