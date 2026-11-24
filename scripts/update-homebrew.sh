#!/bin/sh
# Point Formula/clrc.rb and Casks/clrc.rb at a released version.
# Usage: scripts/update-homebrew.sh <version> <darwin-arm64 sha256> <darwin-amd64 sha256>
# Version may be given with or without the leading "v". Works with BSD (macOS) and GNU sed.
set -eu

die() { echo "update-homebrew: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <version> <arm64-sha256> <amd64-sha256>"
VER="${1#v}"
ARM64_SHA="$2"
AMD64_SHA="$3"

echo "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "bad version: $1"
for sha in "$ARM64_SHA" "$AMD64_SHA"; do
  echo "$sha" | grep -Eq '^[0-9a-f]{64}$' || die "bad sha256: $sha"
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA="$ROOT/Formula/clrc.rb"
CASK="$ROOT/Casks/clrc.rb"

# Formula: the sha256 line right after each arch's url line.
sed -i.bak \
  -e "s|version \"[^\"]*\"|version \"${VER}\"|" \
  -e "/url .*clrc-darwin-arm64/{n;s|sha256 \"[^\"]*\"|sha256 \"${ARM64_SHA}\"|;}" \
  -e "/url .*clrc-darwin-amd64/{n;s|sha256 \"[^\"]*\"|sha256 \"${AMD64_SHA}\"|;}" \
  "$FORMULA"

# Cask: only the two-line `sha256 arm: ..., intel: ...` block — the `arch arm:/intel:`
# line above it must stay untouched.
sed -i.bak \
  -e "s|version \"[^\"]*\"|version \"${VER}\"|" \
  -e "/sha256 arm:/{s|arm: *\"[^\"]*\"|arm:   \"${ARM64_SHA}\"|;n;s|intel: *\"[^\"]*\"|intel: \"${AMD64_SHA}\"|;}" \
  "$CASK"

rm -f "$FORMULA.bak" "$CASK.bak"

# Fail loudly if a pattern stopped matching (e.g. the files were reformatted).
for f in "$FORMULA" "$CASK"; do
  grep -q "version \"${VER}\"" "$f" || die "version not updated in $f"
  grep -q "$ARM64_SHA" "$f" || die "arm64 sha256 not updated in $f"
  grep -q "$AMD64_SHA" "$f" || die "amd64 sha256 not updated in $f"
done
grep -q 'arch arm: "arm64", intel: "amd64"' "$CASK" || die "cask arch line was modified"

echo "Homebrew formula and cask now point at v${VER}"
