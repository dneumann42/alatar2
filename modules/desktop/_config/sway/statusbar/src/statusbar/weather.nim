# ============================================================================
# Weather block source: wttr.in, re-fetched every 10 minutes (be polite to
# the public service). Location is pinned by coordinates (Walla Walla, WA) —
# without them wttr.in guesses from IP geolocation and lands on Kennewick
# instead. Last good data is kept on failure; the next attempt is still
# 10 min after this one.
# ============================================================================

import std/[os, osproc, json]
import ./palette

const
  wxUrl = "https://wttr.in/46.0646,-118.3430?format=j1"
  wxIntervalMs = 10 * 60 * 1000

proc wxIcon*(code: string): string =
  ## WMO-style weather codes as reported by wttr.in
  case code
  of "113": gSun
  of "116": gPartly
  of "119", "122": gCloud
  of "143", "248": gFog
  of "176", "263", "266", "269", "272", "275", "278", "281", "284", "293",
     "296", "299", "302", "305", "308", "311", "314", "317", "320", "353",
     "356", "359", "362", "368": gRain
  of "179", "225", "227", "230", "329", "332", "335", "338", "350", "365",
     "367": gSnow
  of "200", "386", "389", "392", "395", "398": gStorm
  else: gCloud

# Payload sent over wxChan: "tempF<TAB>icon".
var wxChan*: Channel[string]

proc wxWorker*() {.thread.} =
  while true:
    try:
      let outp = execProcess(findExe("curl"),
                             args = ["-s", "--max-time", "8", wxUrl], options = {})
      if outp.len > 0:
        let j = outp.parseJson()
        let cur = j["current_condition"][0]
        let temp = cur["temp_F"].getStr("")
        let icon = wxIcon(cur["weatherCode"].getStr(""))
        if temp.len > 0:
          wxChan.send(temp & "\t" & icon)
    except CatchableError:
      discard
    sleep(wxIntervalMs)
