#!/usr/bin/env bash
#
# try-gtk.sh — one command to build and watch your live network in the GTK window.
#
#   ./scripts/try-gtk.sh           build + launch surveyor (unprivileged) + the GTK UI
#   ./scripts/try-gtk.sh --bpf     same, but surveyor uses the eBPF source (needs caps;
#                                  run ./scripts/try-ebpf.sh first to grant them)
#
# Run it as your normal user (NOT sudo). The default path needs no privileges at all —
# surveyor reads inet_diag + /proc, the GTK app just renders what it streams over a
# Unix socket. Close the window (or Ctrl-C here) to stop everything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
ZIG="$REPO/toolchain/zig"
SURVEYOR="$REPO/zig-out/bin/surveyor"
GTK="$REPO/zig-out/bin/cartograph-gtk"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/cartograph.sock"

bold=$'\e[1m'; green=$'\e[32m'; red=$'\e[31m'; dim=$'\e[2m'; rst=$'\e[0m'
ok()   { echo "${green}✓${rst} $*"; }
fail() { echo "${red}✗ $*${rst}"; exit 1; }
step() { echo; echo "${bold}▸ $*${rst}"; }

BPF_ARG=""
[ "${1:-}" = "--bpf" ] && BPF_ARG="--bpf"

# --- 1. build (TUI-free, just what we need) -------------------------------------
step "Building surveyor + the GTK frontend (-Dgtk)"
echo "${dim}(links system gtk4 + glib; both are already installed)${rst}"
"$ZIG" build -Dgtk || fail "build failed — check: pkg-config --exists gtk4"
[ -x "$SURVEYOR" ] || fail "no $SURVEYOR"
[ -x "$GTK" ] || fail "no $GTK"
ok "built surveyor and cartograph-gtk"

# --- 2. start the capture daemon on a Unix socket -------------------------------
step "Starting:  surveyor serve --socket $SOCK $BPF_ARG"
rm -f "$SOCK"
"$SURVEYOR" serve --socket "$SOCK" $BPF_ARG &
SURVEYOR_PID=$!
# stop the daemon whenever this script exits (window closed, Ctrl-C, error)
trap 'kill "$SURVEYOR_PID" 2>/dev/null || true; rm -f "$SOCK"' EXIT

# give it a beat to bind (the GTK app also retries, so this is just for a clean message)
for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] && ok "surveyor is serving on unix:$SOCK" || fail "surveyor never bound the socket"

# --- 3. open the window ---------------------------------------------------------
step "Opening the GTK window — close it to stop"
"$GTK" --socket "$SOCK"
ok "window closed — shutting surveyor down"
