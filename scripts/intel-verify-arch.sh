#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: intel-verify-arch.sh APP}
for name in agterm agtermctl agterm-session-host zmx; do
  binary="$app/Contents/MacOS/$name"
  [[ -f "$binary" && "$(lipo -archs "$binary")" == x86_64 ]] || {
    printf 'required Intel executable missing or wrong architecture: %s\n' "$name" >&2
    exit 1
  }
done

files=$(mktemp)
trap 'rm -f "$files"' EXIT
find "$app" -type f -print0 > "$files"
while IFS= read -r -d '' binary; do
  kind=$(file -b "$binary")
  case "$kind" in
    *Mach-O*)
      [[ "$(lipo -archs "$binary")" == x86_64 ]] || {
        printf 'non-Intel Mach-O in app: %s\n' "$binary" >&2
        exit 1
      }
      ;;
  esac
done < "$files"
lipo -archs "$app/Contents/MacOS/agterm"
