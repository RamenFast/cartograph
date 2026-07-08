#!/usr/bin/env bash
#
# build-source.sh — source tarball from the *committed tree* (git archive), so a
# tarball with stray files is impossible by construction.
#
#   packaging/build-source.sh [ref]     → packaging/dist/cartograph-<version>-source.tar.gz
#
# Default ref is HEAD; pass the release tag when cutting a release.

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep -oP '\.version = "\K[^"]+' "$PROJECT_DIR/build.zig.zon")"
REF="${1:-HEAD}"
OUT_DIR="$PROJECT_DIR/packaging/dist"
mkdir -p "$OUT_DIR"

git -C "$PROJECT_DIR" archive --format=tar.gz \
    --prefix="cartograph-${VERSION}/" \
    -o "$OUT_DIR/cartograph-${VERSION}-source.tar.gz" "$REF"

ls -la "$OUT_DIR/cartograph-${VERSION}-source.tar.gz"
echo "✓ source tarball from $REF"
