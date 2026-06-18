#!/usr/bin/env bash
#
# try-ebpf.sh — one command to build, grant caps, and test the eBPF capture path.
#
#   ./scripts/try-ebpf.sh          build + setcap + run the eBPF snapshot
#   ./scripts/try-ebpf.sh --undo   remove the caps again (back to unprivileged)
#
# Run it as your normal user (NOT with sudo). It will ask for your password once,
# only for the single `setcap` step. surveyor itself never runs as root.

set -euo pipefail

# Resolve the repo root from this script's location, so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
ZIG="$REPO/toolchain/zig"
SURVEYOR="$REPO/zig-out/bin/surveyor"
CAPS="cap_bpf,cap_perfmon,cap_net_raw,cap_net_admin+ep"

bold=$'\e[1m'; green=$'\e[32m'; red=$'\e[31m'; dim=$'\e[2m'; rst=$'\e[0m'
ok()   { echo "${green}✓${rst} $*"; }
fail() { echo "${red}✗ $*${rst}"; exit 1; }
step() { echo; echo "${bold}▸ $*${rst}"; }

# setcap usually lives in /sbin, which isn't always on the PATH.
SETCAP="$(command -v setcap || echo /sbin/setcap)"
[ -x "$SETCAP" ] || fail "setcap not found. Install it:  sudo apt install libcap2-bin"

# --- teardown mode --------------------------------------------------------------
if [ "${1:-}" = "--undo" ]; then
  step "Removing capabilities from surveyor"
  [ -e "$SURVEYOR" ] || fail "no binary at $SURVEYOR (nothing to undo)"
  sudo "$SETCAP" -r "$SURVEYOR"
  ok "caps removed — surveyor is back to the unprivileged inet_diag path"
  exit 0
fi

# --- 1. build with the eBPF source ----------------------------------------------
step "Building surveyor with the eBPF source (-Dbpf=true)"
echo "${dim}(needs clang + bpftool; first build generates vmlinux.h — can take a moment)${rst}"
if ! "$ZIG" build -Dbpf=true; then
  fail "build failed. Most likely a missing tool — check:  clang --version  and  bpftool version"
fi
[ -x "$SURVEYOR" ] || fail "build reported success but $SURVEYOR is missing"
ok "built $SURVEYOR"

# --- 2. grant the capabilities (the one sudo step) ------------------------------
# NOTE: file caps are wiped every time the binary is rebuilt, so we setcap AFTER
# building, every run. That's why this is a script and not a thing you do once.
step "Granting capabilities (you'll be asked for your password once)"
echo "${dim}$SETCAP $CAPS $SURVEYOR${rst}"
sudo "$SETCAP" "$CAPS" "$SURVEYOR" || fail "setcap failed"
GOT="$("$(command -v getcap || echo /sbin/getcap)" "$SURVEYOR")"
ok "caps set:  $GOT"

# --- 3. run the eBPF snapshot and judge the result ------------------------------
step "Running:  surveyor snapshot --bpf"
OUT="$("$SURVEYOR" snapshot --bpf 2>&1 || true)"

echo
if echo "$OUT" | grep -q "eBPF source unavailable"; then
  echo "${red}${bold}eBPF did NOT attach — it fell back to inet_diag.${rst}"
  echo "${dim}Why (surveyor + libbpf said):${rst}"
  echo "$OUT" | grep -iE "eBPF source unavailable|libbpf|permitted|MEMLOCK" | sed 's/^/    /'
  echo
  echo "Common causes: caps didn't stick (rebuild wipes them — rerun this script),"
  echo "or this kernel/config rejects the program. Paste the lines above to Claude."
  exit 1
else
  ROWS="$(echo "$OUT" | grep -cE 'ESTAB|LISTEN|CLOSE|SYN' || true)"
  echo "${green}${bold}eBPF attached and is capturing. 🎉${rst}"
  echo "    saw ${ROWS} flow row(s) from the kernel ring buffer (no fallback note printed)."
  echo
  echo "Try the live view over the privilege boundary:"
  echo "    ${dim}$SURVEYOR serve --socket /tmp/cg.sock &${rst}"
  echo "    ${dim}$REPO/zig-out/bin/cartograph --ipc --socket /tmp/cg.sock${rst}"
  echo
  echo "When you're done, remove the caps with:  ${dim}./scripts/try-ebpf.sh --undo${rst}"
fi
