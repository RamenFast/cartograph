# Cartograph — Architecture

Two components on opposite sides of a privilege boundary, talking over a lean local
socket. This is the OpenSnitch/Little-Snitch split and it matters: capture needs
`CAP_BPF`/`CAP_NET_RAW`; the UI must never be privileged.

> **Note (M2 reality):** the diagram below is the *target*. There are **two live native
> frontends today** over `libcartograph` — the Zig **TUI** *and* a **GTK4 window** (built
> incrementally every step, not deferred to M4 — D21). These are the **single-observer** local
> expressions (one box, one person). The **`atlas` BEAM/LiveView layer is the multi-observer
> fabric** — *essential, not optional* (D9 amended 2026-06-19): it fans one surveyor stream out
> to many simultaneous live observers (your browser, your phone, your AI), which is what the
> "human + their AI(s) watching the same screen, every step" vision actually requires. It is a
> renderer over the same view-model (it consumes `serve --json`), so parity still holds; it is
> *scaffold-only today*. **The Unix-socket boundary is now live**
> (`surveyor serve --socket <path>` ⇄ `cartograph --ipc --socket <path>`) — the same `ipc`
> codec over a real socket, proven byte-identical to the pipe in tests (`usock.zig`,
> `parity.zig`). Capture is still **unprivileged** today (inet_diag + /proc); the **eBPF
> capture source** behind the `Source` seam is built and its live attach is **verified** under
> `setcap` (D-handoff), which is what makes `setcap` load-bearing (see Privilege model below).
> A third, **agent-facing** surface is live too: `snapshot --json`, `serve --json` (the NDJSON
> event twin of the binary IPC), and `--schema` (AGENT-INTERFACE.md). See ROADMAP M1/M2.

```
┌──── frontends (UNPRIVILEGED) · render the same libcartograph view-model ──────────────────┐
│  LOCAL/1-observer: TUI (Zig) · GTK4 (live, D21) · agents (NDJSON)                           │
│  MANY-observer fabric: atlas — Elixir/Phoenix LiveView/OTP (essential — D9 amended)         │
│  semantic-zoom map (orbit→region→street→ground) · "Why" panel · filters · timeline · logos │
└────────────────────────────────────▲─────────────────────────────────────────────────────┘
                                     │  libcartograph (Zig view-model: flow/lens/scoring/identity)
                                     │  Unix domain socket: length-prefixed binary frames
                                     │  (event stream up · commands down) — no JSON, no HTTP
┌────────────────────────────────────┴──────────── surveyor (PRIVILEGED · Zig) ───────────────┐
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐   ┌──────────────────────────────┐    │
│  │ CAPTURE  │──▶│ ATTRIBUTION  │──▶│  ENRICHMENT    │──▶│  STATE / STORE               │    │
│  │ tiered   │   │ socket↔PID↔  │   │ DNS·SNI·Geo·   │   │ live flow table (hashmap) +  │    │
│  │ (T0/1/2) │   │ exe↔cgroup   │   │ ASN·nDPI·icons │   │ ring buffer + opt. sqlite hx │    │
│  └──────────┘   └──────────────┘   └────────────────┘   └──────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

## surveyor (Zig)

### Capture — tiered (the key to "high to deep" without Wireshark's always-on cost)
- **T0 — always-on, cheap.** eBPF kprobes/tracepoints: `tcp_connect`, `inet_sock_set_state`,
  `tcp_sendmsg`/`recvmsg`, `udp_sendmsg`, `sched_process_exec`/`exit`. Per-flow 5-tuple,
  byte/packet counters, state, and **PID/exe at creation time** — counted in-kernel, no
  payload copy. Streamed to userspace via a BPF ring buffer (µs latency). Powers the map.
- **T1 — header sampling.** Packet headers (eBPF or AF_PACKET w/ snaplen) for flags/RTT
  without payload cost.
- **T2 — deep, on demand.** When the user clicks "capture this flow," attach a
  full-payload `AF_PACKET`/`PACKET_MMAP` tap filtered to that 5-tuple → full dissection,
  hex, and `.pcap` export (open in Wireshark/tshark for the protocol long tail).

### Attribution — "why was this sent"  *(unprivileged path PROVEN — see EXPERIMENTS.md E2)*
- **Primary:** eBPF maps populated at socket-create/exec → reliable PID even for
  short-lived connections (`/proc` scrapers miss these under load).
- **Fallback (built & validated):** parse `/proc/net/tcp{,6}`/`udp`, match socket inode →
  `/proc/<pid>/fd/*` → PID → comm/exe/cmdline/parent/uid/cgroup. 20 ms, <1 MB on this box.

### Enrichment — "where / what is it"
- Passive DNS (capture the machine's own answers) + TLS SNI / QUIC SNI → true hostname.
- Offline **GeoIP + ASN** via a local MMDB (no per-lookup network calls).
- **nDPI** (C lib via Zig FFI) for app-protocol classification ("this is BitTorrent/Netflix").
- Service fingerprint: ASN owner + domain → "GitHub / Cloudflare / Telegram / NTP / router".
- **Identity:** local icon via PID→exe→`.desktop`→XDG theme (offline); remote logo via
  favicon/brand pack, cached + rate-limited + opt-in.

### State / store
- In-memory flow table (Zig hashmap) + bounded ring buffer for the live view.
- Optional on-disk history (sqlite) for "what did this app do overnight?"

### Enforcement — observe-first blocking (XDP)
- Cartograph observes by default; on request it installs **XDP** rules to allow / block /
  throttle by app, host, or flow (the same hook family used for capture). Rules are
  first-class, visible, undoable objects surfaced on the map — not opaque iptables.
- Gated behind explicit user action + `--dry-run`/`--explain`; needs `cap_net_admin`.

### System telemetry — the cross-resource stream  *(PROVEN — experiments/sysmon.zig)*
- Reads `amdgpu` sysfs + procfs unprivileged: GPU busy%, VRAM, power(W), temp, CPU load.
- Feeds the **Resource lens** and powers correlation ("this flow ↔ that GPU/VRAM spike").
- The architectural seed of "see your whole computer": net is just the first resource the
  same engine maps; memory/disk/power slot into the same lens model later.

## Frontends — one view-model, native expressions  (full detail: FRONTENDS.md)
- **`libcartograph`** (Zig): the shared, frontend-agnostic view-model — flow state,
  lenses, identity resolution, risk/impact scoring. **All features live here → parity by
  construction**; renderers cannot diverge.
- **Terminal** (Zig + libvaxis) and **GTK** (GTK4 + zig-gobject) link `libcartograph`
  directly and render the same lenses, risk rings, and verbs. GTK is GPU-accelerated and
  X11+Wayland-native; the TUI shows real logos via the kitty graphics protocol.
- **`atlas` — the shared-presence / distribution layer** (Elixir/Phoenix LiveView/OTP 27,
  **essential**, D9 amended 2026-06-19): one supervised GenServer per flow; LiveView pushes
  diffs to *many* simultaneous observers over persistent connections. This is what BEAM is
  *for*, and it's the architectural answer to the multi-substrate north star — the human's
  browser, their phone, **and one or more AI agents** all watching one machine's truth live,
  with presence, every step. It consumes the same view-model surveyor emits (the `serve --json`
  feed), so it invents no truth of its own — parity by construction holds. (BEAM stays *off*
  the capture hot path — D4; its job is fan-out, not capture.)
- "Explain this flow / is this normal?" uses the **local ollama** model (offline); a cloud
  LLM is strictly opt-in.

## IPC — lean by design (honors "minimal glue / fast")
- Unix domain socket, length-prefixed frames `[u32 len][u8 type][payload]`, little-endian,
  forward-compatible (an unknown type is skipped, not fatal — `ipc.zig`). **As built (M2):**
  `hello · flow_upsert · flow_closed · tick · bye`, plus the act-ontology frames reserved
  thin — `user_state` (profile/lens/greeting, **bidirectional**, D22) · `rule` · `reading` ·
  `ruling` (D19/ONTOLOGY.md). **Down** today is just `user_state`; the M2/M6 command frames
  (start-deep-capture, set-filter, the `rule` write path) extend the same enum additively.
- Rationale: a hot event stream shouldn't pay a JSON/HTTP serialization tax; the binary codec
  keeps surveyor dependency-free and is decoded by the Zig frontends directly. For agents and
  scripts the **same view-model** is projected as NDJSON (`serve --json`) — text where text is
  wanted, bytes where speed is wanted, one truth behind both (AGENT-INTERFACE.md).
  *(Historical note: the original rationale cited BEAM's binary pattern-matching; D9 moved BEAM
  off the capture hot path to the `atlas` distribution layer — essential, not optional (D9
  amended 2026-06-19) — so the **hot-path** consumer today is Zig. `atlas` consumes the NDJSON
  feed, not these raw frames.)*

## Privilege model
- `surveyor` runs with file capabilities, **not** root:
  `setcap cap_bpf,cap_perfmon,cap_net_raw,cap_net_admin+ep surveyor`.
- the frontend runs as the normal user; it can only *ask* surveyor to do things.
- Logo/favicon fetching is the only outbound traffic Cartograph itself generates — cached,
  rate-limited, opt-in, and clearly attributed in its own map (no hypocrisy).

### How it runs today (M2 — the boundary is real, unprivileged so far)
```bash
# the daemon binds a Unix socket; the unprivileged frontend connects to it
./zig-out/bin/surveyor serve --socket /run/user/$UID/cartograph.sock &
./zig-out/bin/cartograph --ipc --socket /run/user/$UID/cartograph.sock
```
The socket boundary works **without privilege today** (inet_diag + /proc). It becomes the
*privilege* boundary once the eBPF capture source lands: at that point surveyor needs caps,
granted by file capabilities (Ben runs this — `setcap` requires root; apt/sudo are not
passwordless in the agent sandbox):
```bash
sudo setcap cap_bpf,cap_perfmon,cap_net_raw,cap_net_admin+ep ./zig-out/bin/surveyor
# verify the caps stuck, and that the daemon never runs as root:
getcap ./zig-out/bin/surveyor      # → cap_bpf,cap_net_admin,cap_net_raw,cap_perfmon=ep
```
The frontend is **never** granted caps — that's the whole point of the split.

## Performance posture
- Count in-kernel; surface aggregates. Never copy payloads in T0/T1.
- Target: always-on overhead indistinguishable from idle on a desktop; deep capture only
  for an explicitly selected flow. Real-time is the design point, not a stretch goal.
