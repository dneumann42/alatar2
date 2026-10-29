import std/[algorithm, envvars, os, osproc, strutils]

type
  AppImageError* = object of CatchableError

proc isAppImage*(path: string): bool =
  path.splitFile.ext.toLowerAscii == ".appimage"

proc appImageHome*(): string =
  getEnv("APPIMAGE_DIR", getHomeDir() / ".local" / "bin")

proc dataDir(): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")

proc appsDir(): string =
  dataDir() / "applications"

proc iconsDir(): string =
  dataDir() / "icons" / "hicolor"

proc expandTilde(path: string): string =
  if path == "~": getHomeDir()
  elif path.startsWith("~/"): getHomeDir() / path[2 ..^ 1]
  else: path

proc appImagesIn*(dir: string): seq[string] {.
    raises: [OSError, ValueError].} =
  ## AppImages sitting directly in dir, sorted, hidden files skipped.
  for kind, name in walkDir(dir, relative = true):
    if kind notin {pcFile, pcLinkToFile}:
      continue
    if name.startsWith(".") or not isAppImage(name):
      continue
    result.add dir / name
  result.sort()

proc refersTo(content, appPath: string): bool =
  content.contains(appPath) or content.contains(appPath.lastPathPart)

proc desktopFor*(path: string): string =
  ## The .desktop entry that references this AppImage, or "" when it has
  ## none. A desktop entry is what wofi and friends list, so this doubles
  ## as the "is it launchable" check.
  result = ""
  let abs = absolutePath(path)
  if not dirExists(appsDir()):
    return
  for kind, entry in walkDir(appsDir()):
    if kind != pcFile or not entry.endsWith(".desktop"):
      continue
    let content =
      try:
        readFile(entry)
      except CatchableError:
        ""
    if content.len > 0 and refersTo(content, abs):
      return entry

proc hasExecBit(path: string): bool {.raises: [OSError].} =
  let perms = getFilePermissions(path)
  fpUserExec in perms or fpGroupExec in perms or fpOthersExec in perms

proc issuesFor*(path: string): seq[string] =
  ## What stands between this AppImage and launching it from the desktop.
  try:
    if not hasExecBit(path):
      result.add "not executable"
  except OSError:
    return @[]
  if desktopFor(path).len == 0:
    result.add "no desktop entry"

proc makeExecutable(path: string): bool {.raises: [OSError].} =
  if hasExecBit(path):
    return false
  setFilePermissions(path,
    getFilePermissions(path) + {fpUserExec, fpGroupExec, fpOthersExec})
  true

proc pngDims(path: string): (int, int) =
  ## Width and height from the PNG header, (0, 0) when it is not a parseable
  ## PNG. The IHDR chunk always starts at byte 16, dimensions big-endian.
  var f: File
  if not open(f, path, fmRead):
    return (0, 0)
  defer: close(f)
  var buf: array[24, char]
  if readBuffer(f, addr buf, buf.len) != buf.len:
    return (0, 0)
  if buf[1] != 'P' or buf[2] != 'N' or buf[3] != 'G':
    return (0, 0)
  let
    w = (buf[16].ord shl 24) or (buf[17].ord shl 16) or
        (buf[18].ord shl 8) or buf[19].ord
    h = (buf[20].ord shl 24) or (buf[21].ord shl 16) or
        (buf[22].ord shl 8) or buf[23].ord
  if w <= 0 or w > 8192 or h <= 0 or h > 8192:
    return (0, 0)
  (w, h)

func niceName(stem: string): string =
  ## "Aseprite_1.3.18.1-x64" -> "Aseprite".
  stem.split('_')[0]

func desktopKey(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
    (c >= '0' and c <= '9') or c in {'-', '_', '.'}

func sanitizeDesktopName(name: string): string =
  for c in name:
    result.add if desktopKey(c): c else: '-'

proc quoteForExec(path: string): string =
  if path.contains({' ', '\t', '"'}): "\"" & path & "\""
  else: path

proc rewriteExec(oldCmd, appPath: string): string =
  ## Swap the AppImage's internal launcher for the AppImage itself and keep
  ## whatever arguments it had ("%U" when it had none).
  var rest = ""
  if oldCmd.startsWith "\"":
    let close = oldCmd.find('"', 1)
    if close > 0:
      rest = oldCmd[close + 1 ..< oldCmd.len].strip
  else:
    let sp = oldCmd.find(' ')
    if sp > 0:
      rest = oldCmd[sp + 1 ..< oldCmd.len].strip
  "Exec=" & quoteForExec(appPath) &
    (if rest.len > 0: " " & rest else: " %U")

proc quietRun(app, tmp: string, patterns: seq[string]): bool =
  try:
    let p = startProcess(command = app,
      args = @["--appimage-extract"] & patterns,
      workingDir = tmp, options = {})
    try: p.waitForExit() == 0 finally: p.close()
  except CatchableError:
    false

proc hasTopLevelDesktop(root: string): bool =
  if not dirExists(root):
    return false
  for kind, path in walkDir(root):
    if kind == pcFile and path.endsWith(".desktop"):
      return true
  false

proc extract(app: string): string =
  ## Unpack the AppImage payload into a fresh temp dir and return its
  ## squashfs-root, "" when nothing could be unpacked. Tries the pattern
  ## form first (desktop and icons only), falls back to a full extract.
  ## The caller owns the temp dir: removeDir(root.parentDir) when done.
  let tmp = getTempDir() / "alatar-appimages-" & $getCurrentProcessId()
  removeDir(tmp)
  createDir(tmp)
  result = tmp / "squashfs-root"
  discard quietRun(app, tmp,
    @["squashfs-root/*.desktop", "squashfs-root/*.png", "squashfs-root/*.svg"])
  if hasTopLevelDesktop(result):
    return
  removeDir(result)
  discard quietRun(app, tmp, @[])
  if dirExists(result):
    return
  removeDir(tmp)
  result = ""

proc copyIcons(root, icon: string) =
  ## Install the AppImage's icon into the hicolor theme so desktop entries
  ## referencing Icon=<name> can find it. Best effort.
  let wanted = [icon & ".png", icon & ".svg"]
  try:
    for path in walkDirRec(root):
      let base = path.lastPathPart
      if base.cmpIgnoreCase(wanted[0]) != 0 and base.cmpIgnoreCase(wanted[1]) != 0:
        continue
      var dir: string
      if base.toLowerAscii.endsWith(".svg"):
        dir = iconsDir() / "scalable" / "apps"
      else:
        let (w, h) = pngDims(path)
        if w == 0:
          continue
        dir = iconsDir() / ($w & "x" & $h) / "apps"
      createDir(dir)
      copyFile(path, dir / base)
  except CatchableError:
    discard

proc refersToEntry(entry, abs: string): bool =
  try:
    refersTo(readFile(entry), abs)
  except CatchableError:
    false

proc refreshCaches() =
  let cmds = [
    "command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database " &
      quoteForExec(appsDir()),
    "command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f " &
      quoteForExec(iconsDir())]
  for cmd in cmds:
    try:
      discard execShellCmd(cmd & " || true")
    except OSError:
      discard

proc buildDesktop(abs: string): string {.
    raises: [AppImageError, OSError, ValueError, IOError].} =
  ## Create the .desktop entry for this AppImage and return its path.
  let root = extract(abs)
  try:
    var embedded, fileName, icon = ""
    if dirExists(root):
      for kind, path in walkDir(root):
        if kind == pcFile and path.endsWith(".desktop"):
          embedded = readFile(path)
          fileName = path.lastPathPart
          break
    let stem = abs.lastPathPart.splitFile.name
    var lines: seq[string]
    var sawExec = false
    if embedded.len > 0:
      for raw in embedded.splitLines:
        let line = raw.strip
        # TryExec would look for the AppImage's internal launcher and fail.
        if line.startsWith("TryExec="):
          continue
        if line.startsWith("Exec="):
          lines.add rewriteExec(line[5 ..< line.len], abs)
          sawExec = true
        elif line.startsWith("Icon="):
          icon = line[5 ..< line.len].strip
          lines.add line
        else:
          lines.add line
      if not sawExec:
        lines.add "Exec=" & quoteForExec(abs) & " %U"
    else:
      icon = stem
      lines = @[
        "[Desktop Entry]", "Type=Application", "Name=" & niceName(stem),
        "Exec=" & quoteForExec(abs) & " %U", "Terminal=false"]
    if icon.len == 0 and dirExists(root):
      icon = stem
    if dirExists(root) and icon.len > 0 and
        not icon.contains('/') and not icon.contains('\\'):
      copyIcons(root, icon)
    var name = sanitizeDesktopName(
      if fileName.len > 0: fileName else: stem & ".desktop")
    if not name.endsWith(".desktop"):
      name.add ".desktop"
    result = appsDir() / name
    var i = 1
    while fileExists(result) and not refersToEntry(result, abs):
      result = appsDir() / (name[0 ..< name.len - ".desktop".len] &
        "-" & $i & ".desktop")
      inc i
    createDir(appsDir())
    writeFile(result, lines.join("\n") & "\n")
  finally:
    if root.len > 0:
      removeDir(root.parentDir)

proc integrateOne*(path: string): seq[string] {.
    raises: [AppImageError, OSError, ValueError, IOError].} =
  ## Fix whatever issuesFor reports for this AppImage; returns what was done.
  let abs = absolutePath(path)
  if makeExecutable(abs):
    result.add "made executable"
  if desktopFor(abs).len == 0:
    let entry = buildDesktop(abs)
    refreshCaches()
    result.add "created " & entry

proc integrateDir*(dir: string, dry: bool): int {.
    raises: [OSError, ValueError, IOError, AppImageError].} =
  ## Integrate (or with dry, just report) the AppImages in dir; returns how
  ## many needed fixing.
  let root = expandTilde(dir)
  if not dirExists(root):
    raise newException(AppImageError, "no such directory '" & dir & "'")
  for app in appImagesIn(root):
    let issues = issuesFor(app)
    if issues.len == 0:
      continue
    inc result
    if dry:
      echo app, ": ", issues.join(", ")
    else:
      let fixes = integrateOne(app)
      if fixes.len > 0:
        echo app, ": ", fixes.join("; ")
