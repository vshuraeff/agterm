#!/usr/bin/env bash
# usage: bash scripts/intel-release.sh X.Y.Z N [--publish|--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "$*" >&2; exit 1; }

version=${1:-}
respin=${2:-}
mode=${3:-}
[[ $# -ge 2 && $# -le 3 && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$respin" =~ ^[1-9][0-9]*$ ]] \
  || fail 'usage: scripts/intel-release.sh X.Y.Z N [--publish|--dry-run]'
[[ -z "$mode" || "$mode" == --dry-run || "$mode" == --publish ]] || fail 'unknown release option'
tag="intel-v$version-r$respin"
upstream="v$version"
repo=vshuraeff/agterm
workflow=intel-build.yml
head=$(git rev-parse HEAD)
tag_commit=$(git rev-parse --verify "refs/tags/$tag^{commit}")
[[ "$head" == "$tag_commit" ]] || fail 'HEAD must be the exact Intel release tag commit'
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail 'release checkout must be clean'
git fetch --quiet --no-tags "https://github.com/$repo.git" "refs/tags/$tag"
[[ "$(git rev-parse 'FETCH_HEAD^{commit}')" == "$head" ]] || fail 'fork tag differs from the local release commit'
git fetch --quiet --no-tags https://github.com/umputun/agterm.git "refs/tags/$upstream"
upstream_commit=$(git rev-parse 'FETCH_HEAD^{commit}')
git merge-base --is-ancestor "$upstream_commit" "$head" || fail 'release tag does not descend from its upstream tag'

private=$(mktemp -d)
chmod 700 "$private"
trap 'rm -rf "$private"' EXIT
gh run list --repo "$repo" --workflow "$workflow" --branch "$tag" --commit "$head" --status success \
  --limit 100 --json databaseId,headSha,headBranch,status,conclusion > "$private/runs.json"
run=$(jq -er --arg head "$head" --arg tag "$tag" '
  [.[] | select(.headSha == $head and .headBranch == $tag and .status == "completed" and .conclusion == "success")]
  | first.databaseId | select(type == "number")' "$private/runs.json")
mkdir "$private/download"
gh run download "$run" --repo "$repo" --name "$tag-unsigned" --dir "$private/download"
zip="$private/download/agterm-$version-x86_64-unsigned.zip"
[[ -f "$zip" ]] || fail 'expected unsigned zip is missing'
# gh before 2.67.0 exits 0 when no attestation is found.
gh_version=$(gh --version | sed -nE '1s/^gh version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[[ -n "$gh_version" && "$(printf '%s\n' 2.67.0 "$gh_version" | sort -V | head -n1)" == 2.67.0 ]] \
  || fail 'gh 2.67.0 or newer is required'
# policy flags validate certificate claims, not workflow-controlled predicate text.
gh attestation verify "$zip" --repo "$repo" \
  --cert-identity "https://github.com/$repo/.github/workflows/$workflow@refs/tags/$tag" \
  --source-ref "refs/tags/$tag" --source-digest "$head" --signer-digest "$head" --deny-self-hosted-runners
ditto -x -k "$zip" "$private/extracted"
app="$private/extracted/agterm.app"
arch=$(bash scripts/intel-verify-arch.sh "$app")
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == io.github.vshuraeff.agterm ]] \
  || fail 'built app has the wrong fork identity'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] \
  || fail 'built app version differs from the upstream tag'
if [[ "$mode" == --dry-run ]]; then
  printf 'CI run %s: provenance, bundle and architecture verified; stopped before credential access and signing\n' "$run"
  exit 0
fi

sign_id=${AGTERM_SIGN_IDENTITY:-}
notary_profile=${AGTERM_NOTARY_PROFILE:-agterm-notary}
if [[ -z "$sign_id" ]]; then
  security find-identity -v -p codesigning > "$private/identities"
  sign_id=$(awk '/"Developer ID Application:/{print $2; exit}' "$private/identities")
fi
[[ -n "$sign_id" && "$sign_id" != - ]] || fail 'a Developer ID Application signing identity is required'

notarize() {
  local artifact=$1 status submission diagnostics submitted=0
  if xcrun notarytool submit "$artifact" --keychain-profile "$notary_profile" \
    --wait --timeout 30m --output-format json > "$private/notary.json"; then
    submitted=1
  fi
  status=$(jq -er '.status | select(type == "string")' "$private/notary.json")
  submission=$(jq -er '.id | select(type == "string" and length > 0)' "$private/notary.json")
  if [[ "$status" != Accepted ]]; then
    # diagnostics stay private, outside uploaded release assets.
    if ! xcrun notarytool log "$submission" --keychain-profile "$notary_profile" > "$private/notary-rejection.json"; then
      printf 'notarization diagnostic retrieval failed\n' >&2
    else
      diagnostics=$(mktemp -d "${TMPDIR:-/tmp}/intel-notary-diagnostics.XXXXXX")
      chmod 700 "$diagnostics"
      cp "$private/notary-rejection.json" "$diagnostics/rejection.json"
      printf 'notarization diagnostics: %s/rejection.json\n' "$diagnostics" >&2
    fi
    fail "notarization rejected submission $submission"
  fi
  [[ "$submitted" == 1 ]] || fail 'notarization command failed despite its response'
}

helpers=(agtermctl zmx agterm-session-host)
find "$app" -type f -print0 > "$private/files"
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary")" in
    *Mach-O*) printf '%s\n' "${binary#"$app/Contents/MacOS/"}" ;;
  esac
done < "$private/files" | LC_ALL=C sort > "$private/macho"
[[ "$(cat "$private/macho")" == "$(printf '%s\n' agterm "${helpers[@]}" | LC_ALL=C sort)" ]] \
  || fail 'the bundle holds Mach-O files other than the app and its three helpers'
# helpers get no entitlements; the outer app is sealed last.
for helper in "${helpers[@]}"; do
  codesign --force --options runtime --timestamp --sign "$sign_id" "$app/Contents/MacOS/$helper"
done
codesign --force --options runtime --timestamp --entitlements agterm/agterm.entitlements --sign "$sign_id" "$app"
codesign --verify --deep --strict "$app"
codesign -dvv "$app" > "$private/signature" 2>&1
grep -q '^Authority=Developer ID Application:' "$private/signature" || fail 'app is not Developer ID Application signed'
for helper in "${helpers[@]}"; do
  codesign -d --entitlements - --xml "$app/Contents/MacOS/$helper" > "$private/entitlements.plist" 2> "$private/codesign.log"
  if [[ -s "$private/entitlements.plist" ]]; then
    plutil -convert json -o "$private/entitlements.json" "$private/entitlements.plist"
    jq -e 'length == 0' "$private/entitlements.json" > /dev/null || fail 'helper carries entitlements'
  fi
done

ditto -c -k --sequesterRsrc --keepParent "$app" "$private/app.zip"
notarize "$private/app.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl -a -vv --type execute "$app" > "$private/spctl.log" 2>&1 || fail 'Gatekeeper rejects the app'

mkdir "$private/staging"
ditto "$app" "$private/staging/agterm.app"
ln -s /Applications "$private/staging/Applications"
dmg="$PWD/build/agterm-$version-$arch.dmg"
mkdir -p build
hdiutil create -volname agterm -srcfolder "$private/staging" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$sign_id" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg" > "$private/spctl.log" 2>&1 || fail 'Gatekeeper rejects the DMG'

cd build
shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256"
printf 'signed and notarized: %s\n' "$(basename "$dmg")"
if [[ "$mode" == --publish ]]; then
  git fetch --quiet --no-tags "https://github.com/$repo.git" "refs/tags/$tag"
  [[ "$(git rev-parse 'FETCH_HEAD^{commit}')" == "$head" ]] || fail 'fork tag moved before publication'
  shasum -a 256 -c "$(basename "$dmg").sha256"
  printf 'Intel (x86_64), macOS 14 or later. Developer ID signed and Apple notarized.\n\nUpstream notes: https://github.com/umputun/agterm/releases/tag/%s\n\nSource commit: %s\nCI build: https://github.com/%s/actions/runs/%s\n' \
    "$upstream" "$head" "$repo" "$run" > "$private/notes.md"
  gh release create "$tag" --repo "$repo" --verify-tag --draft --target "$head" \
    --title "agterm v$version for Intel ($tag)" --notes-file "$private/notes.md"
  gh release upload "$tag" "$dmg" "$dmg.sha256" --repo "$repo"
  printf 'draft release uploaded; review it on GitHub before publishing\n'
fi
