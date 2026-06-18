# Cartograph — planning  *(historical · written under the working name "netscope")*

> Kept as the deliberation record — what was considered and rejected. The project is now
> **Cartograph**; "netscope" below is the old working title. Current decisions live in
> DECISIONS.md (esp. D9 for frontends).

> A Linux-first, eBPF-powered network traffic analyzer that answers, for every packet/flow:
> **What is this? Who is it? Where is it going? Why was it sent — which process & why?**
> with a *visual* identity (app icon + destination logo) at a glance, and the ability to
> zoom from a high-level "what is my machine talking to" view down to raw packet bytes.

Status: pre-implementation. This doc captures the concept, the environment, the
candidate architecture, and the open decisions. Nothing is built yet.

---

## 1. The concept (restated)

Today's tools force a choice:
- **High-level / pretty** (GUI dashboards) but shallow — they show bandwidth per app, not *why*.
- **Deep / accurate** (Wireshark, tcpdump) but firehose — great packet dissection, but
  no process attribution ("which app sent this?"), no human-meaningful identity
  ("that IP is Spotify's CDN"), and a steep wall of hex.

The gap netscope fills: **a single continuous zoom** from
`my machine ⇄ the internet` (with recognizable logos/icons) all the way down to the
byte layout of a chosen packet — with *process attribution and intent* attached at
every level. The differentiator is not "another packet sniffer"; it's the
**"why / who / show-me-what-it-is"** layer that nothing on Linux does well.

Three questions the UI must always be able to answer for a selected flow/packet:
1. **Why was it sent?** → originating process, executable path, command line, parent
   process, the syscall/socket event that created it, user, container/cgroup.
2. **Where is it going / coming from?** → resolved hostname (rDNS + TLS SNI/QUIC),
   GeoIP, ASN/owner ("AS15169 Google"), known-service fingerprint.
3. **What is it? (show me)** → the local app's desktop icon, and the remote service's
   logo/favicon, so the connection reads as `[Firefox icon] → [GitHub logo]` not
   `34221 → 140.82.121.4:443`.

---

## 2. Target environment (this machine — verified 2026-06-17)

| Aspect | Value | Implication |
|---|---|---|
| Distro | Linux Mint 22.3 (Ubuntu 24.04 base) | Debian packaging; apt deps |
| Kernel | 6.17.0-35-generic | Very modern eBPF; all hooks available |
| BTF | `/sys/kernel/btf/vmlinux` present (6.9 MB) | **CO-RE works** → portable single binary |
| Kernel headers | linux-headers-6.17 installed | eBPF build deps satisfied |
| Desktop | Cinnamon on **X11** | GTK-native env; X11 (not Wayland) simplifies any capture-overlay later |
| Rust | 1.95.0 | First-class for aya (eBPF) + native GUI |
| Go | 1.22.2 | Alt path: cilium/ebpf + gopacket (OpenSnitch's stack) |
| Toolchain | gcc 13.3, bpftool 7.7, **no clang** | clang/LLVM needed if compiling eBPF C; aya avoids this (Rust→eBPF) |
| Existing | tcpdump, ss, nethogs | No Wireshark; clear field |

Design assumption: **target this machine first** (Mint/Ubuntu, X11, modern kernel),
keep the capture layer portable via CO-RE so other distros come cheap later.

---

## 3. Candidate architecture

Split into a **privileged capture/enrichment core** and an **unprivileged UI**, talking
over a local socket. This is the OpenSnitch/Little-Snitch pattern and it matters:
packet capture + eBPF needs `CAP_NET_RAW`/`CAP_BPF`/`CAP_NET_ADMIN`; the GUI must not.

```
                 ┌───────────────────────── UI (unprivileged) ──────────────────────┐
                 │  high-level map  ·  flow list  ·  per-flow detail  ·  packet hex   │
                 │  app icons + remote logos   ·   timeline / live   ·   filters      │
                 └───────────────▲───────────────────────────────────────────────────┘
                                 │  local IPC (unix socket: proto/JSON/SSE)
   ┌─────────────────────────────┴──────────── core daemon (privileged) ─────────────┐
   │  ┌───────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────────────┐ │
   │  │  CAPTURE  │──▶│  ATTRIBUTION │──▶│  ENRICHMENT   │──▶│  STATE / STORE       │ │
   │  │ eBPF +    │   │ socket↔PID↔  │   │ DNS/SNI/Geo/  │   │ live flow table +    │ │
   │  │ AF_PACKET │   │ exe↔cgroup   │   │ ASN/service/  │   │ ring buffer + opt.   │ │
   │  │ (tiered)  │   │ (eBPF maps)  │   │ icons/logos   │   │ on-disk history      │ │
   │  └───────────┘   └──────────────┘   └───────────────┘   └──────────────────────┘ │
   └────────────────────────────────────────────────────────────────────────────────┘
```

### 3a. Capture layer — *tiered* (the key idea for "high to deep")
- **Tier 0 — always-on, cheap:** eBPF kprobes/tracepoints on
  `tcp_connect`, `tcp_sendmsg`/`recvmsg`, `udp_sendmsg`, `inet_sock_set_state`,
  `sched_process_exec/exit`. Gives every flow's 5-tuple, byte/packet counters, state,
  and — crucially — the **PID/exe at creation time** with no packet copying. This
  powers the high-level view at ~zero overhead even at high pps.
- **Tier 1 — metadata sampling:** packet headers only (via eBPF or AF_PACKET with a
  snaplen) for protocol/flag/RTT detail without full payload cost.
- **Tier 2 — deep capture, on demand:** when the user clicks a flow "capture this,"
  attach a full-payload AF_PACKET/`PACKET_MMAP` (or pcap) tap filtered to that 5-tuple,
  enabling full dissection + hex + export to `.pcap` (Wireshark interop).

This tiering is what lets it be both "performant always-on monitor" and "deep analyzer
when you want it," instead of paying Wireshark's full-capture cost continuously.

### 3b. Attribution layer — "why was this sent"
- Primary: eBPF maps populated at socket-creation/exec time → reliable PID, even for
  short-lived connections (the case /proc-scraping tools miss). Mirrors OpenSnitch's
  finding that eBPF beats /proc and audit under load.
- Fallback: netlink `sock_diag` + `/proc/<pid>` for anything missed.
- Enrich PID → exe path, cmdline, parent chain, UID/user, cgroup/container, systemd unit.

### 3c. Enrichment layer — "where is it / what is it"
- **rDNS** + passive capture of the machine's own DNS answers to map IP→hostname
  truthfully (not just PTR), plus **TLS SNI / QUIC** extraction for the real domain
  even before DNS is cached.
- **GeoIP + ASN** from a local MMDB (offline, no per-lookup network calls).
- **Service fingerprinting**: ASN owner + domain → "Google / Cloudflare / AWS S3 /
  Spotify CDN / NTP / your router," with a confidence level.
- **Identity / icons (the "show me" feature):**
  - Local app icon: PID→exe→`.desktop`→XDG icon theme lookup (native, offline).
  - Remote logo: domain→favicon / known-brand logo pack, cached locally; degrade
    gracefully to a category glyph (cloud, CDN, ad/tracker, p2p, OS-update…).

### 3d. State / store
- Live in-memory flow table + bounded ring buffer for the real-time view.
- Optional on-disk history (sqlite or columnar) for "what did this app do last night."

---

## 4. Stack — esoteric-language direction (decision pending)

User wants an *esoteric / weird-cool* language, not Rust/Go. Good news: two of the
prime candidates are also genuinely the *right* tools because this app is two very
different machines bolted together — a low-level zero-GC hot path, and a soft-real-time
concurrency/UI layer. Full analysis + power-tool survey + "is real-time achievable"
in **STACK.md**. Summary of the leading direction:

- **Zig** for the eBPF + capture/attribution core — manual memory, no GC, trivial C
  interop (libbpf/libpcap/nDPI), tiny static binary, and Zig can compile *to* the eBPF
  target via LLVM, so the kernel programs AND the loader can be one Zig codebase. Rare,
  cohesive, and actually optimal for the hot path.
- **Elixir + Phoenix LiveView** for real-time orchestration + UI — soft-real-time is
  BEAM's literal home turf; model each flow as an OTP process; LiveView gives a live,
  logo-rich dashboard almost for free. Pair to Zig via a Port/NIF.

Single-language alternatives (Zig-only, Elixir-only, Haskell) and the tradeoffs are in
STACK.md §3.

---

## 5. Risks & hard parts (so they're not surprises)
- **Privilege model**: must isolate the capturing daemon; never run the GUI as root.
  Use capabilities, not full root, where possible.
- **Encrypted payloads**: TLS/QUIC means Tier-2 hex is mostly ciphertext. Value is in
  *metadata* (SNI, sizes, timing, cert) unless we add opt-in keylog/MITM (out of scope
  for v1, big trust/complexity cost).
- **Logo/favicon fetching** = outbound requests that themselves generate traffic and
  leak which sites you visit to favicon hosts. Must be cached, rate-limited, and
  ideally pre-bundled / opt-in.
- **GeoIP/ASN data licensing**: MaxMind GeoLite2 is free but lower quality + license
  signup; IPLocate/IPinfo Lite offer open-licensed daily MMDBs. Pick a redistributable
  source (matters if shipping).
- **High-pps performance**: do counting in-kernel (eBPF maps), only surface aggregates;
  never copy full payloads in Tier 0/1.
- **Wayland later**: this box is X11 (easy); other users on Wayland constrain any
  screen-overlay ambitions (not needed for v1).

---

## 6. Open decisions — see DECISIONS.md (answered via questioning)

---

## Sources
- Aya (Rust eBPF): https://github.com/aya-rs/aya · https://aya-rs.dev/ · FOSDEM 2026 talk
- OpenSnitch architecture: https://deepwiki.com/evilsocket/opensnitch · https://lwn.net/Articles/988401/
- Little Snitch / eBPF app firewalls on Linux: https://www.mrlatte.net/en/stories/2026/04/09/littlesnitch-for-linux/
- Free GeoIP/ASN data: https://www.iplocate.io/free-databases · https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/
- Rust GUI survey: https://blog.logrocket.com/state-rust-gui-libraries/ · https://areweguiyet.com/
