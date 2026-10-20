# /// script
# requires-python = "==3.12.*"
# dependencies = ["ds-store==1.3.3", "mac-alias==2.2.3"]
# ///
# usage: uv run -q --script scripts/dmg/check-layout.py <volume> <app>
# compares the Finder records in <volume>/.DS_Store with what settings.py asks dmgbuild to write.
import os
import sys

from ds_store import DSStore
from mac_alias import Alias

volume, app = sys.argv[1:]
settings = {"defines": {"app": app, "background": ""}}
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings.py")) as f:
    exec(f.read(), settings)

(x, y), (w, h) = settings["window_rect"]
want = {
    ("bwsp", "WindowBounds"): f"{{{{{x}, {y}}}, {{{w}, {h}}}}}",
    ("bwsp", "ShowStatusBar"): settings["show_status_bar"],
    ("bwsp", "ShowTabView"): settings["show_tab_view"],
    ("bwsp", "ShowToolbar"): settings["show_toolbar"],
    ("bwsp", "ShowPathbar"): settings["show_pathbar"],
    ("bwsp", "ShowSidebar"): settings["show_sidebar"],
    ("icvp", "showIconPreview"): settings["show_icon_preview"],
    ("icvp", "iconSize"): float(settings["icon_size"]),
    ("icvp", "textSize"): float(settings["text_size"]),
    ("icvp", "backgroundType"): 2,
}

problems = []
try:
    with DSStore.open(os.path.join(volume, ".DS_Store"), "r") as d:
        root = {code: d["."][code] for code in ("bwsp", "icvp", "icvl")}
        locations = {name: d[name]["Iloc"] for name in settings["icon_locations"]}
except Exception as e:
    sys.exit(f"check-dmg: .DS_Store is missing a layout record or unreadable: {e!r}")

for (code, key), value in want.items():
    if root[code].get(key) != value:
        problems.append(f"{code}.{key} is {root[code].get(key)!r}, settings.py wants {value!r}")
if root["icvl"][1] != b"icnv":
    problems.append(f"default view is {root['icvl'][1]!r}, not icon view")
alias = root["icvp"].get("backgroundImageAlias")
if not alias or Alias.from_bytes(alias).target.filename != ".background.tiff":
    problems.append("the background picture is not .background.tiff")
for name, at in settings["icon_locations"].items():
    if tuple(locations[name]) != tuple(at):
        problems.append(f"{name} sits at {locations[name]!r}, settings.py wants {at!r}")

for p in problems:
    print(f"check-dmg: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
