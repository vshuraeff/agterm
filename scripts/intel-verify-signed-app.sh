#!/usr/bin/env bash
# usage: scripts/intel-verify-signed-app.sh <app> <version>
# fails unless <app> is this fork's Developer ID signed, notarized x86_64 build of <version>.
set -euo pipefail
[[ $# -eq 2 && -d "$1" ]] || { printf 'usage: scripts/intel-verify-signed-app.sh <app> <version>\n' >&2; exit 2; }
app=$1
trap 'printf "%s: failed at line %d: %s\n" "${0##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR
bash "$(dirname "$0")/intel-verify-arch.sh" "$app" > /dev/null
codesign --verify --deep --strict "$app"
signature=$(codesign -dvv "$app" 2>&1)
[[ "$signature" == *$'\nAuthority=Developer ID Application:'* ]] || { printf '%s is not Developer ID signed\n' "$app" >&2; exit 1; }
bash "$(dirname "$0")/intel-stapler-validate.sh" "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == io.github.vshuraeff.agterm ]] \
  || { printf '%s has the wrong bundle id\n' "$app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$2" ]] \
  || { printf '%s is not version %s\n' "$app" "$2" >&2; exit 1; }
# Sparkle must read the fork's appcast with the fork's key: upstream's offers its arm64 app
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$app/Contents/Info.plist")" \
  == https://github.com/vshuraeff/agterm/releases/latest/download/appcast.xml ]] \
  || { printf '%s does not read the fork appcast\n' "$app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")" \
  == "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$(dirname "$0")/../agterm/Info.plist")" ]] \
  || { printf '%s does not carry the fork update key\n' "$app" >&2; exit 1; }
for key in SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print $key" "$app/Contents/Info.plist")" == true ]] \
    || { printf '%s does not set %s\n' "$app" "$key" >&2; exit 1; }
done
