# Einstellungen für dmgbuild (tools/make_dmg.sh): Installations-DMG mit Klimacontrol.app und „Programme“ vor einem
# Hintergrund mit Anleitung. Positionen und Maße passen zu tools/make_dmg_background.swift (640 × 380, Symbole bei
# x 160 und 480, y 210). dmgbuild schreibt die Finder-Ansicht (.DS_Store) selbst – der Finder speichert per
# AppleScript gesetzte Hintergründe und Symbolgrößen seit macOS 26 nicht mehr.
# `defines` stellt dmgbuild bereit (-D app=… -D background=… -D icon=…).

app = defines["app"]  # noqa: F821

format = "ULFO"
filesystem = "HFS+"
files = [app]
symlinks = {"Programme": "/Applications"}
icon = defines["icon"]  # noqa: F821
# Die @2x-Fassung daneben fasst dmgbuild selbst zu einer HiDPI-TIFF zusammen.
background = defines["background"]  # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (640, 380))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    "Klimacontrol.app": (160, 210),
    "Programme": (480, 210),
}
