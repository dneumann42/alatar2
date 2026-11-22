import std/[os, osproc]

import ellipse_ui
import ellipse_ui/keys
from ellipse/platform/platform import quit

import alatar/[desktopchrome, desktopmode, desktoptheme]
import nomicon/[attachment, widgets]

var launchError {.threadvar.}: string

proc launchSystemdui() =
  var executable = findExe("systemdui")
  if executable.len == 0:
    let project = getHomeDir() / "Workspace" / "systemdui"
    for path in [project / "bin" / "systemdui", project / "build" / "systemdui"]:
      executable = findExe(path)
      if executable.len > 0: break
  if executable.len == 0:
    launchError = "Could not find the systemdui executable."
    return

  try:
    let child = startProcess(executable, options = {poParentStreams})
    close(child)
    platform.quit()
  except CatchableError as error:
    launchError = "Could not launch systemdui: " & error.msg

proc view() {.gcsafe.} =
  if pressed("Escape"):
    platform.quit()
    return

  applyDesktopTheme(darkMode())
  let t = activeTheme
  clay "launcher", col(width = grow(), height = grow(), padding = padAll(6), gap = 8)
      .chrome(panel):
    clay "launcher.title", row(width = grow(), height = fixedPx(29),
        padding = Padding(left: 8), alignY = centerY).chrome(selected):
      textElement("Nomicon", TextConfig(fontSize: t.text.menu, fontId: MonoFont,
        color: t.palette.onAccent))
    if quickButton(elementId("systemdui"), "systemdui", "Manage systemd units",
        active = false, arrow = false, width = grow()) == bhToggle:
      launchSystemdui()
    if launchError.len > 0:
      caption(launchError)

when isMainModule:
  run App(window: nomiconWindow("nomicon-launcher", 320, 156, commandLineParams()),
          setup: installChrome, view: view)
