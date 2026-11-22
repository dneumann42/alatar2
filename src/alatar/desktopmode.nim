## Appearance controls shared by the bar and Nomicon.

import ellipse_ui/appearance

export appearance.systemDarkMode, appearance.setDesktopDarkMode

template darkMode*(): bool = systemDarkMode()
template setDarkMode*(dark: bool) = setDesktopDarkMode(dark)
