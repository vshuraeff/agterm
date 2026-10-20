#!/usr/bin/env bash
# usage: scripts/intel-release-notes.sh x86_64-vX.Y.Z-rN   prints the release notes for that tag's commit
# the base tag's CHANGELOG.md section, cherry-picked upstream commits grouped the way upstream groups its
# changelog, and the fork's footer; INTEL.md (Release notes) owns the rules. Needs gh and network access.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "$*" >&2; exit 1; }
tag=${1:-}
[[ $# -eq 1 && "$tag" =~ ^x86_64-v([0-9]+\.[0-9]+\.[0-9]+)-r[1-9][0-9]*$ ]] \
  || fail 'usage: scripts/intel-release-notes.sh x86_64-vX.Y.Z-rN'
version=${BASH_REMATCH[1]}
repo=${GITHUB_REPOSITORY:-vshuraeff/agterm}
up=umputun/agterm
head=$(git rev-parse "refs/tags/$tag^{commit}")
upstream=$(git show "$head:.github/intel-upstream" 2> /dev/null) || upstream="v$version"
git fetch --quiet --no-tags "https://github.com/$up.git" "refs/tags/$upstream"
base=$(git rev-parse 'FETCH_HEAD^{commit}')
git merge-base --is-ancestor "$base" "$head" || fail "$tag does not descend from $upstream"

# references point at upstream, and authors become links so the notes notify nobody.
links() {
  sed -E \
    -e "s,(^|[[:space:](])#([0-9]+),\1[#\2](https://github.com/$up/issues/\2),g" \
    -e "s,(^|[[:space:](])@([[:alnum:]-]+),\1[\2](https://github.com/\2),g" \
    -e "s,(^|[[:space:]])([0-9a-f]{8})([[:space:].,;)]|$),\1[\2](https://github.com/$up/commit/\2)\3,g"
}

below() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | sed -n 1p)" == "${1#v}" ]]; }

# every upstream version released since the base of the fork's previous published release, so a skipped upstream
# release keeps its notes; with no earlier release, the base tag's section alone, as scripts/release.sh cuts it.
releases=$(gh release list --repo "$repo" --exclude-drafts --limit 100 --json tagName --jq '.[].tagName')
prev_tag= prev_version=
while read -r v t; do
  if below "$v" "$version" && { [[ -z "$prev_version" ]] || below "$prev_version" "$v"; }; then
    prev_tag=$t prev_version=$v
  fi
done < <(sed -nE 's/^((x86_64|intel)-v([0-9]+\.[0-9]+\.[0-9]+)-r[1-9][0-9]*)$/\3 \1/p' <<< "$releases")
log=$(git show "$base:CHANGELOG.md")
sections=$upstream
if [[ -n "$prev_tag" ]]; then
  prev_up=$(gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/.github/intel-upstream?ref=$prev_tag" \
    2> /dev/null) || prev_up=v$prev_version
  sections=$(sed -nE 's/^## (v[0-9]+\.[0-9]+\.[0-9]+)( .*)?$/\1/p' <<< "$log" | while read -r v; do
    if { [[ "$v" == "$upstream" ]] || below "$v" "$upstream"; } && below "$prev_up" "$v"; then echo "$v"; fi
  done)
fi
grep -qx "$upstream" <<< "$sections" || fail "CHANGELOG.md at $upstream has no $upstream section"
many=0
[[ "$sections" != "$upstream" ]] && many=1
changelog=$(awk -v keep=" ${sections//$'\n'/ } " -v many="$many" '
  /^## / {grab = index(keep, " " $2 " ") > 0; if (grab && many) print; next}
  grab {print}' <<< "$log")
[[ -n "$changelog" ]] || fail "CHANGELOG.md at $upstream has no $upstream section"

# one entry per pull request, grouped by the first commit's type; refactor, test, ci, chore and
# docs(backlog) commits are left out, as upstream leaves them out.
backports=$(mktemp -d)
trap 'rm -rf "$backports"' EXIT
git log --reverse --format=%H --grep='^(cherry picked from commit ' "$base..$head" > "$backports/commits"
while read -r commit; do
  source=$(git log -1 --format=%b "$commit" | sed -nE 's/^\(cherry picked from commit ([0-9a-f]{40})\)$/\1/p' | tail -n1)
  subject=$(git log -1 --format=%s "$commit")
  type=$(sed -nE 's/^([a-z]+)(\(([a-z-]+)\))?!?: .*/\1 \3/p' <<< "$subject")
  case "$type" in
    'feat '*) group=features ;;
    'fix '*) group=fixes ;;
    'docs backlog') continue ;;
    'docs '* | '') group=improved ;;
    *) continue ;;
  esac
  pr=$(gh api "repos/$up/commits/$source/pulls" --jq '.[0] | select(.) | "\(.number) \(.user.login)"')
  if [[ -n "$pr" ]]; then
    ref="#${pr%% *} @${pr#* }"
    key=pr-${pr%% *}
  else
    ref="${source:0:8} @$(gh api "repos/$up/commits/$source" --jq '.author.login')"
    key=$source
  fi
  [[ ! -e "$backports/$key" ]] || continue
  touch "$backports/$key"
  text=$(sed -E -e 's/^[a-z]+(\([a-z-]+\))?!?: //' -e 's/ \(#[0-9]+\)$//' <<< "$subject")
  printf -- '- %s %s\n' "$text" "$ref" >> "$backports/$group"
done < "$backports/commits"

{
  if [[ -s "$backports/features" || -s "$backports/improved" || -s "$backports/fixes" ]]; then
    printf "agterm %s for Intel is upstream %s plus the changes from upstream \`master\` below, which no upstream release carries yet.\n\n" \
      "$version" "$upstream"
    printf '## From upstream master\n'
    for group in features:'New Features' improved:Improved fixes:'Bug Fixes'; do
      [[ -s "$backports/${group%%:*}" ]] || continue
      printf '\n### %s\n\n' "${group#*:}"
      cat "$backports/${group%%:*}"
    done
    # several sections carry their own version headings.
    [[ $many == 1 ]] && printf '\n' || printf '\n## Upstream %s\n' "$upstream"
  fi
  printf '%s\n' "$changelog"
} | links

build_run=$(gh run list --repo "$repo" --workflow intel-build.yml --branch "$tag" --commit "$head" --status success \
  --limit 1 --json databaseId --jq '.[0].databaseId // empty')
dmg_run=$(gh run list --repo "$repo" --workflow intel-dmg.yml --branch "$tag" --commit "$head" --status success \
  --limit 1 --json databaseId --jq '.[0].databaseId // empty')
dmg="agterm-$version-x86_64.dmg"
cat <<EOF

---

Intel (x86_64) build from an independent fork, macOS 14 or later; the agterm author neither builds nor supports it.
Signed with a Developer ID certificate and notarized by Apple, so macOS Gatekeeper opens it with no extra steps.

- **Direct download:** open the \`.dmg\` and drag \`agterm.app\` into \`/Applications\`.
- **Verify:** \`gh attestation verify $dmg --repo $repo\` checks where the DMG was built,
  \`shasum -a 256 -c $dmg.sha256\` its checksum.
- **Source:** [\`${head:0:8}\`](https://github.com/$repo/commit/$head)${build_run:+, app built by [this run](https://github.com/$repo/actions/runs/$build_run)}${dmg_run:+, DMG by [this run](https://github.com/$repo/actions/runs/$dmg_run)}${GITHUB_RUN_ID:+, attested by [this run](https://github.com/$repo/actions/runs/$GITHUB_RUN_ID)}.
EOF
