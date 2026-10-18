#!/usr/bin/env bash
# usage: bash scripts/intel-refresh.sh BASE ONTO   rebase the stack BASE..HEAD onto ONTO
#        bash scripts/intel-refresh.sh --report    review the finished rebase
# Pushes nothing. Run it on a branch of its own created at the stack head (INTEL.md, Refresh).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "$*" >&2; exit 1; }
state="$(git rev-parse --git-path intel-refresh)"
rerere=(-c rerere.enabled=true -c rerere.autoupdate=false)

report() {
  [[ -f "$state" ]] || fail 'no refresh recorded; run intel-refresh.sh BASE ONTO first'
  local base head onto new
  read -r base head onto < "$state"
  [[ ! -d "$(git rev-parse --git-path rebase-merge)" ]] || fail 'rebase still in progress'
  local failed=0
  new=$(git rev-parse HEAD)
  printf '== range-diff\n'
  git range-diff "$base..$head" "$onto..$new"
  printf '== whitespace\n'
  # patch files carry blank context lines
  if git diff --check "$onto..$new" -- . ':!scripts/zmx-patches/*.patch'; then printf 'clean\n'; else failed=1; fi
  printf '== upstream ci.yml changes to port into intel-ci.yml\n'
  git --no-pager diff "$base" "$onto" -- .github/workflows/ci.yml
  printf '== ZMX_REV\n'
  git diff -U0 "$base" "$onto" -- scripts/setup.sh | grep -E '^[-+]ZMX_REV=' || printf 'unchanged\n'
  printf '== temporary commits (drop once upstream has the fix; INTEL.md lists the condition)\n'
  git log --reverse --format='%h %s' "$onto..$new" | grep -v -E '^[0-9a-f]+ [a-z]+\(intel\):' || printf 'none\n'
  printf '== audit\n'
  bash scripts/intel-audit.sh || failed=1
  return "$failed"
}

[[ "${1:-}" == --report && $# -eq 1 ]] && { report; exit; }
[[ $# -eq 2 ]] || fail 'usage: scripts/intel-refresh.sh BASE ONTO | --report'
upstream=${INTEL_UPSTREAM:-origin/master}
base=$(git rev-parse --verify "$1^{commit}")
onto=$(git rev-parse --verify "$2^{commit}")
head=$(git rev-parse HEAD)
[[ ! -d "$(git rev-parse --git-path rebase-merge)" ]] || fail 'a rebase is in progress; finish or abort it first'
git symbolic-ref -q HEAD > /dev/null || fail 'HEAD is detached; switch to a branch made for this refresh'
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail 'working tree must be clean'
[[ "$base" == "$(git merge-base "$head" "$upstream")" ]] \
  || fail "BASE is not where HEAD forks from $upstream (set INTEL_UPSTREAM to override)"
[[ -z "$(git rev-list --merges "$base..$head")" ]] || fail 'the stack contains merge commits'
count=$(git rev-list --count "$base..$head")
[[ "$(git rev-list --count "$base..$head" --not "$onto")" == "$count" ]] \
  || fail 'some commits in BASE..HEAD are already in ONTO; BASE is not the stack base'
printf '%s %s %s\n' "$base" "$head" "$onto" > "$state"
printf 'stack of %s commits, old head:\n%s\n' "$count" "$head"
git log --reverse --format='  %h %s' "$base..$head"
git "${rerere[@]}" rebase --onto "$onto" "$base" || fail "stopped on a conflict: resolve it, git add the paths,
git ${rerere[*]} rebase --continue, then bash scripts/intel-refresh.sh --report"
report
