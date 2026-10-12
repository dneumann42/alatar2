import std/[os]

import alatar/packages

proc start*() {.raises: [].} =
  try:
    discard
  except:
    echo getCurrentExceptionMsg()

when isMainModule:
  start()
