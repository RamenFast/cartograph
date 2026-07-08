#!/usr/bin/env bash
#
# stage.sh — build release binaries and lay out the shared install tree.
#
# Sourced by build-deb.sh and build-rpm.sh so the two payloads are identical
# by construction (the packaging law: deb and rpm carry the same bytes).
#
# Provides:
#   PROJECT_DIR, VERSION, ZIG
#   build_release            — zig build (bpf+gtk, ReleaseSafe) + version gate
#   stage_tree <destdir>     — install the full FHS tree under <destdir>/usr

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The one version: build.zig.zon is the source of truth (build.zig injects the
# same string into --version, so the gate below can't pass on a stale binary).
VERSION="$(grep -oP '\.version = "\K[^"]+' "$PROJECT_DIR/build.zig.zon")"
[ -n "$VERSION" ] || { echo "could not read version from build.zig.zon" >&2; exit 1; }

# Vendored toolchain first (the repo pin), PATH zig second.
if [ -x "$PROJECT_DIR/toolchain/zig" ]; then
    ZIG="$PROJECT_DIR/toolchain/zig"
elif command -v zig >/dev/null; then
    ZIG="$(command -v zig)"
else
    echo "no zig found — vendor one at toolchain/zig (0.16) or install zig" >&2
    exit 1
fi

build_release() {
    echo "→ zig build (ReleaseSafe, -Dbpf -Dgtk) with $ZIG"
    (cd "$PROJECT_DIR" && "$ZIG" build -Dbpf=true -Dgtk=true -Doptimize=ReleaseSafe)

    # The agent-and-human-proof gate: the binary must answer with the manifest
    # version, or the package would lie about its contents.
    local got
    got="$("$PROJECT_DIR/zig-out/bin/surveyor" --version)"
    [ "$got" = "surveyor $VERSION" ] || {
        echo "version gate failed: binary says '$got', manifest says '$VERSION'" >&2
        exit 1
    }
    echo "✓ version gate: $got"
}

stage_tree() {
    local dest="$1"
    local bin="$dest/usr/bin"
    local icons="$dest/usr/share/icons/hicolor"

    install -d "$bin" \
        "$dest/usr/share/applications" \
        "$icons/scalable/apps" \
        "$dest/usr/share/man/man1" \
        "$dest/usr/share/doc/cartograph"

    # binaries, stripped (ReleaseSafe keeps its safety checks; symbols go)
    for exe in surveyor cartograph cartograph-gtk; do
        install -m755 "$PROJECT_DIR/zig-out/bin/$exe" "$bin/$exe"
        strip --strip-unneeded "$bin/$exe"
    done

    # the GeoIP fetcher ships as a first-class command (surveyor's degrade
    # note names it, so the fix it prescribes must exist on PATH)
    install -m755 "$PROJECT_DIR/scripts/fetch-geoip.sh" "$bin/cartograph-fetch-geoip"

    # desktop entry + icons
    install -m644 "$PROJECT_DIR/packaging/cartograph.desktop" "$dest/usr/share/applications/cartograph.desktop"
    install -m644 "$PROJECT_DIR/assets/icon/cartograph.svg" "$icons/scalable/apps/cartograph.svg"
    for s in 16 32 48 64 128 256; do
        install -d "$icons/${s}x${s}/apps"
        install -m644 "$PROJECT_DIR/assets/icon/cartograph-${s}.png" "$icons/${s}x${s}/apps/cartograph.png"
    done

    # man pages (scdoc → gz, reproducible timestamps)
    for page in cartograph surveyor; do
        scdoc < "$PROJECT_DIR/man/${page}.1.scd" | gzip -9n > "$dest/usr/share/man/man1/${page}.1.gz"
    done

    # license + readme
    install -m644 "$PROJECT_DIR/LICENSE" "$dest/usr/share/doc/cartograph/copyright"
    install -m644 "$PROJECT_DIR/README.md" "$dest/usr/share/doc/cartograph/README.md"
}
