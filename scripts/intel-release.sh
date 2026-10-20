#!/usr/bin/env bash
# usage: bash scripts/intel-release.sh X.Y.Z N [--publish|--dry-run]
set -euo pipefail
# a newer script can release an older tag: point AGTERM_RELEASE_ROOT at that tag's checkout.
cd "${AGTERM_RELEASE_ROOT:-$(dirname "$0")/..}"

fail() { printf '%s\n' "$*" >&2; exit 1; }
# 75 (EX_TEMPFAIL): Apple holds a submission; rerunning the same command resumes it.
pending() { printf '%s; rerun the same command later\n' "$*" >&2; exit 75; }

version=${1:-}
respin=${2:-}
mode=${3:-}
[[ $# -ge 2 && $# -le 3 && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$respin" =~ ^[1-9][0-9]*$ ]] \
  || fail 'usage: scripts/intel-release.sh X.Y.Z N [--publish|--dry-run]'
[[ -z "$mode" || "$mode" == --dry-run || "$mode" == --publish ]] || fail 'unknown release option'
tag="x86_64-v$version-r$respin"
upstream="v$version"
# a release cut before upstream tags its changes names its base tag here (INTEL.md, What the fork is).
[[ ! -f .github/intel-upstream ]] || upstream=$(< .github/intel-upstream)
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
# the signed app, the DMG's cdhash and pending submission ids survive a rerun here (build/ is ignored).
work="$PWD/build/$tag"
dmg_workflow=intel-dmg.yml
attest_workflow=intel-attest.yml
# gh before 2.67.0 exits 0 when no attestation is found.
gh_version=$(gh --version | sed -nE '1s/^gh version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[[ -n "$gh_version" && "$(printf '%s\n' 2.67.0 "$gh_version" | sort -V | head -n1)" == 2.67.0 ]] \
  || fail 'gh 2.67.0 or newer is required'

# policy flags validate certificate claims, not workflow-controlled predicate text.
verify_attestation() {
  gh attestation verify "$1" --repo "$repo" \
    --cert-identity "https://github.com/$repo/.github/workflows/$2@refs/tags/$tag" \
    --source-ref "refs/tags/$tag" --source-digest "$head" --signer-digest "$head" --deny-self-hosted-runners
}

verify_artifact() {
  local dest=$1 zip
  gh run list --repo "$repo" --workflow "$workflow" --branch "$tag" --commit "$head" --status success \
    --limit 100 --json databaseId,headSha,headBranch,status,conclusion > "$private/runs.json"
  run=$(jq -er --arg head "$head" --arg tag "$tag" '
    [.[] | select(.headSha == $head and .headBranch == $tag and .status == "completed" and .conclusion == "success")]
    | first.databaseId | select(type == "number")' "$private/runs.json")
  mkdir "$private/download"
  gh run download "$run" --repo "$repo" --name "$tag-unsigned" --dir "$private/download"
  zip="$private/download/agterm-$version-x86_64-unsigned.zip"
  [[ -f "$zip" ]] || fail 'expected unsigned zip is missing'
  verify_attestation "$zip" "$workflow"
  ditto -x -k "$zip" "$dest"
  app="$dest/agterm.app"
  arch=$(bash scripts/intel-verify-arch.sh "$app")
  codesign --verify --deep --strict "$app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == io.github.vshuraeff.agterm ]] \
    || fail 'built app has the wrong fork identity'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] \
    || fail 'built app version differs from the upstream tag'
}

if [[ "$mode" == --dry-run ]]; then
  verify_artifact "$private/extracted"
  printf 'CI run %s: provenance, bundle and architecture verified; stopped before credential access and signing\n' "$run"
  exit 0
fi

sign_id=${AGTERM_SIGN_IDENTITY:-}
notary_profile=${AGTERM_NOTARY_PROFILE:-agterm-notary}
notary_wait=${AGTERM_NOTARY_WAIT:-30m}
if [[ -z "$sign_id" ]]; then
  security find-identity -v -p codesigning > "$private/identities"
  sign_id=$(awk '/"Developer ID Application:/{print $2; exit}' "$private/identities")
fi
[[ -n "$sign_id" && "$sign_id" != - ]] || fail 'a Developer ID Application signing identity is required'

# a ticket Apple already issued for this cdhash is stapled without a new submission.
notarize() {
  local target=$1 upload=$2 record=$3 submission status diagnostics
  xcrun stapler staple "$target" > "$private/staple.log" 2>&1 && return 0
  # a non-empty response marks a submission that may be live, so it is never submitted again.
  if [[ ! -s "$record" ]]; then
    xcrun notarytool submit "$upload" --keychain-profile "$notary_profile" --output-format json > "$record" \
      || { rm -f "$record"; fail 'notarization submit failed'; }
  fi
  submission=$(jq -er '.id | select(type == "string" and length > 0)' "$record") \
    || fail "no submission id in $record; reconcile it with notarytool history"
  printf 'notarization submission %s\n' "$submission"
  xcrun notarytool wait "$submission" --keychain-profile "$notary_profile" --timeout "$notary_wait" \
    --output-format json > "$private/wait.json" || true
  xcrun notarytool info "$submission" --keychain-profile "$notary_profile" --output-format json > "$private/info.json"
  status=$(jq -er '.status | select(type == "string")' "$private/info.json")
  case "$status" in
    Accepted)
      if ! xcrun stapler staple "$target" > "$private/staple.log" 2>&1; then
        cat "$private/staple.log" >&2
        pending "submission $submission is accepted but stapling failed"
      fi ;;
    'In Progress') pending "submission $submission is still in progress" ;;
    *)
      # diagnostics stay private, outside uploaded release assets.
      if ! xcrun notarytool log "$submission" --keychain-profile "$notary_profile" > "$private/notary-rejection.json"; then
        printf 'notarization diagnostic retrieval failed\n' >&2
      else
        diagnostics=$(mktemp -d "${TMPDIR:-/tmp}/intel-notary-diagnostics.XXXXXX")
        chmod 700 "$diagnostics"
        cp "$private/notary-rejection.json" "$diagnostics/rejection.json"
        printf 'notarization diagnostics: %s/rejection.json\n' "$diagnostics" >&2
      fi
      fail "notarization rejected submission $submission ($status)" ;;
  esac
}

# sets release to missing, draft or published; a full listing, unlike a view, tells a missing release from a failed request.
read_release() {
  gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[] | {tag_name, draft}' > "$private/releases.json"
  release=missing
  if jq -e -s --arg tag "$tag" 'any(.[]; .tag_name == $tag)' "$private/releases.json" > /dev/null; then
    release=published
    if jq -e -s --arg tag "$tag" 'all(.[] | select(.tag_name == $tag); .draft)' "$private/releases.json" > /dev/null; then
      release=draft
    fi
  fi
}

if [[ ! -f "$work/signed" ]]; then
  if [[ "$mode" == --publish ]]; then
    read_release
    [[ "$release" != published ]] || fail "$tag is already published"
  fi
  rm -rf "$work"
  mkdir -p "$work"
  chmod 700 "$work"
  verify_artifact "$work"
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
  printf '%s\n' "$head" > "$work/head"
  printf '%s\n' "$arch" > "$work/arch"
  touch "$work/signed"
fi
# a resumed run trusts the app it signed after verify_artifact; the signed app cannot be re-checked against the zip.
[[ "$(< "$work/head")" == "$head" ]] || fail "$work belongs to another commit; remove it to start over"
arch=$(< "$work/arch")
app="$work/agterm.app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$private/app.zip"
notarize "$app" "$private/app.zip" "$work/app.submission.json"
xcrun stapler validate "$app"
spctl -a -vv --type execute "$app" > "$private/spctl.log" 2>&1 || fail 'Gatekeeper rejects the app'
if [[ "$mode" != --publish ]]; then
  printf 'signed and notarized: %s; --publish builds, attests and publishes the release\n' "$app"
  exit 0
fi

tag_unmoved() {
  git fetch --quiet --no-tags "https://github.com/$repo.git" "refs/tags/$tag"
  [[ "$(git rev-parse 'FETCH_HEAD^{commit}')" == "$head" ]] || fail 'fork tag moved since the release started'
}

# dispatches workflow $1 on the tag unless record $2 already names its run, waits up to 30 minutes and sets
# workflow_run; a failed run's record is removed, so the next rerun dispatches the workflow again.
run_workflow() {
  local workflow=$1 record=$2 since deadline
  if [[ ! -s "$record" ]]; then
    since=$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)
    gh workflow run "$workflow" --repo "$repo" --ref "$tag" -f tag="$tag"
    workflow_run=
    for _ in {1..24}; do
      sleep 5
      gh run list --repo "$repo" --workflow "$workflow" --event workflow_dispatch --branch "$tag" --commit "$head" \
        --limit 20 --json databaseId,createdAt > "$private/runs-list.json"
      workflow_run=$(jq -r --arg since "$since" \
        '[.[] | select(.createdAt >= $since)] | sort_by(.createdAt) | last.databaseId // empty' "$private/runs-list.json")
      [[ -n "$workflow_run" ]] && break
    done
    [[ -n "$workflow_run" ]] || fail "no $workflow run appeared for $tag; check Actions, then rerun"
    printf '%s\n' "$workflow_run" > "$record"
  fi
  workflow_run=$(< "$record")
  deadline=$((SECONDS + 1800))
  while :; do
    gh run view "$workflow_run" --repo "$repo" --json status,conclusion,headSha > "$private/run.json"
    [[ "$(jq -r .status "$private/run.json")" == completed ]] && break
    (( SECONDS < deadline )) || pending "$workflow run $workflow_run is still running"
    sleep 30
  done
  [[ "$(jq -r .headSha "$private/run.json")" == "$head" ]] || fail "$workflow run $workflow_run built another commit"
  if [[ "$(jq -r .conclusion "$private/run.json")" != success ]]; then
    rm -f "$record"
    fail "$workflow run $workflow_run did not succeed; rerun to dispatch it again"
  fi
}

app_asset="agterm-$version-$arch-app.zip"
# inside the tag's directory so a pending respin's DMG is never overwritten by another respin.
dmg="$work/agterm-$version-$arch.dmg"
dmg_name=$(basename "$dmg")
dmg_cdhash() { codesign -dvvv "$dmg" > "$private/dmg-signature" 2>&1; sed -n 's/^CDHash=//p' "$private/dmg-signature"; }
# UDZO output is not reproducible, so a DMG that may have been submitted is never replaced.
if [[ ! -s "$work/dmg.cdhash" ]]; then
  if [[ ! -s "$work/dmg.run" ]]; then
    tag_unmoved
    read_release
    [[ "$release" != published ]] || fail "$tag is already published"
    if [[ "$release" == missing ]]; then
      # intel-attest.yml writes the final notes in CI; these hold the draft until then.
      bash scripts/intel-release-notes.sh "$tag" > "$private/notes.md"
      gh release create "$tag" --repo "$repo" --verify-tag --draft --target "$head" \
        --title "agterm v$version x86_64" --notes-file "$private/notes.md"
    fi
    ditto -c -k --sequesterRsrc --keepParent "$app" "$private/$app_asset"
    gh release upload "$tag" "$private/$app_asset" --repo "$repo" --clobber
  fi
  run_workflow "$dmg_workflow" "$work/dmg.run"
  mkdir "$private/dmg-download"
  gh run download "$workflow_run" --repo "$repo" --name "$tag-dmg" --dir "$private/dmg-download"
  ci_dmg="$private/dmg-download/$dmg_name"
  [[ -f "$ci_dmg" ]] || fail 'expected CI DMG is missing'
  verify_attestation "$ci_dmg" "$dmg_workflow"
  bash scripts/check-dmg.sh "$ci_dmg" "$app" || fail 'the CI DMG fails check-dmg.sh against the signed app and the tag layout'
  cp "$ci_dmg" "$dmg"
  codesign --force --timestamp --sign "$sign_id" "$dmg"
  dmg_cdhash > "$work/dmg.cdhash"
fi
[[ -f "$dmg" && "$(dmg_cdhash)" == "$(< "$work/dmg.cdhash")" ]] \
  || fail "the DMG changed since it was signed; remove $work to start over"
notarize "$dmg" "$dmg" "$work/dmg.submission.json"
xcrun stapler validate "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg" > "$private/spctl.log" 2>&1 || fail 'Gatekeeper rejects the DMG'

cd "$work"
shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
printf 'signed and notarized: %s\n' "$dmg_name"
if [[ ! -f published ]]; then
  tag_unmoved
  shasum -a 256 -c "$dmg_name.sha256"
  # a resumed run skipped the first check, and the draft may have been published since.
  read_release
  # publishing marks an edit that GitHub may have applied before gh failed.
  if [[ "$release" != published || ! -f publishing ]]; then
    [[ "$release" == draft ]] || fail "$tag is $release, not a draft; nothing was uploaded"
    gh release upload "$tag" "$dmg_name" "$dmg_name.sha256" --repo "$repo" --clobber
    # attests the uploaded DMG itself and writes the release notes.
    run_workflow "$attest_workflow" attest.run
    verify_attestation "$dmg_name" "$attest_workflow"
    gh release view "$tag" --repo "$repo" --json assets > "$private/assets.json"
    if jq -e --arg name "$app_asset" 'any(.assets[]; .name == $name)' "$private/assets.json" > /dev/null; then
      gh release delete-asset "$tag" "$app_asset" --repo "$repo" --yes
    fi
    touch publishing
    gh release edit "$tag" --repo "$repo" --draft=false --latest
  fi
  touch published
fi
# what users download is checked once more, from the published release.
mkdir "$private/published"
gh release download "$tag" --repo "$repo" --dir "$private/published"
[[ "$(ls "$private/published")" == "$(printf '%s\n' "$dmg_name" "$dmg_name.sha256")" ]] \
  || fail 'the published release holds assets other than the DMG and its checksum'
(cd "$private/published" && shasum -a 256 -c "$dmg_name.sha256")
verify_attestation "$private/published/$dmg_name" "$attest_workflow"
xcrun stapler validate "$private/published/$dmg_name"
mv -f "$dmg_name" "$dmg_name.sha256" ..
cd ..
rm -rf "$work"
printf 'published: %s\n' "$(gh release view "$tag" --repo "$repo" --json url --jq .url)"
