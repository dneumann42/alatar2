import ellipse_ui

import nomicon/[actions, menu, state, theme]

var screen = newState()

proc prepare() =
  actions.refreshAll(screen)

proc view() =
  setTheme(gothicTheme(screen.darkStyle))
  render(screen)

when isMainModule:
  run App(window: WindowConfig(title: "nomicon", width: 640, height: 720),
          setup: prepare, view: view)
