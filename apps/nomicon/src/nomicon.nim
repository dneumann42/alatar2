import std/os
import ellipse_ui
import ellipse_ui/keys
from ellipse/platform/platform import docked, quit
from ellipse/platform/layershell import destroyLayer
import sdl3 as sdl
import alatar/[desktopchrome, desktopmode, desktoptheme]

import nomicon/[actions, attachment, menu, state]

var screen {.threadvar.}: State
type LoadedSettings = tuple[group: SettingsGroup, state: State]

var loadedSettings: Channel[LoadedSettings]
var loaders: array[SettingsGroup, Thread[SettingsGroup]]

proc flushWayland(display: pointer): cint {.
  importc: "wl_display_flush", header: "<wayland-client.h>".}

proc loadInitialSettings(group: SettingsGroup) {.thread.} =
  loadedSettings.send((group, loadSettings(group)))

proc prepare() {.gcsafe.} =
  screen = newState()
  screen.pending = {low(SettingsGroup)..high(SettingsGroup)}
  installChrome()
  loadedSettings.open(ord(high(SettingsGroup)) + 1)
  for group in SettingsGroup:
    createThread(loaders[group], loadInitialSettings, group)

proc view() {.gcsafe.} =
  if pressed("Escape"):
    platform.quit()
    return
  while screen.pending != {}:
    let loaded = loadedSettings.tryRecv()
    if not loaded.dataAvailable: break
    let (group, state) = loaded.msg
    joinThread(loaders[group])
    screen.applySettings(group, state)
  if screen.pending != {}: requestFrameIn(50_000_000)
  screen.darkStyle = darkMode()
  applyDesktopTheme(screen.darkStyle)
  render(screen)

when isMainModule:
  const Width = 640
  const Height = 720
  run App(window: nomiconWindow("nomicon-settings", Width, Height,
                               commandLineParams()),
    setup: prepare, view: view)
  if screen != nil:
    if screen.pending != {}:
      let window = sdlWindow()
      if window != nil:
        let raw = cast[sdl.Window](window)
        if docked():
          # Remove the popup while background settings reads finish.
          let display = sdl.getPointerProperty(sdl.getWindowProperties(raw),
            sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil)
          destroyLayer()
          if display != nil: discard flushWayland(display)
        else:
          discard sdl.hideWindow(raw)
      # Let outstanding reads finish before the process tears down Nim state.
      for group in screen.pending:
        joinThread(loaders[group])
    loadedSettings.close()
