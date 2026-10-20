# dmgbuild settings for the installer window, loaded by scripts/build-dmg.sh
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]

# the frame is the 660x420 point background plus the title bar; background.svg puts icon centers at x 165 and 495, y 205.
window_rect = ((200, 120), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {appname: (165, 205), "Applications": (495, 205)}
