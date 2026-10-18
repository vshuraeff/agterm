#!/usr/bin/env bash
# Print an official ziglang.org x86_64-macos zig for one of setup.sh's zig formulas, downloading and
# checking it once: Homebrew ships no Intel macOS bottle for zig or its LLVM, so brew builds them for hours.
# usage: intel-zig.sh GHOSTTY|ZMX   (export the result as GHOSTTY_ZIG / ZMX_ZIG for setup.sh)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  GHOSTTY | ZMX) ;;
  *) echo "usage: $0 GHOSTTY|ZMX" >&2; exit 2 ;;
esac
setup="$root/scripts/setup.sh"
formula="$(sed -nE "s/^$1_ZIG_FORMULA=\"([^\"]+)\".*/\1/p" "$setup")"
# release tags before ghostty 1.4.0 name one ZIG_FORMULA for both builds
[[ -n "$formula" ]] || formula="$(sed -nE 's/^ZIG_FORMULA="([^"]+)".*/\1/p' "$setup")"
case "${formula#zig@}" in
  0.16) version=0.16.0 sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
  0.17) version=0.17.1 sha=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7 ;;
  *) echo "error: no pinned zig for '$formula'; add one from https://ziglang.org/download/index.json" >&2; exit 1 ;;
esac
name="zig-x86_64-macos-$version"
dir="${XDG_CACHE_HOME:-$HOME/.cache}/agterm-intel/$name"
if [[ ! -x "$dir/zig" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/$name.tar.xz" "https://ziglang.org/download/$version/$name.tar.xz"
  echo "$sha  $tmp/$name.tar.xz" | shasum -a 256 -c - >&2
  tar -xJf "$tmp/$name.tar.xz" -C "$tmp"
  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir"
  mv "$tmp/$name" "$dir"
fi
printf '%s\n' "$dir/zig"
