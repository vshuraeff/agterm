#!/usr/bin/env bash
# Intel release gates (INTEL.md, Gates).
# usage: intel-gates.sh [PHASE...]   phases: lint prep core app release closures, default all in that order
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
all=(lint prep core app release closures)
phases=("$@")
[[ ${#phases[@]} -gt 0 ]] || phases=("${all[@]}")
for p in "${phases[@]}"; do
  [[ " ${all[*]} " == *" $p "* ]] || { echo "unknown phase: $p (one of: ${all[*]})" >&2; exit 2; }
done

out="$root/build/intel-gates/$(date +%Y%m%d-%H%M%S)"
cache="${AGTERM_INTEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agterm-intel}/artifacts"
mkdir -p "$out"
summary="$out/summary.txt"
scratch="$(mktemp -d /tmp/agig.XXXX)"
trap 'rm -rf "$scratch"' EXIT
{
  echo "head $(git rev-parse HEAD)"
  echo "phases ${phases[*]}"
  dirty="$(git status --porcelain | cut -c4- | tr '\n' ' ')"
  [[ -z "$dirty" ]] && echo "tree clean" || echo "tree dirty: $dirty"
} > "$summary"

GHOSTTY_ZIG="$(bash scripts/intel-zig.sh GHOSTTY)" || exit 1
ZMX_ZIG="$(bash scripts/intel-zig.sh ZMX)" || exit 1
export GHOSTTY_ZIG ZMX_ZIG

ghostty_set=(GhosttyKit.xcframework agterm/Resources/ghostty agterm/Resources/terminfo .ghostty-build-stamp)
zmx_set=(agterm/Resources/zmx .zmx-build-stamp)

# clones the newest cached set built from the pinned revision into a checkout that has no stamp of its own
restore_set() {
  local name="$1" rev="$2"; shift 2
  local stamp="${*: -1}" entry
  [[ -e "$stamp" ]] && return 0
  [[ -d "$cache/$name" ]] || return 0
  while read -r entry; do
    [[ "$(cat "$cache/$name/$entry/$stamp" 2>/dev/null)" == "$rev "* ]] || continue
    # the stamp goes last, so a failed copy leaves setup.sh nothing that claims the set is current
    for path in "$@"; do
      if ! { rm -rf "$path" && mkdir -p "$(dirname "$path")" && cp -Rc "$cache/$name/$entry/$path" "$path"; }; then
        rm -rf "$@"
        echo "restoring $name from $entry failed" >&2
        return 1
      fi
    done
    echo "restored $name from $entry"
    return 0
  done < <(ls -t "$cache/$name")
}

# keeps the set setup.sh just staged under its stamp, and the three newest sets per name
save_set() {
  local name="$1"; shift
  local stamp="${*: -1}" key tmp path
  [[ -f "$stamp" && ! -L "$stamp" ]] || return 0
  key="$(shasum -a 256 "$stamp" | cut -c1-16)"
  if [[ ! -d "$cache/$name/$key" ]]; then
    tmp="$cache/$name/.tmp-$$"
    rm -rf "$tmp"
    for path in "$@"; do
      mkdir -p "$tmp/$(dirname "$path")"
      cp -Rc "$path" "$tmp/$path" || { rm -rf "$tmp"; return 1; }
    done
    mv "$tmp" "$cache/$name/$key"
    echo "saved $name as $key"
  fi
  touch "$cache/$name/$key"
  ls -t "$cache/$name" | tail -n +4 | while read -r old; do rm -rf "${cache:?}/$name/$old"; done
}

pinned() { sed -nE "s/^$1=\"([^\"]+)\".*/\1/p" scripts/setup.sh; }

phase_lint() { make lint; }

phase_prep() {
  mkdir -p "$cache/ghostty" "$cache/zmx"
  restore_set ghostty "$(pinned GHOSTTY_REV)" "${ghostty_set[@]}" || return 1
  restore_set zmx "$(pinned ZMX_REV)" "${zmx_set[@]}" || return 1
  make prep || return 1
  [[ "$(lipo -archs agterm/Resources/zmx/zmx)" == x86_64 ]] || { echo "zmx is not x86_64" >&2; return 1; }
  # a failed save costs the next checkout a rebuild, not this run its result
  save_set ghostty "${ghostty_set[@]}" || echo "cache save failed: ghostty" >> "$summary"
  save_set zmx "${zmx_set[@]}" || echo "cache save failed: zmx" >> "$summary"
}

# an empty config home keeps the fish cases off the user's config.fish and its PATH to the live agtermctl;
# the short state dir keeps socket paths under the AF_UNIX limit
core_env() {
  mkdir -p "$scratch/config"
  env XDG_CONFIG_HOME="$scratch/config" AGTERM_STATE_DIR="$scratch/state" \
    AGTERM_REQUIRE_ZMX=1 AGTERM_REQUIRE_FISH=1 "$@"
}

# about 20 minutes: a syspolicyd restart can leave an exec asleep for good
core_test() {
  (cd agtermCore && core_env WATCHDOG_SECONDS="$1" DIAG_DIR="$out/$2" ../scripts/watchdog.sh swift test "${@:3}")
}

phase_core() {
  local rc suite i
  core_test 1500 core-hang && return 0
  rc=1
  # --filter matches a type name; a suite shown by its display name cannot be selected that way
  sed -nE 's/.*✘ Suite "([^"]+)" failed.*/\1/p' "$out/core.log" | sort -u | while read -r suite; do
    echo "isolated rerun skipped for display-named suite \"$suite\"" >> "$summary"
  done
  for suite in $(sed -nE 's/.*✘ Suite ([A-Za-z0-9_]+) failed.*/\1/p' "$out/core.log" | sort -u); do
    for i in 1 2 3; do
      if core_test 600 "core-hang-$suite-$i" --skip-build --filter "$suite" > "$out/core-$suite-$i.log" 2>&1; then
        echo "isolated $suite run $i passed" >> "$summary"
      else
        echo "isolated $suite run $i failed" >> "$summary"
      fi
    done
  done
  return "$rc"
}

phase_app() {
  local rc=0 test i restarts
  make test-app || rc=1
  restarts=$(grep -c "Restarting after unexpected exit" "$out/app.log")
  [[ "$restarts" == 0 ]] || { echo "$restarts restarts after an unexpected exit" >> "$summary"; rc=1; }
  [[ $rc == 0 ]] && return 0
  for test in $(sed -nE "s/.*Test Case '-\[agtermTests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' failed.*/\1\/\2/p" "$out/app.log" | sort -u); do
    for i in 1 2 3; do
      if xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS' \
        -derivedDataPath build/DerivedData "-only-testing:agtermTests/$test" > "$out/app-${test//\//-}-$i.log" 2>&1; then
        echo "isolated $test run $i passed" >> "$summary"
      else
        echo "isolated $test run $i failed" >> "$summary"
      fi
    done
  done
  return "$rc"
}

phase_release() {
  scripts/build.sh && bash scripts/intel-verify-arch.sh build/DerivedData/Build/Products/Release/agterm.app
}

phase_closures() { bash scripts/intel-verify-closures.sh build/DerivedData/Build/Products; }

failed=0
for p in "${phases[@]}"; do
  start=$(date +%s)
  echo "start $p $(date +%H:%M:%S)" >> "$summary"
  ( "phase_$p" ) > "$out/$p.log" 2>&1
  rc=$?
  echo "end $p rc=$rc $(( $(date +%s) - start ))s" >> "$summary"
  [[ $rc == 0 ]] || failed=1
done
echo "done failed=$failed" >> "$summary"
cat "$summary"
echo "$summary"
exit $failed
