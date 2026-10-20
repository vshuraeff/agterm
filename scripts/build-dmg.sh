#!/usr/bin/env bash
# usage: scripts/build-dmg.sh <app> <output.dmg>
# the window layout lives in scripts/dmg/; dmgbuild and its dependencies are pinned so every run lays out the same image.
set -euo pipefail
[[ $# -eq 2 && -d "$1" ]] || { printf 'usage: scripts/build-dmg.sh <app> <output.dmg>\n' >&2; exit 2; }
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
layout="$(cd "$(dirname "$0")/dmg" && pwd)"
mkdir -p "$(dirname "$2")"
uvx --python 3.12 --with ds-store==1.3.3 --with mac-alias==2.2.3 --from dmgbuild==1.6.7 dmgbuild \
  -s "$layout/settings.py" -D app="$app" -D background="$layout/background.tiff" agterm "$2"
