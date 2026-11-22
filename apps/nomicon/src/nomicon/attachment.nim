import std/strutils

import ellipse_ui

proc nomiconWindow*(title: string, width, height: int32,
                    args: seq[string]): WindowConfig =
  result = WindowConfig(title: title, width: width, height: height,
                        resizable: true, transparent: true)
  if args.len == 5 and args[0] == "--attach":
    let outputWidth = max(1, parseInt(args[4]))
    let popupWidth = min(int(width), outputWidth)
    let inset = max(0, parseInt(args[3]))
    let margin = if args[2] == "left": outputWidth - inset - popupWidth
                 else: inset
    result.width = int32(popupWidth)
    result.resizable = false
    result.layer = LayerConfig(enabled: true, edge: edgeTop, level: layerOverlay,
      thickness: height, length: result.width, exclusive: 0, anchorEnd: true,
      marginEnd: int32(clamp(margin, 0, outputWidth - popupWidth)), output: args[1],
      keyboard: keyboardOnDemand, namespace: title)
