# Cartograph — Experiment log

Real tests run during planning, with results. Throwaway probes live in `experiments/`.

## E0 — Environment capability probe  ✅
- Linux Mint 22.3 (Ubuntu 24.04 base), kernel **6.17.0-35**, Cinnamon on **X11**.
- **BTF present** (`/sys/kernel/btf/vmlinux`, 6.9 MB) → CO-RE eBPF viable; portable binary.
- Toolchains: Rust 1.95, Go 1.22, gcc 13.3, bpftool 7.7, perf, tcpdump, ss, nethogs.
  **Absent:** clang, libbpf-dev, libpcap-dev, bpftrace, Zig, Elixir/Erlang, Wireshark.
- **No passwordless sudo** in this session → cannot load eBPF here; can do unprivileged work.
- **Bash sandbox has network** (ziglang.org → HTTP 200) → could vendor Zig.
- User is in groups `sudo, docker, ollama` → a local LLM runtime is already installed
  (useful for offline "explain this flow"). Interfaces: `lo`, `enp3s0`.
- `ss -tnp` already attributes own-process sockets unprivileged (steam/hermes/chrome…).

## E1 — Vendor Zig 0.16 locally (no root)  ✅
- Parsed Zig's release index, downloaded `zig-x86_64-linux-0.16.0` (53 MB) into
  `toolchain/`, verified `zig version` → 0.16.0. Confirms a no-install dev path.
- Note: Zig 0.16 has a large I/O/args/fs redesign vs older docs — filesystem ops now take
  an explicit `Io` (from the new `Init` param to `main`), `readLink` returns a length,
  `mem.trimRight`→`trimEnd`, `Thread.sleep`→`io.sleep`, `process.argsAlloc` removed.
  These were discovered by compiling against the vendored std; notes captured for M1.

## E2 — Unprivileged socket→process attribution in pure Zig  ✅ (foundational proof)
`experiments/attribution-spike.zig` (the original one-shot probe; promoted into `src/` in
M1). Parses `/proc/net/tcp`, builds an inode→(pid,comm) map by
scanning `/proc/<pid>/fd/*` socket symlinks, and joins them. Zero dependencies.

**Sample (real, live):**
```
3983   chrome           ESTAB   192.168.1.9:35286   140.82.113.26:443    (GitHub)
43256  claude           ESTAB   192.168.1.9:42258   160.79.104.10:443    (Anthropic)
1451   hermes           ESTAB   192.168.1.9:32804   149.154.166.110:443  (Telegram)
44958  steamwebhelper   ESTAB   192.168.1.9:35460   2.18.201.212:443     (Akamai)
```

**Metrics (ReleaseFast):**
| metric | value |
|---|---|
| full snapshot (scan all /proc + map + parse tcp) | **20 ms** |
| peak RSS | **772 KB** |
| static binary | **3.7 MB** |
| sockets attributed | **47 / 54** (rest = root/other-user, need privilege) |
| dependencies | **0** |

**Conclusions:**
- The attribution model is correct and extremely cheap → great always-on fallback.
- The `?` rows (sshd:22, cups:631, systemd-resolved:53, nginx:80) confirm exactly what the
  privileged eBPF path (M2) must add: other-user + short-lived sockets.
- Zig 0.16 is a viable, fast, dependency-free core. The std API churn is manageable.

## E3 — AMD GPU + system telemetry in pure Zig  ✅
`experiments/sysmon.zig`. Discovers the DRM card dynamically; reads sysfs/procfs
unprivileged: `gpu_busy_percent`, VRAM used/total, hwmon `power1_average` + `temp1_input`,
`/proc/loadavg`. Live sample: **GPU busy 5% · VRAM 0.7/12.0 GiB · 9.0 W · 41 °C**. Compiled
first try (0.16 patterns internalized). Proves the cross-resource "see your whole computer"
stream + the Radeon RX 6700 XT (RDNA2) integration, with zero privilege.

## E4 — inet_diag byte counters + RTT, unprivileged  ✅ (M1)
`src/capture/diag.zig`. A from-scratch `sock_diag`/`inet_diag` netlink client (the API
`ss` uses) dumps every TCP/UDP socket over v4+v6 and reads `tcpi_bytes_acked` /
`tcpi_bytes_received` (genuine **cumulative** counters) + smoothed RTT from the embedded
`struct tcp_info` — no privilege, no `CAP_NET_ADMIN`. This is the correction to a wrong
assumption: `/proc/net/tcp`'s tx/rx_queue are *queue depth*, not throughput, so they can't
drive a live rate. inet_diag can. Live sample: `claude 160.79.104.10:443 ↑12.0 MB ↓242 KB
24 ms`, `spotify [2a04:4e42:4e::760]:443 89.1 MB 43 ms`.

## E6 — Live attributed-flow TUI over `libcartograph`  ✅ (M1)
`src/tui`. A native-Zig renderer (alt-screen, raw `/dev/tty`, `poll`-driven, `ioctl`
winsize) draws the shared `FlowTable`: category color+glyph, **animated throughput
sparklines** (`▁▇█`), IPv6-bracketed endpoints, fresh-flow amber dot, switchable lens
profiles. Proven to run two ways through the **same** `render()`:
- in-process capture (`cartograph`), and
- consuming `surveyor`'s binary IPC (`surveyor serve | cartograph --ipc`).
Parity-by-construction is now demonstrated, not just asserted. (libvaxis deferred — see
ROADMAP M1; the renderer boundary makes it a later backend swap.)

## Environment update (2026-06-17)
Deps since installed & confirmed: clang 18, llvm 18, libbpf-dev, libpcap-dev, libcap2-bin,
libndpi-dev, libelf-dev, bpftrace 0.20.2, tshark/dumpcap 4.2.2, **Elixir/Erlang OTP 27**.
GPU: **Radeon RX 6700 XT**, amdgpu driver, Vulkan (RADV) + glxinfo present, telemetry
readable. Still missing: `libgtk-4-dev`, vala (the GTK frontend stack). apt is not
passwordless in this sandbox.

## Fact-check — comparison table (Jun 2026)
- **GlassWire**: Windows/Android only — **not on Linux**; removed from the table.
- **OpenSnitch**: PyQt6; shows dest IP/host/port + PID/path/cmdline + (buggy) app icon →
  identity is ⚠️ not ✅; no remote logos/geo.
- **Sniffnet** (Rust GUI): real-time & pretty, but **does not attribute processes/PIDs**.
- **Portmaster**: closest existing Linux app firewall + monitor, but **Electron/Angular UI**.
- **ntopng**: deep via nDPI but **web-based + host/flow-oriented**, not per-process.
- Cartograph's ticks are honestly marked 🎯 = design target; only attribution is proven today.

## Pending (need privilege or a later milestone)
- E5: minimal eBPF load via libbpf/Zig (needs CAP_BPF; deps present) — M2. Closes the `?`
  rows (root/other-user, short-lived) the /proc path still misses.
- E5b: bpftrace one-liner on `tcp_connect` to cross-check kernel-level attribution (sudo).
- E7: GTK4 zig-gobject window spike + the libvaxis-on-0.16 patch (kitty-graphics logos) — M4.
