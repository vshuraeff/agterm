#!/usr/bin/env bash
# compare the same source built with and without release whole-module optimization.
set -euo pipefail
products=${1:?expected Build/Products directory}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
nm "$products/Release/agterm.app/Contents/MacOS/agterm" > "$scratch/release.nm"
nm "$products/Debug/agterm.app/Contents/MacOS/agterm.debug.dylib" > "$scratch/debug.nm"
xcrun swift-demangle < "$scratch/release.nm" > "$scratch/release.symbols"
xcrun swift-demangle < "$scratch/debug.nm" > "$scratch/debug.symbols"
for configuration in release debug; do
  awk '/ t closure #/ {$1=$2=""; sub(/^  /, ""); print}' "$scratch/$configuration.symbols" \
    | LC_ALL=C sort -u > "$scratch/$configuration.closures"
  test -s "$scratch/$configuration.closures" || { echo 'missing closure symbols' >&2; exit 1; }
done
awk '/@Swift.MainActor @Sendable \(\) -> \(\)/ {
  sub(/@Swift.MainActor @Sendable/, "@Sendable"); print
}' "$scratch/release.closures" | LC_ALL=C sort -u > "$scratch/release.actor"
awk '/@Sendable \(\) -> \(\)/ && !/@Swift.MainActor/' "$scratch/debug.closures" \
  | LC_ALL=C sort -u > "$scratch/debug.nonactor"
LC_ALL=C comm -12 "$scratch/release.actor" "$scratch/debug.nonactor" > "$scratch/unexpected"
if test -s "$scratch/unexpected"; then
  cat "$scratch/unexpected" >&2
  echo 'Release introduced MainActor isolation on nonisolated Debug closures' >&2
  exit 1
fi
echo 'no Release-only MainActor closure isolation'
