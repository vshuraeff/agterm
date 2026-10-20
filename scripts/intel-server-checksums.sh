#!/usr/bin/env bash
# usage: scripts/intel-server-checksums.sh X.Y.Z <out>
# writes the agterm-server.sha256 that upstream's vX.Y.Z app carries, once it matches upstream's two tarballs.
# `agtermctl server install` downloads agterm-server from umputun/agterm, so the fork app needs upstream's sums.
set -euo pipefail
[[ $# -eq 2 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'usage: scripts/intel-server-checksums.sh X.Y.Z <out>\n' >&2; exit 2; }
version=$1
out=$2
fail() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

dir=$(mktemp -d)
chmod 700 "$dir"
mnt="$dir/mnt"
attached=
cleanup() { [[ -z "$attached" ]] || hdiutil detach -quiet "$mnt" || true; rm -rf "$dir"; }
trap cleanup EXIT

names=("agterm-server-$version-linux-aarch64.tar.gz" "agterm-server-$version-linux-x86_64.tar.gz")
gh release download "v$version" --repo umputun/agterm --dir "$dir" \
  --pattern "agterm-$version.dmg" --pattern "${names[0]}" --pattern "${names[1]}"
mkdir "$mnt"
hdiutil attach -readonly -nobrowse -quiet -mountpoint "$mnt" "$dir/agterm-$version.dmg"
attached=1
app="$mnt/agterm.app"
codesign --verify --deep --strict "$app" || fail "upstream's v$version app fails its signature check"
spctl -a -t execute "$app" 2> /dev/null || fail "Gatekeeper rejects upstream's v$version app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] \
  || fail "upstream's DMG does not hold version $version"
cp "$app/Contents/Resources/agterm-server.sha256" "$dir/sums" || fail "upstream's v$version app has no agterm-server.sha256"
hdiutil detach -quiet "$mnt"
attached=

# exactly one well-formed line per tarball, the shape ServerInstall.checksum accepts
[[ "$(wc -l < "$dir/sums" | tr -d ' ')" == 2 ]] || fail 'upstream checksum file does not have two lines'
for name in "${names[@]}"; do
  [[ "$(grep -Ec "^[0-9a-f]{64}  ${name//./\\.}\$" "$dir/sums")" == 1 ]] || fail "no single checksum line for $name"
done
(cd "$dir" && shasum -a 256 -c sums > /dev/null) || fail "upstream's tarballs differ from its app's checksums"
cp "$dir/sums" "$out"
