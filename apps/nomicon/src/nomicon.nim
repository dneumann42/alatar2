## Nomicon -- alatar's GUI app, built on the ellipse kit.
##
## The counter example from documentation/nim-tutorial.md (ellipse): every
## frame re-runs `view` from top to bottom, declaring the clay tree; the
## only state is `count`, plain module-scope data that the buttons mutate
## through the immediate-mode round trip.
##
##   nimble build && ./bin/nomicon        (windowed, SDL3)
##   ./bin/nomicon --tui                  (or ELLIPSE_TUI=1: same UI in a
##                                         terminal, no SDL)

import ellipse_ui

var count = 0

proc view() =
  clay "root", col(width = grow(), height = grow(), padding = padAll(24),
                   gap = 8, alignX = centerX, alignY = centerY):
    heading("Nomicon", 1)
    text($count, 48)
    clay "buttons", row(gap = 12):
      if button(hashId("dec"), "Decrement", height = fixedPx(44)):
        dec count
      if button(hashId("inc"), "Increment", height = fixedPx(44)):
        inc count
      if button(hashId("reset"), "Reset", height = fixedPx(44)):
        count = 0
    caption("Edit src/nomicon.nim and save: the app shell hot-reloads.")

when isMainModule:
  run App(window: WindowConfig(title: "nomicon"), view: view)
