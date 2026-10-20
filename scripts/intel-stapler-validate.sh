#!/usr/bin/env bash
# usage: scripts/intel-stapler-validate.sh <path>
# runs `xcrun stapler validate`, which asks Apple's CloudKit ticket service; retries only network failures.
set -euo pipefail
[[ $# -eq 1 && -e "$1" ]] || { printf 'usage: scripts/intel-stapler-validate.sh <path>\n' >&2; exit 2; }
target=$1
# INTEL_STAPLER_WAITS overrides the waits between the 5 attempts (tests only)
read -r -a waits <<< "${INTEL_STAPLER_WAITS:-10 20 40 60}"
attempts=$(( ${#waits[@]} + 1 ))
for ((attempt = 1; ; attempt++)); do
  status=0
  output=$(xcrun stapler validate "$target" 2>&1) || status=$?
  [[ $status -eq 0 ]] && exit 0
  printf '%s\n' "$output" >&2
  if [[ "$output" != *NSURLErrorDomain* && "$output" != *apple-cloudkit.com* && "$output" != *CloudKit* ]]; then
    printf 'stapler validate failed for %s (exit %d)\n' "$target" "$status" >&2
    exit "$status"
  fi
  if ((attempt == attempts)); then
    printf 'stapler validate failed for %s after %d attempts (exit %d)\n' "$target" "$attempts" "$status" >&2
    exit "$status"
  fi
  wait=${waits[attempt - 1]}
  printf 'attempt %d/%d failed (network), retrying in %ss\n' "$attempt" "$attempts" "$wait" >&2
  sleep "$wait"
done
