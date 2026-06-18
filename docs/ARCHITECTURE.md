# Cartograph — Architecture

Two components on opposite sides of a privilege boundary, talking over a lean local
socket. This is the OpenSnitch/Little-Snitch split and it matters: capture needs
`CAP_BPF`/`CAP_NET_RAW`; the UI must never be privileged.

> **Note (M1 reality):** the diagram below is the *target*. As of M1 the frontend is a
> native-Zig **TUI** over `libcartograph`; the **GTK** expression lands in M4 and the
> Elixir/LiveView remote view is an *optional* extra (D9), not the primary UI. Capture is
> still **unprivileged** (inet_diag + /proc) and links in-process; the privilege boundary
> and the Unix socket go live with **M2** (eBPF). The IPC frame format already exists and is
> transport-agnostic (pipe today, socket then). See ROADMAP M1/M2.

```
┌──── frontends (UNPRIVILEGED) · render the same libcartograph view-model ──────────────────┐
│  TUI (Zig+libvaxis later) · GTK4 (M4) · optional Elixir/LiveView remote view (D9)          │
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
- **Optional remote view** (Elixir/Phoenix LiveView, OTP 27 installed): one GenServer per
  flow; LiveView pushes diffs to a browser — for watching a headless box from your phone.
- "Explain this flow / is this normal?" uses the **local ollama** model (offline); a cloud
  LLM is strictly opt-in.

## IPC — lean by design (honors "minimal glue / fast")
- Unix domain socket. **Up:** event frames `[u32 len][u8 type][payload]` (flow-new,
  flow-update, flow-closed, dns, process). **Down:** command frames (start-deep-capture,
  set-filter, resolve-identity). Encoding: packed structs / CBOR — **not** JSON-over-HTTP.
- Rationale: BEAM parses binaries extremely well; avoids a serialization tax on a hot
  event stream; keeps surveyor dependency-free.

## Privilege model
- `surveyor` runs with file capabilities, **not** root:
  `setcap cap_bpf,cap_perfmon,cap_net_raw,cap_net_admin+ep surveyor`.
- `atlas` runs as the normal user; it can only *ask* surveyor to do things.
- Logo/favicon fetching is the only outbound traffic Cartograph itself generates — cached,
  rate-limited, opt-in, and clearly attributed in its own map (no hypocrisy).

## Performance posture
- Count in-kernel; surface aggregates. Never copy payloads in T0/T1.
- Target: always-on overhead indistinguishable from idle on a desktop; deep capture only
  for an explicitly selected flow. Real-time is the design point, not a stretch goal.
