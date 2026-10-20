#!/usr/bin/env bash
# renders background.svg into the two-resolution background.tiff; needs rsvg-convert and the JetBrains Mono font
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rsvg-convert -w 660 -h 420 background.svg -o "$tmp/background.png"
rsvg-convert -w 1320 -h 840 background.svg -o "$tmp/background@2x.png"
tiffutil -cathidpicheck "$tmp/background.png" "$tmp/background@2x.png" -out background.tiff
