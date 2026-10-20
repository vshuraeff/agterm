#!/usr/bin/env bash
# usage: scripts/check-dmg.sh <dmg> <app>
# checks the installation contract, not byte identity: the top-level entries, the scripts/dmg background and
# Finder records, and a validly signed app matching <app> in contents, file types, modes and links.
set -euo pipefail
[[ $# -eq 2 && -f "$1" && -d "$2" ]] || { printf 'usage: scripts/check-dmg.sh <dmg> <app>\n' >&2; exit 2; }
layout="$(cd "$(dirname "$0")/dmg" && pwd)"
app=$2
name=$(basename "$app")
mnt=$(mktemp -d)
trap 'hdiutil detach "$mnt" > /dev/null 2>&1 || true; rmdir "$mnt"' EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$1" > /dev/null
ok=1
problem() { printf 'check-dmg: %s\n' "$*" >&2; ok=0; }
[[ "$(cd "$mnt" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort)" \
  == "$(printf '%s\n' ./.DS_Store ./.VolumeIcon.icns ./.background.tiff ./Applications "./$name" | LC_ALL=C sort)" ]] \
  || problem 'unexpected top-level entries'
[[ "$(readlink "$mnt/Applications")" == /Applications ]] || problem 'Applications is not a link to /Applications'
cmp -s "$mnt/.background.tiff" "$layout/background.tiff" || problem 'background differs from scripts/dmg'
cmp -s "$mnt/.VolumeIcon.icns" "$app/Contents/Resources/AppIcon.icns" || problem 'volume icon is not the app icon'
uv run -q --script "$layout/check-layout.py" "$mnt" "$app" || ok=0
# diff -r compares contents only, so types, permission bits and link targets are listed separately.
entries() { (cd "$1" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%HT %Mp%Lp %N%SY'); }
diff -r "$mnt/$name" "$app" > /dev/null 2>&1 || problem "$name differs from $app"
[[ "$(entries "$mnt/$name")" == "$(entries "$app")" ]] || problem "$name file types, modes or links differ from $app"
codesign --verify --deep --strict "$mnt/$name" 2> /dev/null || problem "$name in the image fails codesign --verify"
(( ok ))
