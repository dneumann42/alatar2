#!/bin/sh

set -eu

wallpapers="${WALLPAPERS_DIR:-$HOME/Pictures/Wallpapers}"

if [ ! -d "$wallpapers" ]; then
    echo "wallpaper directory not found: $wallpapers" >&2
    exit 1
fi

selection="$(mktemp)"

# Sway/swayfx treat real fullscreen as deliberately opaque: on entering
# fullscreen the compositor disables the shell-background (wallpaper) layer
# and paints a black backdrop under the window, so a transparent fullscreen
# window can never show the desktop behind it. To get a fullscreen-looking
# picker that stays see-through, the picker is floated + maximized to the
# whole output by its for_window rule instead, and the bars are hidden while
# it is open.
set_bar_mode() {
    mode="$1"
    swaymsg -t get_bar_config_ids 2>/dev/null |
    tr -d '[]" ' |
    while read -r id; do
        [ -n "$id" ] && swaymsg "bar $id mode $mode" >/dev/null 2>&1 || true
    done
}

cleanup() {
    set_bar_mode dock
    rm -f "$selection"
}
trap cleanup EXIT

set_bar_mode invisible

# Configure the gallery: transparent window, vim-style movement, and write
# the selected path to $selection on Enter/Space. Cancel exits without
# writing. overlay = false keeps swayimg from forcing the geometry of the
# focused window, so the for_window rule can size it.
SWAYIMG_SELECTION="$selection" swayimg \
    --gallery \
    --appid wallpaper-picker \
    --execute '
        swayimg.overlay = false
        swayimg.gallery.window_color = 0x00000000
        local out = os.getenv("SWAYIMG_SELECTION")
        swayimg.gallery.on_key("h", function() swayimg.gallery.select("left") end)
        swayimg.gallery.on_key("j", function() swayimg.gallery.select("down") end)
        swayimg.gallery.on_key("k", function() swayimg.gallery.select("up") end)
        swayimg.gallery.on_key("l", function() swayimg.gallery.select("right") end)
        swayimg.gallery.on_key({"Return", "space"}, function()
            local image = swayimg.gallery.get_image()
            if image and image.path and out then
                local f = io.open(out, "w")
                if f then
                    f:write(image.path)
                    f:close()
                end
            end
            swayimg.exit(0)
        end)
        swayimg.gallery.on_key("q", function() swayimg.exit(1) end)
    ' \
    -- "$wallpapers" || true

if [ ! -s "$selection" ]; then
    exit 1
fi

image="$(cat "$selection")"
awww img "$image"

# New wallpaper, new theme: wallust extracts a 16-color palette from the very
# picture awww is now showing, renders the sway/kitty templates into
# ~/.cache/wallust/ and reloads sway (all configured in
# ~/.config/wallust/wallust.toml). Best-effort: a theme failure must never
# undo the wallpaper change itself.
if command -v wallust >/dev/null 2>&1; then
    wallust run "$image" || echo "set-wallpaper: wallust failed, theme unchanged" >&2
else
    echo "set-wallpaper: wallust not on PATH, theme unchanged" >&2
fi
