#!/usr/bin/env bash
#
# build-deb.sh — cartograph .deb, self-contained (no fpm, no debhelper).
#
#   packaging/build-deb.sh          → packaging/dist/cartograph_<version>_<arch>.deb
#
# Depends are the direct links of the shipped binaries (surveyed with ldd and
# mapped with dpkg -S); niceties ride Recommends. Payload comes from stage.sh,
# shared with build-rpm.sh so the two packages carry identical bytes.

set -euo pipefail
source "$(dirname "$0")/stage.sh"

command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found" >&2; exit 1; }
command -v scdoc >/dev/null || { echo "scdoc not found (sudo apt install scdoc)" >&2; exit 1; }

ARCH="$(dpkg --print-architecture)"
OUT_DIR="$PROJECT_DIR/packaging/dist"
OUT="$OUT_DIR/cartograph_${VERSION}_${ARCH}.deb"
mkdir -p "$OUT_DIR"

build_release

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

stage_tree "$STAGING"
install -d "$STAGING/DEBIAN"

INSTALLED_SIZE="$(du -sk "$STAGING/usr" | cut -f1)"

cat > "$STAGING/DEBIAN/control" <<EOF
Package: cartograph
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Depends: libc6, libbpf1, libelf1t64 | libelf1, zlib1g, libzstd1, libgtk-4-1, libglib2.0-0t64 | libglib2.0-0
Recommends: curl
Maintainer: Ben <2bmillerb@gmail.com>
Homepage: https://github.com/RamenFast/cartograph
Description: living map of your machine's network, from orbit to the byte
 Cartograph shows, live and by real name, every process on this machine and
 who it is talking to — process attribution, offline GeoIP/ASN identity,
 rDNS/passive-DNS hostnames, throughput, RTT, exposure badges — and a "Why"
 panel that narrates any flow in plain language.
 .
 Ships three faces over one view-model: surveyor (the capture core: one-shot
 tables, NDJSON streams for agents, or a Unix-socket daemon), cartograph (the
 TUI), and cartograph-gtk (the GTK4 window). The optional eBPF source catches
 short-lived flows and UDP/QUIC bytes; enable it per the README (setcap).
EOF

# postinst: one gentle, actionable note — no silent capability grants. The
# unprivileged path is the default; eBPF is an explicit opt-in the user makes.
cat > "$STAGING/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    echo "cartograph: unprivileged capture works out of the box (surveyor snapshot)."
    echo "  optional eBPF source (short-lived flows, UDP/QUIC bytes):"
    echo "    sudo setcap cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep /usr/bin/surveyor"
    echo "  optional GeoIP identity (who owns each remote):  cartograph-fetch-geoip"
fi
exit 0
EOF
chmod 755 "$STAGING/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$STAGING" "$OUT" >/dev/null
echo
dpkg-deb --info "$OUT"
echo
echo "✓ $OUT"
