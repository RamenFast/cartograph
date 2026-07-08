#!/usr/bin/env bash
#
# build-rpm.sh — cartograph .rpm via rpmbuild with a generated spec.
#
#   packaging/build-rpm.sh          → packaging/dist/cartograph-<version>-1.<arch>.rpm
#
# The payload is the same stage.sh tree the deb uses (identical bytes law).
# Shared-library Requires are auto-detected by rpm from the ELF headers.
# Built and `rpm --test`-verified on Mint; reports from RPM distros welcome.

set -euo pipefail
source "$(dirname "$0")/stage.sh"

command -v rpmbuild >/dev/null || { echo "rpmbuild not found (sudo apt install rpm)" >&2; exit 1; }
command -v scdoc >/dev/null || { echo "scdoc not found (sudo apt install scdoc)" >&2; exit 1; }

ARCH="$(uname -m)"
OUT_DIR="$PROJECT_DIR/packaging/dist"
mkdir -p "$OUT_DIR"

build_release

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE" "$WORK/rpm"
stage_tree "$STAGE"

cat > "$WORK/cartograph.spec" <<EOF
Name:           cartograph
Version:        $VERSION
Release:        1
Summary:        Living map of your machine's network, from orbit to the byte
License:        GPL-3.0-or-later
URL:            https://github.com/RamenFast/cartograph
Recommends:     curl

%define debug_package %{nil}
%define __os_install_post %{nil}

%description
Cartograph shows, live and by real name, every process on this machine and
who it is talking to — process attribution, offline GeoIP/ASN identity,
rDNS/passive-DNS hostnames, throughput, RTT, exposure badges — and a "Why"
panel that narrates any flow in plain language.

Ships three faces over one view-model: surveyor (the capture core: one-shot
tables, NDJSON streams for agents, or a Unix-socket daemon), cartograph (the
TUI), and cartograph-gtk (the GTK4 window). The optional eBPF source catches
short-lived flows and UDP/QUIC bytes; enable it per the README (setcap).

%install
cp -a $STAGE/. %{buildroot}/

%post
echo "cartograph: unprivileged capture works out of the box (surveyor snapshot)."
echo "  optional eBPF source:  sudo setcap cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep /usr/bin/surveyor"
echo "  optional GeoIP identity:  cartograph-fetch-geoip"

%files
/usr/bin/surveyor
/usr/bin/cartograph
/usr/bin/cartograph-gtk
/usr/bin/cartograph-fetch-geoip
/usr/share/applications/cartograph.desktop
/usr/share/icons/hicolor/scalable/apps/cartograph.svg
/usr/share/icons/hicolor/16x16/apps/cartograph.png
/usr/share/icons/hicolor/32x32/apps/cartograph.png
/usr/share/icons/hicolor/48x48/apps/cartograph.png
/usr/share/icons/hicolor/64x64/apps/cartograph.png
/usr/share/icons/hicolor/128x128/apps/cartograph.png
/usr/share/icons/hicolor/256x256/apps/cartograph.png
%doc /usr/share/doc/cartograph/README.md
%license /usr/share/doc/cartograph/copyright
%{_mandir}/man1/cartograph.1.gz
%{_mandir}/man1/surveyor.1.gz
EOF

rpmbuild -bb "$WORK/cartograph.spec" \
    --define "_topdir $WORK/rpm" \
    --define "_rpmdir $OUT_DIR" \
    --define "_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
    >/dev/null 2>"$WORK/rpmbuild.log" || { cat "$WORK/rpmbuild.log" >&2; exit 1; }

OUT="$OUT_DIR/cartograph-${VERSION}-1.${ARCH}.rpm"
echo
rpm -qpi "$OUT"
echo
rpm -qpl "$OUT" | head -20
echo
echo "— auto-detected Requires (rpm reads the ELF headers):"
rpm -qp --requires "$OUT" 2>/dev/null | sed 's/^/    /'
echo "✓ $OUT"
