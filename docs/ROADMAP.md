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
- ✅ **Agent/Unix surface** (D18): `surveyor snapshot --json` emits NDJSON (one flow per line,
  stable schema) — `… --json | jq` is the kid tinkering *and* the agent reasoning, same pipe.
- *Demo (real):* `zig build run` — past `nethogs` already (per-flow bytes **and** RTT
  **and** category **and** v6 **and** sparklines).
- **libvaxis deferred, deliberately.** It targets Zig 0.15.1; on 0.16's reworked I/O it
  needs non-trivial patching, and its headline win (kitty-graphics logos) isn't needed
  until M4/M7. We shipped a native renderer behind the same view-model, so libvaxis
  becomes a drop-in *render backend* swap when logos land — no architectural debt.
- **Known limitations (M1 release notes):** UDP is enumerated but loose (sockets, no byte
  counters — inet_diag has no UDP throughput); capture-layer (`diag`/`proc`) is validated by
  live runs, not unit tests yet (M2 adds a netlink mock + golden-frame test). Per Nexus
  critique v3 §5.8/§5.2 — scoped-down honestly, not a M2 surprise.

> **Threaded through M2–M8 (from Nexus critique v3):** the **act ontology**
> ([ONTOLOGY.md](ONTOLOGY.md)) and the **persistence/privacy contract** ([STATE.md](STATE.md))
> are designed up front so M3 (scoring), M6 (blocking), and M8 (narration) stay coherent.
>
> **Agent-native surface (D18, [AGENT-INTERFACE.md](AGENT-INTERFACE.md)):** every verb is a real
> Unix program — NDJSON in a pipe, pretty at a TTY, no AI left out. First slice shipped in M1
> (`surveyor snapshot --json`); `serve --json` event stream + `--schema` + isatty-auto follow.
> When enforcement lands (M6), `block`/`allow` return a JSON `Ruling` so an agent acts *and reads
> back what it did*.

## M2 — eBPF capture + attribution (privileged core)  ✅ (this session; eBPF attach verified 2026-06-18)
- ✅ **eBPF source** on the TCP state machine (`tp_btf/inet_sock_set_state`, CO-RE) → BPF
  ring buffer → Zig (libbpf via FFI). Built with `-Dbpf=true`; swapped behind the existing
  `Source`/`Observation` seam so the `FlowTable` and frontends don't change. **Verified: loads +
  attaches under `setcap` on kernel 6.17** (`scripts/try-ebpf.sh`), with a loud, honest fallback
  to inet_diag when caps are absent.
  - ⚠️ **Known: eBPF is an event *augmenter*, not a standalone source.** The hook fires on TCP
    state *transitions*, so it sees *new/short-lived* activity, not the *existing* socket table
    (a `snapshot --bpf` shows 0 rows in an idle instant). The production design is **hybrid:
    inet_diag for the baseline table + byte counters, eBPF for births/deaths/attribution, fused** —
    the **top M3 capture task** (and eBPF carries no byte counters yet; bytes stay on inet_diag).
- ✅ **Test discipline (critique §5.1/§5.2):** netlink mock + **golden-frame decode tests**
  (capture correctness asserted, not "validated by live runs"); the **in-process ↔ IPC parity
  property** landed *before* the socket went live; eBPF event decode tested root-free.
- ✅ **Privilege boundary stood up:** surveyor serves over a **Unix socket** (`serve --socket`),
  the unprivileged frontend connects (`--ipc --socket`) — same codec, proven byte-identical.
- ✅ **Act ontology + reserved IPC frames** (ONTOLOGY.md, D19); **persistence & privacy
  contract** committed (STATE.md, D20). **Unattributed-`?`-flow handling answered in
  `libcartograph`** (`service`/`exposure`, sshd/cups/resolved/nginx legible) — not a renderer
  detail (critique §5.3).

## M3 — Hybrid capture + enrichment + the risk/impact engine
- **Hybrid capture fusion (first):** make the `.bpf` source = inet_diag (baseline table + byte
  counters) **+** eBPF events (births/deaths/short-lived/attribution), fused — so eBPF *adds* to
  the live table instead of replacing it. This is what makes `--bpf` actually show the `?` rows
  closed in the normal view (M2 left it either/or).
- Passive DNS + TLS SNI/QUIC; offline GeoIP/ASN MMDB; **nDPI** classification; service
  fingerprinting; the transparent **impact/confidence scoring** (DESIGN-LANGUAGE.md).
- **`Greeting` lands here** (the persistence seam made type), after passing the type test;
  scoring emits **`Reading`s**. **Every M1 in-process test gains an IPC twin** so the parity
  claim survives the renderer swap (critique §5.2/§6).
- **GTK (D21):** a minimal GTK4 window over the IPC socket ships *now* and grows with each of the
  above — the visual surface is built incrementally, not deferred. See M4/FRONTENDS.md.

## M4 — The two expressions + the design language  *(GTK now starts in M3, D21 — this milestone is where it matures)*
- **Terminal** (libvaxis, kitty-graphics logos) **and GTK** (GTK4 + zig-gobject), both over
  `libcartograph`. The **orbit→region** zoom; colors/icons/**risk rings**; lens toggling
  & profiles. X11+Wayland native by construction.
- **`user_state` IPC frame ships *before* the GTK spike** (Greeting writes + profile/lens
  toggles), so GTK and TUI share one source of truth instead of forking a state cache
  (critique §4 Seam C / §5).

## M5 — Deep capture (T2) + dissection
- On-demand full-payload AF_PACKET tap per flow; `.pcap` export; **tshark** interop;
  **street→ground** zoom (packet timeline → hex/field tree).

## M6 — Enforcement: observe-first blocking (you asked for this)
- XDP **allow / block / throttle** by app/host/flow; rules as visible, undoable map objects;
  `--dry-run`/`--explain`. Little-Snitch-on-Linux, but visual.
- **`Rule` type lands here** (operates on flows; `source` distinguishes user vs postcard vs
  default). The `.ignored` Greeting visual + Rule visuals are designed **together** here, not
  as a M7 afterthought (critique §3). Rules must reload + **re-arm XDP on boot** (STATE.md).

## M7 — Identity, GPU map & ambient
- Local app icons (XDG/.desktop) + remote logo/brand pack + favicon cache + category glyphs.
- **GPU**: Vulkan-compute force-directed layout (RADV) for a smooth large map; **ambient
  "aquarium" mode**.

## M8 — The "Why" narrative, local-LLM & cross-resource fusion
- Plain-language flow narration; **ollama** offline "explain / is this normal?"; the
  **daily postcard**; the **Resource lens** correlating net ↔ CPU/GPU/RAM/energy.
- **`Reading` + `Ruling` types** drive the narrative + postcard. Two LLM surfaces, two
  contracts: the *live "explain this flow"* verb is the local model's voice; the *postcard
  template is the user's voice* (`postcard --profile ben`) — don't conflate (critique §3/§4).
  The model sees a **whitelist**, never raw flow (STATE.md privacy posture).

## M9 — Packaging, man pages & polish
- Portable CO-RE surveyor binary (multi-distro); `.deb`; systemd unit; ship `cartograph(1)`
  + per-verb man pages (drafted); first-run "doctor".

## Later / the bigger arc
- Wayland layer-shell ambient overlay; **time-travel replay (DVR)**; **attack-surface mirror**;
  user-defined/extensible lenses; anomaly hints; the connection **passport**; and the
  extension of the same engine to memory/disk/power — the **operating system you can see.**
