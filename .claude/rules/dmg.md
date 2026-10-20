---
paths:
  - "scripts/build-dmg.sh"
  - "scripts/check-dmg.sh"
  - "scripts/dmg/**"
---

## Installer DMG (`scripts/build-dmg.sh`, `scripts/dmg/`)

- Finder draws icon labels black over a background picture even in dark appearance (macOS 15.8), so the
  background keeps a light pad under each label; a dark area behind a label makes it unreadable.
- `window_rect` is the window frame including the title bar, so its height is the background's plus about 28 pt.
  The status bar, path bar and tab bar follow the viewer's global Finder settings and cannot be turned off
  from the image, so keep everything that matters away from the bottom edge, where those bars crop it.
- `background.svg` is the source and `render-background.sh` regenerates the committed `background.tiff`;
  `check-dmg.sh` compares the mounted image against that TIFF, so commit both together.
- `check-layout.py` takes its expected values from `settings.py` but checks only the keys it lists, so a
  layout setting added there gets an entry in its table too. Its ds-store and mac-alias pins match `build-dmg.sh`.
- dmgbuild drives `hdiutil`, whose output is not byte-reproducible; what is fixed is the pinned recipe plus
  `check-dmg.sh`'s installation-contract check, never a comparison of two images.
