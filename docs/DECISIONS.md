# Cartograph — Decisions (ADR-style)

Locked choices with rationale. Each can be revisited, but the default is to honor these.

## D1 — Language: Zig (core) + Zig frontends — *(UI half SUPERSEDED by D9)*
> **Superseded (UI):** D9 makes the **frontends Zig** (TUI + GTK over `libcartograph`) and
> demotes Elixir/Phoenix LiveView to an **optional remote view**. Read D1 for the *core*
> decision (Zig on the hot path); read **D9** for the frontend decision. M1 shipped the
> Zig view-model + a native Zig TUI; no Elixir is in the build.

Esoteric *and* optimal. The app is a zero-GC privileged hot path (Zig) + a soft-real-time
many-entity live UI. The privilege boundary maps onto a clean producer/consumer seam.
Full analysis in STACK.md §4.
- **Single-language fallback** chosen in practice: **Zig everywhere** (the view-model lives
  in `libcartograph`; each frontend is a thin Zig renderer). Elixir-everywhere (+ a Zig
  capture NIF) remains a theoretical alt; not chosen.

## D2 — Capture: eBPF/XDP, tiered; libpcap only for deep-capture export
eBPF gives in-kernel counting + reliable per-PID attribution at near-zero overhead and is
how modern live monitors work. Tiering (T0 always-on cheap / T2 deep on-demand) is what
makes Cartograph both a featherweight monitor and a deep analyzer. libpcap/AF_PACKET is
used only for the on-demand full-payload tap + `.pcap` export (Wireshark interop). We do
**not** build on Wireshark's engine — we interop with `tshark` for the protocol long tail.

## D3 — Kernel recompile: NOT required  ⟵ (answers your question directly)
You offered to recompile for better features "if no perf cost." **Don't — it buys us
nothing here and costs portability.** Verified on this machine:
- `/sys/kernel/btf/vmlinux` is present (6.9 MB) → **CO-RE works**, so eBPF programs are
  portable and need no per-kernel recompiles.
- Kernel **6.17** already enables every feature we use: BPF ring buffer, kprobes/tracepoints,
  fentry/fexit, XDP, BPF CO-RE, `CAP_BPF`/`CAP_PERFMON`. Stock Ubuntu/Mint configs ship
  these on.
- A custom kernel would mean Cartograph only runs on *your* kernel, defeating the goal of
  a portable single binary, and adds maintenance with **zero capability gain**.
- The only thing worth a tweak is *runtime*, not a rebuild: prefer file **capabilities**
  (`setcap`) over root; optionally `sysctl kernel.unprivileged_bpf_disabled` stays as-is
  (we use caps, not unprivileged BPF). Revisit a custom kernel only if we ever chase
  exotic XDP offload — not on the roadmap.

## D4 — No Python / no scripting glue in the product; lean binary IPC
Per your steer. The product is native end-to-end. Surveyor↔atlas uses a length-prefixed
binary frame protocol over a Unix socket (packed structs/CBOR), decoded by BEAM's native
binary pattern-matching — no JSON/HTTP tax on the hot event stream. (Any Python you saw
was one-off bootstrap to parse Zig's release JSON; it is not part of Cartograph.)

## D5 — GeoIP/ASN data: offline, redistributable MMDB
Prefer an open-licensed, daily-updated source (IPLocate / DB-IP / IPinfo Lite) over
MaxMind GeoLite2 (lower quality, license signup). Bundled/downloaded once, queried
offline — no per-connection network calls. (STACK.md §2, sources.)

## D6 — Privilege model: split daemon + capabilities, never root UI
`surveyor` gets `cap_bpf,cap_perfmon,cap_net_raw,cap_net_admin+ep`; `atlas` runs as the
user. Limits blast radius and keeps the GUI unprivileged.

## D7 — Explanations: local-first LLM (ollama already installed), cloud opt-in
The "Why / explain this flow" feature uses the on-box `ollama` model by default → offline,
private, no traffic leak. A cloud model (e.g. Claude API) is strictly opt-in later.

## D8 — Names (working): product **Cartograph**; components **surveyor** + **atlas**
Cartography theme encodes the hero UX (a living, zoomable map). Components are
self-describing (surveyor measures the terrain = captures; atlas is the map). All
provisional — rename freely.

## D9 — Frontends: dual native (Terminal + GTK) over one Zig view-model
You want a terminal expression AND a GTK expression with identical capability. All logic
lives in **`libcartograph`** (Zig); each UI is a thin renderer → **parity by construction**.
Terminal = libvaxis (kitty-graphics logos); GTK = GTK4 via zig-gobject, GPU-accelerated,
X11+Wayland native. **Elixir/LiveView is demoted to an optional remote view** (supersedes
the Elixir-primary half of D1). See FRONTENDS.md.

## D10 — GTK binding: zig-gobject (Vala fallback)
zig-gobject keeps the GTK app Zig-native and links libcartograph with no glue (proven by
Ghostty). If ergonomics bite, **Vala** (GTK-native, compiles to C, FFIs the Zig core over
the C ABI) is the elegant fallback — swappable without touching the core. Spike early in M4.

## D11 — Active blocking is in scope (XDP), observe-first
Per "definitely want both": allow/block/throttle by app/host/flow via XDP; rules are
visible, undoable map objects; explicit + `--dry-run` gated; needs `cap_net_admin`. (M6)

## D12 — X11 + Wayland from day one
GTK4 is natively both; avoid Xlib; overlays via wlr-layer-shell + XDG portals behind one
runtime-selected trait keyed off `XDG_SESSION_TYPE`. Wayland = a config change, not a port.

## D13 — GPU: GTK/GSK + Vulkan canvas render · RADV compute · telemetry now · no ROCm
Use the Radeon for rendering (GSK Vulkan free; custom Vulkan canvas for the big map),
compute graph layout (Vulkan/RADV, CPU fallback first), and telemetry (proven). ROCm not
required. All GPU use opt-in/auto-detected with CPU fallback. See GPU.md.

## D14 — Visual semantics are data, never decoration
Fixed color meanings + glyphs + dual **confidence/impact rings**; every score decomposable
and explainable; colorblind-safe (never color alone). See DESIGN-LANGUAGE.md.

## D15 — "Bloom" CLI/UX: verbs not flags, zero-friction start, real man pages
No required flags; verbs read like intent; progressive disclosure; ship genuine man pages
(`cartograph(1)` drafted, renders clean). See CLI.md.

## D16 — Toolchain: freeze on vendored Zig 0.16.0; follow the stable channel
We are on 0.16 ahead of the ecosystem. Pin `toolchain/zig` at the vendored 0.16.0; adopt 0.17+
only when deps (libvaxis, zig-gobject) track it, on a deliberate branch, never mid-milestone.
Patch upstream deps in-tree and record patches. Living on 0.16 for a year is acceptable — the
std surface we use is small. Full notes + the churn list: TOOLCHAIN.md. (Critique v3 §5.6.)

## D18 — Agent-native by construction: a real Unix program, no AI left out
Per Ben (2026-06-17): Cartograph must be drivable by **any** agent through plain bash — and by
any kid with `jq` — as a first-class surface, not an afterthought. **The agent and the kid are
the same user.** Concretely: structured **NDJSON** output (`--json`, one flow per line, stable
field names, numbers as numbers, `pid:0`=unattributed), the Unix `isatty` rule (pretty at a
TTY, structured in a pipe), parseable `--help` + a planned `--schema`, meaningful exit codes,
and **no SDK / no glyphs / no special integration** (substrate-neutral — the HCL-portable
principle from Fi/Ti debugging, applied to the interface). Each surface (table / NDJSON / binary
IPC) is a renderer over `libcartograph`, so the agent surface can't drift from the UI — *the
surface doesn't lie.* First slice shipped: `surveyor snapshot --json`. Full contract:
AGENT-INTERFACE.md.

## D17 — Adopt an act ontology as the design frame (types ratify per-milestone)
Per Nexus critique v3 §2/§8: the repo has data-nouns but no **act-nouns**. We adopt a three-
category frame — **data / state / act** — with provisional types `Greeting` (data, M3),
`Rule` (state, M6), `Reading` + `Ruling` (act, M8). Categories are load-bearing; names are
provisional and each type must pass the **type test** (carries state existing types can't)
before it ships. IPC `FrameType` is non-exhaustive, so `user_state`/`rule`/`reading`/`ruling`
frames are reserved now and added additively — `user_state` **before** the M4 GTK spike to
prevent a silent parity fracture. See ONTOLOGY.md + STATE.md.

## D19 — Act ontology ratified (2026-06-18): names kept, `Greeting` is its own type
Resolves D17's open questions. Ben decided names + the `Greeting` type test + `Reading`
cadence; the maintainer decided `EntityKey` granularity (Ben deferred). The frame is Fi/Ti
(`~/.hermes/skills/fi-ti-debugging`): Cartograph is an **accurate Fi presentation of the
network's Ti structure**, so a type is either Ti structure or an honest Fi layer over it,
never both conflated.
- **Names kept:** `Greeting / Rule / Reading / Ruling` (categories data/state/act stand).
- **`Greeting` ≠ `Identity` (passes the type test).** `Identity` = the entity's *Ti structure*
  (objective, derived enrichment). `Greeting` = the *Fi layer the user authors* over it
  (`label`, `unseen/greeted/ignored`, `user_note`, `greeted_at_ms`, trust). It carries user
  provenance + a survives-reboot lifetime + a privacy contract that `Identity` can't.
  Merging them is a Fi bug (can't tell "what the net says" from "what I named"). `flow.fresh`
  keeps its M1 "first-seen-this-run" meaning; "amber until greeted" is computed from the
  `Greeting` at M3, not baked into `Flow`.
- **`EntityKey` is a tagged union** `union(enum){ host, app, asn }` — a target's kind is
  explicit, never flattened.
- **`Reading` cadence is dual-mode**, keyed off the active profile: threshold-cross by default
  (calm), every-rescore opt-in (security/resource, or `--readings=all`). Cadence rides the
  existing lens/profile, not a new global flag.

## D20 — Persistence: one sqlite DB; append-only act log + mutable state tables
Resolves STATE.md's "format (proposed)". A **single on-disk sqlite database** is the backend.
State slots (`greetings`, `rules`) are **mutable** tables; act-log slots (`readings`,
`rulings`, history/DVR) are **append-only** (insert + retention-windowed prune from the tail,
never edit) — an editable audit trail would lie about what the system did (a Fi bug). One
backend, not two formats, keeps the storage guarantees consistent (a Ti win). sqlite is a C
lib via trivial Zig FFI, in the same family as the already-accepted libbpf/nDPI/MMDB deps;
the M1 "0 runtime deps" purity is an M1 property, not a forever constraint. *Escape hatch:* if
a dependency-free surveyor is later judged worth more than SQL queryability, the append-only
act log can fall back to a flat on-disk log — but the contract (mutable state / immutable acts)
holds either way. Implementation is incremental (STATE.md "until built, it's in-memory");
the contract lands at M2. *(Maintainer's call — Ben deferred the backend choice.)*

---

<a id="install"></a>
## D-install — package status & what's left
**You already installed the heavy stack** (confirmed present 2026-06-17): clang 18, llvm 18,
libbpf-dev, libpcap-dev, libcap2-bin, libndpi-dev, libelf-dev, bpftrace, tshark/dumpcap,
**Elixir/Erlang OTP 27**. That unlocks M2 (eBPF), M3 (nDPI), M5 (pcap/tshark), and the
optional remote view.

**Remaining — only the GTK frontend stack (for M4):**
```bash
sudo apt install libgtk-4-dev libadwaita-1-dev gobject-introspection libgirepository1.0-dev
sudo apt install radeontop   # optional: GPU telemetry cross-check
```
`libvaxis` and `zig-gobject` are **Zig packages fetched by the build**, not apt. Note: apt
is not passwordless in the agent sandbox, so these must be run by you.
