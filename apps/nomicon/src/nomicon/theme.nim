import ellipse_ui

func gnomePalette(dark: bool): Palette =
  result = defaultPalette()
  result.accent = rgb(53, 132, 228)
  result.selectedBg = if dark: rgb(122, 178, 255) else: rgb(130, 190, 255)
  result.onAccent = rgb(255, 255, 255)
  if dark:
    result.bg = rgb(18, 18, 24)
    result.panelBg = rgb(36, 38, 46)
    result.buttonBg = rgb(66, 71, 86)
    result.buttonHoverBg = rgb(88, 95, 114)
    result.buttonPressBg = rgb(52, 56, 68)
  else:
    result.bg = rgb(246, 246, 246)
    result.panelBg = rgb(255, 255, 255)
    result.panelBorder = rgb(208, 208, 208)
    result.buttonBg = rgb(224, 222, 220)
    result.buttonHoverBg = rgb(206, 204, 202)
    result.buttonPressBg = rgb(184, 183, 181)
    result.fieldBg = rgb(255, 255, 255)
    result.textColor = rgb(30, 32, 36)
    result.dimColor = rgb(120, 124, 130)
    result.labelColor = rgb(80, 84, 90)

func gnomeTheme*(dark: bool): Theme =
  result = defaultTheme()
  result.palette = gnomePalette(dark)
