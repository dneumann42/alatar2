#!/usr/bin/env python3
"""Generate the qgtk3 QT_GUI_GTK_JSON palette for pcmanfm-qt.

The Qt gtk3 platform theme can take its whole palette mapping from a JSON
file (QT_GUI_GTK_JSON).  This script emits *fixed* brushes so pcmanfm-qt
gets a black background with bright borders, without touching the system
GTK theme.  Re-run after changing COLORS below; output file:
~/.config/pcmanfm-qt/gtk3-palette.json
"""
import json
import os

# Role -> color.  Fusion/Windows styles draw widget frames/outlines from
# Dark/Mid/Light/Midlight, so those are the "bright borders".
COLORS = {
    "Window":          "#0b0d12",   # near-black chrome
    "Base":            "#000000",   # pure-black file views
    "AlternateBase":   "#111318",   # subtle alternating rows
    "ToolTipBase":     "#0b0d12",
    "ToolTipText":     "#e6eaf2",
    "WindowText":      "#e6eaf2",
    "Text":            "#e6eaf2",
    "ButtonText":      "#e6eaf2",
    "Button":          "#161922",   # toolbar / buttons slightly lifted
    "Background":      "#0b0d12",
    "Foreground":      "#e6eaf2",
    "Highlight":       "#89b4fa",
    "HighlightedText": "#0b0d12",
    "Light":           "#b4befe",   # bright bevels
    "Midlight":        "#89b4fa",
    "Mid":             "#74c7ec",
    "Dark":            "#89b4fa",   # main frame/outline color -> bright borders
    "Shadow":          "#585b70",
    "Link":            "#74c7ec",
    "LinkVisited":     "#cba6f7",
    "PlaceholderText": "#6c7086",
}

PALETTES = [
    "SystemPalette", "CheckBoxPalette", "RadioButtonPalette",
    "ComboBoxPalette", "GroupBoxPalette", "MenuPalette",
    "TabBarPalette", "TextLineEditPalette", "LabelPalette",
]


def brush(color):
    return {
        "ColorGroup": "All",
        "ColorScheme": "Unknown",
        "SourceType": "Fixed",
        "SourceData": {
            "FixedBrush": {"Color": color, "Width": -1, "Height": -1},
        },
    }


doc = {
    "QtGtk3Palettes": {
        p: {role: [brush(color)] for role, color in COLORS.items()}
        for p in PALETTES
    }
}

out = os.path.expanduser("~/.config/pcmanfm-qt/gtk3-palette.json")
with open(out, "w") as f:
    json.dump(doc, f, indent=1)
print(f"wrote {out}")
