# ============================================================================
# Palette, glyphs, and shared constants.
# Icons are Font Awesome 5 glyphs (present in the JetBrainsMono Nerd Font the
# bar uses). Colors mirror appearance.conf — keep in sync.
# ============================================================================

const
  cAccent*  = "#89b4fa"
  cAccent2* = "#74c7ec"
  cUrgent*  = "#f38ba8"
  cText*    = "#e6eaf2"
  cMuted*   = "#9aa4b2"

# ---- Font Awesome 5 solid glyphs ----
const
  gPlay*     = "\uF04B"
  gPause*    = "\uF04C"
  gClock*    = "\uF017"
  gCalendar* = "\uF073"
  gWired*    = "\uF0C1"
  gWifi*     = "\uF1EB"
  gOffline*  = "\uF127"
  gCpu*      = "\uF4BC"
  gRam*      = "\uF2DB"
  gTemp*     = "\uF2C9"
  gGpu*      = "\uF06D"
  gVoff*     = "\uF026"
  gVlow*     = "\uF027"
  gVhigh*    = "\uF028"

# ---- weather emoji (rendered by Noto Color Emoji via pango fallback) ----
# NB: literal UTF-8, not \U escapes — Nim's \U takes only 4 hex digits, so
# "\U0001F324" would compile to 0x0001 followed by literal "F324".
const
  gSun*    = "🌞"      # clear
  gPartly* = "🌤️"  # sun behind small cloud
  gCloud*  = "☁️"      # overcast
  gRain*   = "🌧️"  # rain
  gSnow*   = "🌨️"  # snow
  gStorm*  = "🌩️"  # thunder
  gFog*    = "🌫️"  # fog/mist

const DEGREE* = "\u00B0"

const strawberryId* = "org.strawberrymusicplayer.strawberry"
