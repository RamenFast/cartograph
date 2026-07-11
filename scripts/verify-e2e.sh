#!/usr/bin/env bash
# verify-e2e.sh — the whole-system truth check (audit F25/F26: the public
# binaries and daemon behavior must have a regression gate, not just unit tests).
#
# Exercises the *shipped* surfaces end to end: contracts, exit codes, the
# session daemon, the shared cursor, ctl, fd hygiene, and pipe behavior.
# Run it after any change:   ./scripts/verify-e2e.sh
# Exit 0 = every check passed. Nonzero = the count of failures.
set -u
cd "$(dirname "$0")/.."

ZIG=${ZIG:-./toolchain/zig-x86_64-linux-0.16.0/zig}
BPF_FLAG=${BPF_FLAG:---bpf-auto}   # --bpf-auto: use -Dbpf=true only if bpftool+BTF exist
PASS=0; FAIL=0
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'

ok()   { PASS=$((PASS+1)); printf '%sok%s     %s\n' "$GREEN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '%sFAIL%s   %s\n' "$RED" "$RST" "$1"; }
check(){ if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi }

# ---- 0. build + unit tests -------------------------------------------------
BUILD_FLAGS=""
if [ "$BPF_FLAG" = "--bpf-auto" ]; then
    if command -v bpftool >/dev/null 2>&1 && [ -r /sys/kernel/btf/vmlinux ]; then
        BUILD_FLAGS="-Dbpf=true"
    fi
elif [ "$BPF_FLAG" = "--bpf" ]; then BUILD_FLAGS="-Dbpf=true"; fi
if pkg-config --exists gtk4 2>/dev/null; then BUILD_FLAGS="$BUILD_FLAGS -Dgtk=true"; fi
printf '%sbuild flags:%s %s\n' "$DIM" "$RST" "${BUILD_FLAGS:-'(none)'}"

$ZIG build $BUILD_FLAGS >/dev/null 2>&1
check $? "zig build $BUILD_FLAGS"
$ZIG build test $BUILD_FLAGS >/dev/null 2>&1
check $? "zig build test (unit suite)"

B=./zig-out/bin/surveyor
[ -x "$B" ] || { bad "surveyor binary exists"; echo "cannot continue"; exit 1; }

# ---- 1. one-shot contracts (workspace R1/R2/R5/R6) -------------------------
TMP=$(mktemp -d /tmp/cg-verify-XXXX)
trap 'rm -rf "$TMP"' EXIT

$B --schema > "$TMP/schema.json" 2>/dev/null
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="ok" and d["tool"] and d["version"] and "T" in d["ts"]
assert len(d["events"])==8 and d["commands"] and d["flow_fields"]
' "$TMP/schema.json" >/dev/null 2>&1
check $? "--schema: valid JSON, envelope, 8 events, commands array"

$B status > "$TMP/status.json" 2>/dev/null
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="ok" and d["version"] and "T" in d["ts"]
assert d["capture"]["source"] in ("polling","ebpf+polling")
assert isinstance(d["listeners"],list) and "flows" in d
' "$TMP/status.json" >/dev/null 2>&1
check $? "status: envelope + capture posture + listeners"

$B snapshot --json 2>/dev/null | head -50 > "$TMP/snap.ndjson"
python3 -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    d=json.loads(line); assert "proto" in d and "local_port" in d; n+=1
assert n>0
' "$TMP/snap.ndjson" >/dev/null 2>&1
check $? "snapshot --json: every line parses, stable fields"

# ---- 2. exit codes mean something (workspace R4) ---------------------------
$B no-such-verb   >/dev/null 2>&1; [ $? -eq 3 ]; check $? "unknown verb exits 3"
$B serve --bogus  >/dev/null 2>&1; [ $? -eq 3 ]; check $? "unknown flag exits 3"
$B ctl focus asn NaN --socket /tmp/nonexist.sock >/dev/null 2>&1; [ $? -eq 3 ]
check $? "ctl bad grammar exits 3"
$B ctl focus orbit --socket /tmp/definitely-no-daemon-$$.sock >/dev/null 2>&1; [ $? -eq 2 ]
check $? "ctl with no daemon exits 2"

# ---- 3. pipe behavior (F19: normal Unix consumers) -------------------------
timeout 10 sh -c "$B serve --json 2>/dev/null | head -1 >/dev/null"
check $? "serve --json | head -1 : clean exit on downstream hangup"

timeout 6 $B serve --json 2>/dev/null | head -2 > "$TMP/greeting.ndjson"
python3 -c '
import json,sys
lines=[json.loads(l) for l in open(sys.argv[1])]
assert lines[0]["event"]=="hello" and lines[0]["ev"]=="hello"   # canonical + alias
assert lines[1]["event"]=="posture" and "source" in lines[1]
' "$TMP/greeting.ndjson" >/dev/null 2>&1
check $? "stream greeting: hello then posture, event+ev on every line"

# ---- 4. the session daemon (F5/F20: one core, many observers) --------------
S=$(mktemp -u /tmp/cg-verify-XXXX.sock)
"$B" serve --socket "$S" >/dev/null 2>&1 &
DPID=$!
for i in $(seq 1 30); do [ -S "$S.json" ] && break; sleep 0.1; done
[ -S "$S.json" ]; check $? "daemon binds <sock> and <sock>.json"

python3 - "$S" "$B" <<'EOF'
import json, socket, subprocess, sys, time
sock, B = sys.argv[1], sys.argv[2]

def watcher():
    s = socket.socket(socket.AF_UNIX); s.connect(sock + ".json"); s.settimeout(5)
    return s

def lines_of(s, want, deadline=6.0):
    buf, t0, out = b"", time.time(), []
    while time.time() - t0 < deadline:
        try: buf += s.recv(65536)
        except socket.timeout: break
        for raw in buf.split(b"\n")[:-1]:
            d = json.loads(raw)
            if d.get("event") == want: out.append(d)
        buf = buf.split(b"\n")[-1]
        if out: break
    return out

fails = []
a, b = watcher(), watcher()          # two simultaneous NDJSON observers
lines_of(a, "focus"); lines_of(b, "focus")   # drain the greetings

r = subprocess.run([B, "ctl", "focus", "app", "verifytest", "--socket", sock],
                   capture_output=True, text=True)
if r.returncode != 0: fails.append(f"ctl ack exit {r.returncode}")
if '"event":"ack"' not in r.stdout: fails.append("ctl did not print the ack line")

fa = lines_of(a, "focus"); fb = lines_of(b, "focus")
for name, f in (("A", fa), ("B", fb)):
    if not f: fails.append(f"observer {name} never saw the broadcast focus"); continue
    d = f[0]
    if not d.get("shared"): fails.append(f"observer {name}: focus not shared")
    if d.get("entity") != "verifytest": fails.append(f"observer {name}: wrong entity")

# a malformed command comes back as a structured error with a fix
a.sendall(b'{"cmd":"focus","target":"asn"}\n')
errs = lines_of(a, "error")
if not errs or not errs[0].get("fix"): fails.append("malformed command: no error+fix reply")

a.close(); b.close()
for m in fails: print("  detail:", m)
sys.exit(1 if fails else 0)
EOF
check $? "two observers + ctl: broadcast shared focus, ack, error+fix"

# fd hygiene: churn connections, the daemon's fd table must not grow (F20)
FD0=$(ls /proc/$DPID/fd | wc -l)
for i in $(seq 1 8); do
    python3 -c "
import socket
s=socket.socket(socket.AF_UNIX); s.connect('$S.json'); s.recv(4096); s.close()" 2>/dev/null
done
sleep 2.5   # let the sweep run
FD1=$(ls /proc/$DPID/fd | wc -l)
[ "$FD1" -le "$FD0" ]; check $? "fd hygiene: $FD0 -> $FD1 after 8 churned connections"

kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
rm -f "$S" "$S.json"

# ---- 5. exit-idle: the daemon leaves with its last observer (F2) ------------
S2=$(mktemp -u /tmp/cg-verify-XXXX.sock)
"$B" serve --socket "$S2" --exit-idle >/dev/null 2>&1 &
D2=$!
for i in $(seq 1 30); do [ -S "$S2.json" ] && break; sleep 0.1; done
python3 -c "
import socket,time
s=socket.socket(socket.AF_UNIX); s.connect('$S2.json'); s.recv(4096); time.sleep(0.5); s.close()"
DEAD=1
for i in $(seq 1 40); do kill -0 $D2 2>/dev/null || { DEAD=0; break; }; sleep 0.25; done
check $DEAD "--exit-idle: daemon exits after its last observer disconnects"
kill $D2 2>/dev/null; rm -f "$S2" "$S2.json"

# ---- verdict ----------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
exit $FAIL
