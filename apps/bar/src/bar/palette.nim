import ellipse_ui
import alatar/[desktopmode, desktoptheme]

export desktoptheme.hexColor, desktoptheme.applyChrome, desktoptheme.themeFrameInterval

type Palette* = DesktopPalette

proc refresh*(): Palette = desktopPalette(darkMode())

func get*(p: Palette, name: string, fallback: Color): Color =
  case name
  of "bar_bg": p.background
  of "bar_flat": p.onAccent
  of "surface", "button_hover_bg": p.surface
  of "text", "button_hover_fg": p.text
  of "muted", "button_fg": p.muted
  of "accent": p.accent
  of "accent2": p.accent2
  of "inactive": p.border
  of "urgent": p.urgent
  else: fallback
