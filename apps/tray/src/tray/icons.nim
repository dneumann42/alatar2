## Theme-icon and pixmap decoding, shared by the tray strip and the bar
## (extracted verbatim from tray.nim when apps/bar arrived).
##
## Steam and Spotify export their tray icons as theme *files* (IconName +
## IconThemePath), not ARGB pixmaps, and Nim 2.4 dropped the std PNG codec.
## ImageMagick is already a declared desktop package: two frame-polled
## children per icon - `magick identify` for the geometry, `magick ... bgra:-`
## for raw BGRA bytes (which is native-order ARGB32 on little-endian).
## Everything is cached by path+mtime and resolved asynchronously, so the
## letter tile shows for a frame or two and the real logo takes over.

import std/[os, strutils, sets, tables]
import ellipse_ui
import ellipse/platform/process
import ./sni

{.push gcsafe.}

type
  IconStage = enum jSize, jPixels
  IconJob = object
    p: ChildProcess
    stage: IconStage
    key, sig, path: string
    w, h: int32

var iconJobs {.threadvar.}: seq[IconJob]
var icons {.threadvar.}: Table[string, Icon]
var iconSig {.threadvar.}: Table[string, string]

const
  iconMax* = 48                     ## downscale target, px
  iconSizeDirs = ["48x48", "32x32", "24x24", "22x22", "16x16", "scalable"]
  iconCatDirs = ["apps", "status", "panel", "actions", "devices"]
  iconThemeDirs = ["hicolor", "Adwaita"]

proc findIconFile*(name, themePath: string): string =
  if name.len == 0: return ""
  var dirs: seq[string] = @[]
  if themePath.len > 0: dirs.add themePath
  let home = getHomeDir()
  for th in iconThemeDirs:
    dirs.add home / ".local/share/icons" / th
    dirs.add "/usr/share/icons/" & th
  for d in dirs:
    for ext in [".png", ".svg"]:
      let direct = d / (name & ext)
      if fileExists(direct): return direct
  for d in dirs:
    for sz in iconSizeDirs:
      for cat in iconCatDirs:
        for ext in [".png", ".svg"]:
          let cand = d / sz / cat / (name & ext)
          if fileExists(cand): return cand
  ""

proc freeIconFor(k: string) =
  var found: Icon
  if icons.pop(k, found) and found != nil:
    found.freeIcon
    iconSig.del(k)

proc enqueueIcon(key, sig, path: string) =
  for j in iconJobs:
    if j.key == key and j.sig == sig: return
  var j = IconJob(stage: jSize, key: key, sig: sig, path: path)
  j.p = spawnProcess(@["magick", "identify", "-format", "%w %h", path])
  iconJobs.add j

proc finishIcon(j: IconJob; bytes: string) =
  let n = int(j.w) * int(j.h)
  if n <= 0 or bytes.len < n * 4: return
  var argb = newSeq[uint32](n)
  for i in 0 ..< n:
    let o = i * 4
    argb[i] = (uint32(bytes[o+3]) shl 24) or (uint32(bytes[o]) shl 16) or
              (uint32(bytes[o+1]) shl 8) or uint32(bytes[o+2])
  # BGRA bytes -> native ARGB32: b,g,r,a -> a<<24 | r<<16 | g<<8 | b
  # (argb[i] built from: a=o+3, b=o, g=o+1, r=o+2)
  let icon = loadIcon(argb, j.w, j.h)
  if icon != nil:
    freeIconFor(j.key)
    icons[j.key] = icon
    iconSig[j.key] = j.sig

proc tickIconJobs*() =
  var i = 0
  while i < iconJobs.len:
    var j = iconJobs[i]
    if j.p.poll():
      if j.stage == jSize:
        let dims = j.p.output.strip.split(WhiteSpace)
        if dims.len >= 2 and parseInt(dims[0]) > 0:
          var w = parseInt(dims[0])
          var h = parseInt(dims[1])
          if max(w, h) > iconMax:
            let sc = float64(iconMax) / float64(max(w, h))
            w = max(1, int(float64(w) * sc))
            h = max(1, int(float64(h) * sc))
          j.w = w.int32
          j.h = h.int32
          var scale = ""
          if max(w, h) < iconMax or dims[0].parseInt > iconMax or
              dims[1].parseInt > iconMax:
            scale = $w & "x" & $h
          var args = @["magick", j.path, "-depth", "8"]
          if scale.len > 0: args.add @["-resize", scale]
          args.add @["bgra:-"]
          j.p.close()
          j.p = spawnProcess(args)
          j.stage = jPixels
          iconJobs[i] = j
          continue
        j.p.close()
        iconJobs.del(i)
        continue
      else:
        finishIcon(j, j.p.output)
        j.p.close()
        iconJobs.del(i)
        continue
    iconJobs[i] = j
    inc i

func itemKey*(it: TrayItem): string = it.service & it.path

func pixmapSig*(it: TrayItem): string =
  if it.pixmaps.len == 0: ""
  else:
    let p = it.pixmaps[^1] ## the last size is usually the best one
    $p.width & "x" & $p.height & ":" & $p.argb.len & ":" &
      $p.argb[0] & ":" & $p.argb[^1]

proc cacheSig*(it: TrayItem): string =
  ## Identity of the icon's current source: the pixmap bytes, or the
  ## theme file (found on disk, so a repoint by pamac's update/no-update
  ## icon swap busts the cache and reloads).
  if it.pixmaps.len > 0:
    "px:" & it.pixmapSig
  else:
    let f = findIconFile(it.iconName, it.iconThemePath)
    (if f.len > 0: "file:" & f else: "")

proc iconFor*(it: TrayItem): Icon =
  let k = it.itemKey
  let sig = it.cacheSig
  if sig.len == 0: return nil         # nothing to show: letter tile
  if icons.hasKey(k):
    if iconSig.getOrDefault(k) == sig:
      return icons[k]
    freeIconFor(k)                    # stale pixmap/file: replace below
  elif iconSig.getOrDefault(k) == sig:
    return nil                        # decode in flight (or failed): tile
  iconSig[k] = sig
  if it.pixmaps.len > 0:
    let p = it.pixmaps[^1]
    let icon = loadIcon(p.argb, p.width, p.height)
    if icon != nil:
      icons[k] = icon
    return nil
  let file = findIconFile(it.iconName, it.iconThemePath)
  if file.len > 0:
    enqueueIcon(k, sig, file)
  nil

proc loadIconFile*(path: string): Icon =
  ## One-shot decode of a known file (a button icon next to buttons.toml):
  ## enqueues the same two-child job chain as `iconFor`; nil until it lands.
  if path.len == 0 or not fileExists(path): return nil
  let key = "file:" & path
  if icons.hasKey(key): return icons[key]
  enqueueIcon(key, "", path)
  nil

proc pruneIcons*(alive: HashSet[string]) =
  var gone: seq[string] = @[]
  for k in icons.keys:
    if k notin alive: gone.add k
  for k in gone: freeIconFor(k)
