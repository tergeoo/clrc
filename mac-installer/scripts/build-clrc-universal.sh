#!/bin/sh
# Build universal (arm64 + x86_64) `clrc` and `claude-relay` binaries and drop
# them into the installer app's Resources so the .app can bundle them.
#
# Usage: sh mac-installer/scripts/build-clrc-universal.sh [VERSION]
#   VERSION (optional) is stamped into main.version (e.g. v1.3.0).
#
# The resulting binaries are git-ignored (see Resources/.gitignore) — they are
# build products, regenerated on demand, never committed.
set -e

VERSION="${1:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/mac-installer/Clrc/Clrc/Resources"
LDFLAGS="-s -w -X main.version=$VERSION"

mkdir -p "$OUT"

build() { # $1 = module dir (relative to ROOT), $2 = output binary name
  moddir="$ROOT/$1"
  name="$2"
  echo "building universal $name from $1 ..."
  ( cd "$moddir" && CGO_ENABLED=0 GOARCH=arm64 go build -ldflags="$LDFLAGS" -o "/tmp/$name-arm64" ./cmd/ )
  ( cd "$moddir" && CGO_ENABLED=0 GOARCH=amd64 go build -ldflags="$LDFLAGS" -o "/tmp/$name-amd64" ./cmd/ )
  lipo -create -output "$OUT/$name" "/tmp/$name-arm64" "/tmp/$name-amd64"
  chmod 755 "$OUT/$name"
  rm -f "/tmp/$name-arm64" "/tmp/$name-amd64"
}

build agent clrc
build relay claude-relay

echo
echo "wrote universal binaries to $OUT:"
for b in clrc claude-relay; do
  printf "  %s: " "$b"
  lipo -info "$OUT/$b" | sed 's/.*: //'
done
