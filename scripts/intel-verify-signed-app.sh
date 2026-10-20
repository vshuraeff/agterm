#!/usr/bin/env bash
# usage: scripts/intel-verify-signed-app.sh <app> <version>
# fails unless <app> is this fork's Developer ID signed, notarized x86_64 build of <version>.
set -euo pipefail
[[ $# -eq 2 && -d "$1" ]] || { printf 'usage: scripts/intel-verify-signed-app.sh <app> <version>\n' >&2; exit 2; }
app=$1
bash "$(dirname "$0")/intel-verify-arch.sh" "$app" > /dev/null
codesign --verify --deep --strict "$app"
signature=$(codesign -dvv "$app" 2>&1)
[[ "$signature" == *$'\nAuthority=Developer ID Application:'* ]] || { printf '%s is not Developer ID signed\n' "$app" >&2; exit 1; }
xcrun stapler validate "$app" > /dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == io.github.vshuraeff.agterm ]] \
  || { printf '%s has the wrong bundle id\n' "$app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$2" ]] \
  || { printf '%s is not version %s\n' "$app" "$2" >&2; exit 1; }
