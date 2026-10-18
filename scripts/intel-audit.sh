#!/usr/bin/env bash
# usage: bash scripts/intel-audit.sh
# fails on app sources that need the plain-deinit or worker-thread treatment (INTEL.md, The Intel stack)
set -euo pipefail
cd "$(dirname "$0")/.."

# retain newlines for diagnostics while matching across them; this conservative scan can also flag strings
# and return-type signatures. whole-line // comments are ignored, not arbitrary Swift syntax.
# shellcheck disable=SC2016 # awk, not the shell, expands $0
git ls-files -z -- ':(glob)agterm/**/*.swift' ':(glob)agtermTests/**/*.swift' | xargs -0 awk '
function find_sites(pattern, reason, rest, offset, start, prefix, line) {
  rest = text
  offset = 0
  while (match(rest, pattern)) {
    start = offset + RSTART
    if (substr(rest, RSTART, 1) !~ /[[:alnum:]_]/) start++
    prefix = substr(text, 1, start - 1)
    line = 1 + gsub(/\n/, "", prefix)
    printf "%s:%d: %s\n", path, line, reason
    found = 1
    offset += RSTART + RLENGTH - 1
    rest = substr(rest, RSTART + RLENGTH)
  }
}
function scan() {
  find_sites("(^|[^[:alnum:]_])isolated[[:space:]]+deinit([^[:alnum:]_]|$)", "isolated deinit needs plain deinit")
  if (path != "agterm/Control/WorkerThread.swift")
    find_sites("(^|[^[:alnum:]_])Thread[[:space:]]*([({]|[.][[:space:]]*(detachNewThread|init[[:space:]]*[(]))", "thread start outside WorkerThread.swift")
}
FNR == 1 { scan(); text = ""; path = FILENAME }
{ text = text ($0 ~ /^[[:space:]]*\/\// ? "" : $0) "\n" }
END { scan(); exit found ? 1 : 0 }
'
printf 'intel audit: clean\n'
