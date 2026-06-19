# Cartograph

> **A living map of your machine's network — from orbit to the byte.**
> Cartograph answers, for every connection and packet: **what is this, who is it,
> where is it going, and *why was it sent*?** — with a visual identity (the local
> app's icon, the remote service's logo) and a continuous zoom from "who is my machine
> talking to right now" all the way down to raw packet bytes.

*Working title — see [docs/DECISIONS.md](docs/DECISIONS.md). Status: **M2 built** — unprivileged
capture core + live TUI **and a live GTK window**, eBPF source (attach verified), and the
Unix-socket privilege boundary. New here? Read [docs/NEXT-SESSION.md](docs/NEXT-SESSION.md).*

---

## Why this exists

Linux makes you choose between **pretty-but-shallow** (bandwidth dashboards that never
say *why*) and **deep-but-firehose** (Wireshark/tcpdump — superb dissection, but no
process attribution, no human-meaningful identity, a wall of hex). Cartograph closes the
gap with the layer nothing on Linux does well: **why / who / show-me-what-it-is**,
attached at every zoom level.

*(Fact-checked Jun 2026 — Linux-relevant tools only. **GlassWire and Little Snitch are
excluded: GlassWire is Windows/Android-only and Little Snitch is macOS-only.**)*

| capability | Wireshark | OpenSnitch | ntopng | Portmaster | **Cartograph** |
|---|---|---|---|---|---|
| Deep packet dissection | ✅ | ❌ | ◐ nDPI class. | ❌ | ◐ on-demand ·🎯 |
| Per-process attribution | ❌ | ✅ | ❌ host/flow | ✅ | ✅ **proven** |
| Human identity + **logos** | ❌ | ⚠️ app icon | ⚠️ ASN/host | ⚠️ | ✅ 🎯 |
| Continuous **orbit→byte** zoom | ❌ | ❌ | ❌ | ❌ | ✅ 🎯 *(the unique one)* |
| "Why was this sent?" narrative | ❌ | ❌ | ❌ | ❌ | ✅ 🎯 |
| Risk **icon/color** language | ❌ | ⚠️ | ⚠️ | ⚠️ | ✅ 🎯 |
| Native blocking / firewall | ❌ | ✅ | ❌ | ✅ | ◐ XDP 🎯 |
| Always-on + low overhead | ❌ | ✅ | ✅ | ✅ | ✅ 🎯 |
| Native (no Electron) | ✅ Qt | ✅ PyQt | ⚠️ web | ❌ Electron | ✅ Zig |
| TUI **and** GTK, full parity | ❌ | ❌ | ❌ | ❌ | ✅ 🎯 |

Legend: ✅ yes · ◐ partial/on-demand · ⚠️ limited · ❌ no · **🎯 = Cartograph design target,
not yet built** (only per-process attribution is *proven* today — see below). Honest notes:
**Sniffnet** (Rust GUI) is lovely but **cannot attribute processes**; **Portmaster** is the
closest existing Linux tool but ships a heavyweight Electron/Angular UI; **ntopng** is
web-based and host/flow-oriented, not per-process.

## The stack (deliberately not boring, and actually optimal)

One brain, several **expressions** — each on home turf, with **feature parity guaranteed
by construction** (everything lives in the core + a shared view-model, never in a
renderer — see [docs/FRONTENDS.md](docs/FRONTENDS.md)):

- **`surveyor/`** — privileged capture/attribution/enrichment core, in **Zig**. Zero-GC,
  deterministic, trivial C interop (libbpf/libpcap/nDPI), tiny static binary, and Zig can
  compile *to* the eBPF target — kernel programs and loader in one language. **No Python,
  no scripting glue, anywhere in the product.**
- **Two native frontends over the same `libcartograph` view-model:**
  - **Terminal** — native-Zig renderer today (libvaxis later for kitty-graphics logos).
  - **GTK** — **a live GTK4 window today** (GTK4 linked by direct C FFI from Zig; GPU-
    accelerated, **X11 and Wayland**-native), built incrementally alongside every feature
    (D21). zig-gobject's generated bindings remain a later drop-in swap (D10).
- **`atlas/`** — *optional* remote view in **Elixir/Phoenix LiveView** (OTP 27 installed)
  for watching a headless box from your phone. Bonus, not required.

All frontends speak a lean length-prefixed **binary** protocol over a Unix socket — no
JSON/HTTP tax. Power-tool survey + language trade-offs: **[docs/STACK.md](docs/STACK.md)**.

## What already works (proven on this machine)

A pure-Zig spike (`surveyor/src/main.zig`) does live socket→process attribution from
`/proc`, unprivileged, with zero dependencies:

```
PID    COMM             STATE       LOCAL                  REMOTE
3983   chrome           ESTAB       192.168.1.9:35286      140.82.113.26:443     ← GitHub
43256  claude           ESTAB       192.168.1.9:42258      160.79.104.10:443     ← Anthropic
1451   hermes           ESTAB       192.168.1.9:32804      149.154.166.110:443   ← Telegram
44958  steamwebhelper   ESTAB       192.168.1.9:35460      2.18.201.212:443      ← Akamai CDN
```

- **20 ms** to scan all of `/proc`, build the socket→PID map, and parse the TCP table.
- **772 KB** peak RAM · **3.7 MB** static binary · **0** runtime dependencies.

This is the no-privilege *fallback* path; the privileged eBPF path (next milestone) adds
short-lived-connection capture and the rows currently shown as `?` (root/other-user
sockets). A second spike (`experiments/sysmon.zig`) reads your **Radeon live** — busy %,
VRAM, **watts**, °C — unprivileged, proving the cross-resource "see your whole computer"
stream. See **[docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)**.

## Quickstart  (M1 — builds & runs today)

```bash
# Zig 0.16 is vendored in toolchain/ (no system install needed)
./toolchain/zig build                 # build surveyor + cartograph into zig-out/bin
./toolchain/zig build test            # run the unit tests (32 green)
./toolchain/zig build run             # the live TUI (in-process capture)

# the architecture for real — capture core streams binary IPC to the frontend:
./zig-out/bin/surveyor serve | ./zig-out/bin/cartograph --ipc

# …or over the real privilege boundary (a Unix socket, M2):
./zig-out/bin/surveyor serve --socket /tmp/cg.sock &
./zig-out/bin/cartograph --ipc --socket /tmp/cg.sock

./zig-out/bin/surveyor snapshot       # one-shot human-readable attributed table
./zig-out/bin/surveyor snapshot --json | jq   # the agent/Unix surface (NDJSON)

# eBPF capture (M2, opt-in). One script builds it, grants caps, and tests it:
./scripts/try-ebpf.sh                 # asks for your password once (setcap only)
./scripts/try-ebpf.sh --undo          # remove the caps, back to unprivileged

# the GTK window (opt-in build). One script builds it and opens it over the socket:
./scripts/try-gtk.sh                  # unprivileged; close the window to stop
./toolchain/zig build run-gtk -Dgtk -- --socket /tmp/cg.sock   # or run it directly
```
Without caps, `surveyor … --bpf` falls back to the inet_diag path *loudly* (it tells
you exactly what's missing) — it never silently downgrades and never crashes.

The TUI shows, per flow: the owning app + category glyph, the (IPv6-bracketed) endpoint,
a live throughput **sparkline**, total bytes, and **RTT** — all from real cumulative
counters (`inet_diag`), attributed to PIDs via `/proc`, **unprivileged**. `q` quits,
`p` cycles lens profiles (calm → nerd → security → resource).

**Architecture realised in M1:** one `libcartograph` view-model (`src/lib`), a capture
core (`src/capture` + `src/surveyor`) that speaks a lean length-prefixed binary IPC, and a
frontend (`src/tui`) that renders the same model in-process *or* over that IPC — so feature
parity across future frontends is structural, not a promise.

## Repo layout

```
cartograph/
├── README.md            ← you are here
├── build.zig · build.zig.zon   ← Zig 0.16 build (modules + exes + tests)
├── src/
│   ├── lib/             ← libcartograph: the frontend-agnostic view-model
│   │   ├── flow.zig · table.zig · ipc.zig · identity.zig · lens.zig · sparkline.zig
│   ├── capture/         ← capture core: inet_diag byte counters + /proc attribution
│   │   ├── diag.zig · proc.zig · capture.zig
│   ├── capture/bpf/    ← the CO-RE eBPF program (cartograph.bpf.c) + event.h
│   ├── surveyor/main.zig   ← capture CLI: `snapshot` | `serve` (binary IPC / socket)
│   ├── tui/             ← the first frontend: live attributed-flow TUI
│   │   ├── main.zig · term.zig
│   └── gtk/main.zig    ← the GTK4 frontend: live flow window over the IPC socket
├── scripts/            ← try-ebpf.sh (eBPF + caps) · try-gtk.sh (build + open the window)
├── man/cartograph.1     ← man page draft (Bloom UX) — renders clean
├── atlas/               ← optional Elixir/LiveView remote view (scaffold pending)
├── toolchain/           ← vendored Zig 0.16.0 (gitignored)
├── experiments/
│   ├── attribution-spike.zig  ← the original /proc attribution probe (E2)
│   └── sysmon.zig             ← working AMD-GPU + system telemetry spike
├── assets/              ← icons, logo packs, category glyphs
└── docs/
    ├── VISION.md          ← product vision + foresight features (creative north star)
    ├── ARCHITECTURE.md    ← components, tiered capture, blocking, IPC, privilege
    ├── FRONTENDS.md       ← TUI + GTK dual expression, parity, X11/Wayland strategy
    ├── DESIGN-LANGUAGE.md ← colors/icons/risk rings — "colors mean something"
    ├── DATA-STREAMS.md    ← togglable lenses & profiles
    ├── CLI.md             ← the "Bloom" CLI/UX philosophy + flags + man pages
    ├── GPU.md             ← AMD Radeon: render · Vulkan compute · telemetry
    ├── STACK.md           ← Wireshark verdict, real-time, esoteric-language analysis
    ├── ROADMAP.md         ← the journey: milestones M0→M9
    ├── DECISIONS.md       ← locked decisions (incl. "do we recompile the kernel?")
    ├── ONTOLOGY.md        ← the act ontology (Greeting/Rule/Reading/Ruling) — the frame
    ├── AGENT-INTERFACE.md ← the agent/Unix surface — NDJSON, "no AI left out" (D18)
    ├── STATE.md           ← persistence + privacy contract; the `?`-flow design question
    ├── TOOLCHAIN.md       ← Zig 0.16 churn notes + freeze/longevity plan
    ├── STRUCTURE.md       ← project layout + collaboration conventions
    ├── NEXT-SESSION.md    ← handoff: where we are, what's next (start here)
    ├── EXPERIMENTS.md     ← what was tested + results
    └── PLANNING.md        ← historical deliberation (working-title "netscope")
```

## Install status — you already installed the heavy stack ✅

Confirmed present: **clang 18, llvm 18, bpftrace, libbpf-dev, libpcap-dev, libcap2-bin,
libndpi-dev, libelf-dev, tshark/dumpcap, and Elixir/Erlang OTP 27.** 🎉 That unlocks the
eBPF core (M2), nDPI classification (M3), deep-capture export (M5), and the optional
remote view.

The **GTK stack is also installed** (gtk4 4.14.5, libadwaita 1.5.0, gobject-introspection)
and the GTK window builds + runs today (`./scripts/try-gtk.sh`). For reference, the apt line is:
```bash
sudo apt install libgtk-4-dev libadwaita-1-dev gobject-introspection libgirepository1.0-dev
sudo apt install radeontop   # optional: nice for cross-checking GPU telemetry
```
(`libvaxis` and `zig-gobject` are Zig packages a build would fetch — not apt. The current GTK
frontend links system GTK directly via C FFI and needs neither.)

**Kernel recompile is NOT required** — this kernel (6.17) already exposes BTF and every
BPF/XDP feature we need. Rationale in [docs/DECISIONS.md](docs/DECISIONS.md) (D3).
