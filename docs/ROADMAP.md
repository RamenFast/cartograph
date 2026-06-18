# Cartograph — Roadmap / the journey

Each milestone is shippable and demoable on its own. ✅ done · 🔨 next · ⬜ planned.
Cross-resource and visual-language work is threaded through, not bolted on at the end.

## M0 — Foundation  ✅ (done this session)
- ✅ Env validated: kernel 6.17, **BTF present** (CO-RE works), Cinnamon/X11, **Radeon RX 6700 XT**.
- ✅ Heavy deps installed: clang/llvm 18, libbpf, libpcap, libndpi, bpftrace, tshark, **Elixir/OTP 27**.
- ✅ Zig 0.16 vendored locally (no system install).
- ✅ **Proof 1:** pure-Zig unprivileged socket→PID attribution — 20 ms, 772 KB, 47/54 sockets.
- ✅ **Proof 2:** pure-Zig AMD-GPU + system telemetry (busy/VRAM/W/°C) unprivileged.
- ✅ Vision, architecture, stack, frontends, design-language, lenses, CLI, GPU, decisions, man page.

## M1 — `surveyor` MVP + the shared view-model  ✅ (this session)
- ✅ Split out **`libcartograph`** (`src/lib`): flow model, live `FlowTable` (rate/freshness
  derivation, closed-flow sweep), the **binary IPC** frame codec, category/identity
  inference, lens/profile system. 13 unit tests green.
- ✅ Promote the spike → `surveyor` (`src/surveyor`, `src/capture`): **tcp + udp over v4 & v6**,
  **real cumulative byte counters + RTT via `inet_diag` netlink** (the honest unprivileged
  source — `/proc/net/tcp` only has queue depth), `/proc` PID/exe attribution, a native
  1 Hz live loop, and the **lean length-prefixed binary IPC** (`surveyor serve`).
- ✅ First renderer wired: a native-Zig **live attributed-flow TUI** (`src/tui`) over
  `libcartograph` — category color+glyph, animated throughput sparklines, IPv6-bracketed
  endpoints, fresh-flow glow, lens **profiles**. Runs in-process *or* over the IPC
  (`surveyor serve | cartograph --ipc`) through the same `render()` — parity proven.
- *Demo (real):* `zig build run` — past `nethogs` already (per-flow bytes **and** RTT
  **and** category **and** v6 **and** sparklines).
- **libvaxis deferred, deliberately.** It targets Zig 0.15.1; on 0.16's reworked I/O it
  needs non-trivial patching, and its headline win (kitty-graphics logos) isn't needed
  until M4/M7. We shipped a native renderer behind the same view-model, so libvaxis
  becomes a drop-in *render backend* swap when logos land — no architectural debt.

## M2 — eBPF capture + attribution (privileged core)
- eBPF on tcp_connect / sock_state / exec (Zig→BPF or libbpf via FFI); BPF ring buffer →
  Zig. Closes the `?` rows (root/other-user, short-lived). `setcap`, no full root.

## M3 — Enrichment + the risk/impact engine
- Passive DNS + TLS SNI/QUIC; offline GeoIP/ASN MMDB; **nDPI** classification; service
  fingerprinting; the transparent **impact/confidence scoring** (DESIGN-LANGUAGE.md).

## M4 — The two expressions + the design language
- **Terminal** (libvaxis, kitty-graphics logos) **and GTK** (GTK4 + zig-gobject), both over
  `libcartograph`. The **orbit→region** zoom; colors/icons/**risk rings**; lens toggling
  & profiles. X11+Wayland native by construction.

## M5 — Deep capture (T2) + dissection
- On-demand full-payload AF_PACKET tap per flow; `.pcap` export; **tshark** interop;
  **street→ground** zoom (packet timeline → hex/field tree).

## M6 — Enforcement: observe-first blocking (you asked for this)
- XDP **allow / block / throttle** by app/host/flow; rules as visible, undoable map objects;
  `--dry-run`/`--explain`. Little-Snitch-on-Linux, but visual.

## M7 — Identity, GPU map & ambient
- Local app icons (XDG/.desktop) + remote logo/brand pack + favicon cache + category glyphs.
- **GPU**: Vulkan-compute force-directed layout (RADV) for a smooth large map; **ambient
  "aquarium" mode**.

## M8 — The "Why" narrative, local-LLM & cross-resource fusion
- Plain-language flow narration; **ollama** offline "explain / is this normal?"; the
  **daily postcard**; the **Resource lens** correlating net ↔ CPU/GPU/RAM/energy.

## M9 — Packaging, man pages & polish
- Portable CO-RE surveyor binary (multi-distro); `.deb`; systemd unit; ship `cartograph(1)`
  + per-verb man pages (drafted); first-run "doctor".

## Later / the bigger arc
- Wayland layer-shell ambient overlay; **time-travel replay (DVR)**; **attack-surface mirror**;
  user-defined/extensible lenses; anomaly hints; the connection **passport**; and the
  extension of the same engine to memory/disk/power — the **operating system you can see.**
