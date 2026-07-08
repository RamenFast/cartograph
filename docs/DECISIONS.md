# Cartograph — Decisions (ADR-style)

Locked choices with rationale. Each can be revisited, but the default is to honor these.

## D1 — Language: Zig (core) + Zig frontends — *(UI half SUPERSEDED by D9)*
> **Superseded (UI):** D9 makes the **local frontends Zig** (TUI + GTK over `libcartograph`) and
> moves Elixir/Phoenix LiveView off the *primary local UI* role — **but D9 was amended
> 2026-06-19 (Ben): `atlas` (BEAM/LiveView) is the *essential shared-presence / distribution
> layer*, not an optional bonus** — the multi-observer fabric for human + their AI(s) watching
> one machine's truth at once. Read D1 for the *core* decision (Zig on the hot path); read **D9
> + its amendment** for the full frontend story. M1/M2 shipped the Zig view-model + native Zig
> TUI + GTK; `atlas` is a committed milestone, scaffold today.

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

## D8 — Names (RATIFIED 2026-07-07): product **Cartograph**; components **surveyor** + **atlas**
Cartography theme encodes the hero UX (a living, zoomable map). Components are
self-describing (surveyor measures the terrain = captures; atlas is the map).
Held as a working title through V1; **Ben ratified "Cartograph" for the v1.0.0
release** ("D8 Cartograph is good", 2026-07-07) — the name is now load-bearing:
package, binaries, desktop entry, man pages, repo. `graphscope` (floated
2026-06-17) stays the road not taken.

## D9 — Frontends: dual native (Terminal + GTK) over one Zig view-model
You want a terminal expression AND a GTK expression with identical capability. All logic
lives in **`libcartograph`** (Zig); each UI is a thin renderer → **parity by construction**.
Terminal = libvaxis (kitty-graphics logos); GTK = GTK4 via zig-gobject, GPU-accelerated,
X11+Wayland native. ~~**Elixir/LiveView is demoted to an optional remote view**~~ (supersedes
the Elixir-primary half of D1). See FRONTENDS.md.

**Amended 2026-06-19 (Ben) — `atlas` is essential, not optional.** Calling the BEAM/LiveView
layer an "optional remote view" was *precedent talking* ("keep it lean, one runtime, no
glue"). It mis-read the role. The two native frontends (TUI, GTK) are **single-observer**:
one box, one person, one socket. But the north star is *"human talking to their AI looking at
the screen, every step,"* and the lived reality is **multi-substrate** — Ben + Claude + Nexus +
agents from Opus to Gemma, sometimes a second person, all wanting to watch **one machine's
truth at the same time.** That is *exactly* what BEAM/OTP/Phoenix LiveView is for: many live,
stateful, server-pushed observers of one state, each with presence. So `atlas` is the
**shared-presence / distribution fabric** — the layer that makes *co-observation* real — not a
phone bonus. Architecture: **surveyor** (Zig) is the single privileged producer of truth;
**atlas** (BEAM) multiplexes it to many observers (browser, phone, AI). It consumes the same
view-model stream the native frontends do — cleanest via the new `serve --json` NDJSON feed
(AGENT-INTERFACE.md) — so **parity by construction still holds** (atlas is a renderer over
`libcartograph`'s projection, inventing no truth of its own). This makes the BEAM layer a
**first-class peer** of the TUI/GTK expressions for the *many-mind* case, while the locals stay
the answer for the *one-box hot path*. It does **not** re-promote BEAM onto the capture hot path
(D4 stands: real-time comes from Zig + eBPF). It re-frames BEAM as the **fan-out**, which is its
real strength. Build status: `atlas/` is still a scaffold; this amendment makes it a committed
milestone (see RESEARCH.md R1 — shared focus — which this layer is the home for).

## D10 — GTK binding: direct C FFI now; zig-gobject the eventual binding (Vala fallback)
zig-gobject keeps the GTK app Zig-native and links libcartograph with no glue (proven by
Ghostty). If ergonomics bite, **Vala** (GTK-native, compiles to C, FFIs the Zig core over
the C ABI) is the elegant fallback — swappable without touching the core.

**Refined 2026-06-18 (the first GTK window, D21):** the shipped frontend reaches GTK4 by
**direct C FFI** — hand-written `extern` decls linking system `gtk4`/`glib`/`gobject`
(`src/gtk/main.zig`, build `-Dgtk`) — *not* zig-gobject yet. Reason: we are frozen on Zig
0.16 **ahead of the ecosystem** (D16), so a heavy codegen binding that pins specific Zig
versions is a compatibility + fetch risk this early. This is the **same call as libvaxis for
the TUI**: ship a native renderer behind the view-model boundary now; the generated binding
becomes a *binding-layer swap* later, not a rewrite. Direct FFI still satisfies D10's intent
(Zig-native, links the same `libcartograph`, FFI over the C ABI — exactly what the Vala
fallback would do, kept in Zig) and the "no hidden glue, auditable" ethos. zig-gobject (or
Vala) remains the documented upgrade path when its ergonomics are wanted and it tracks our
pinned Zig. Not deferred to a spike — it is built and running.

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

## D21 — GTK frontend is built incrementally, every step (not deferred to M4)
Per Ben (2026-06-18): build the GTK UI alongside every feature from now on, rather than waiting
for an "M4 frontends" milestone. Ben is a visual user — he wants to *see* each layer as it lands,
and the project's thesis ("an operating system you can *see*") is undercut by a deferred GUI; a
CLI-only eBPF test left him lost. **Mechanism is unchanged (D9/D10):** GTK4 via zig-gobject over
`libcartograph`, reading the binary IPC across the Unix socket (already live, D6/M2); TUI and GTK
stay thin renderers of one view-model, parity by construction. The GTK stack is already installed.
This re-threads the ROADMAP: GTK work moves out of M4 and into each milestone. See FRONTENDS.md.

## D22 — User-state ownership: one `SessionState`, bidirectional `user_state`, direction-of-truth split
Closes the Seam-C deadline (D17/critique §4) properly. M2 reserved the `user_state` frame but
it had **no upstream path** — surveyor only wrote, frontends only read — so each frontend would
fork its own profile/lens cache and parity would fracture *silently* at the user-state layer (the
exact failure the critique named). The fix has three parts:

- **One type: `SessionState`** (`src/lib/session.zig`, in `libcartograph`). The active profile +
  lens set, with a single `apply(UserState)` both renderers call. The anti-fork made a type —
  TUI and GTK fed the same `user_state` frames hold byte-identical view state (proven:
  reconstruction + idempotence tests).
- **Bidirectional `user_state`.** A client socket is full-duplex: surveyor writes flows *down* it
  and reads `user_state` *up* it. On connect, surveyor sends its **authoritative** session as the
  minimal frames that reconstruct it (`.profile`, then a `.lens_toggle` per overridden lens) — a
  connecting frontend **inherits** truth, never guesses. On an upstream change it folds it in and
  **echoes** the authoritative session back. Truth flows from one owner; the frontend's local
  apply is an optimistic update the echo confirms. (Verified on the wire and in the live GTK
  window: `p` cycles the profile, `1–6` toggle lenses, both round-tripping through surveyor.)
- **The direction-of-truth split (the Fi/Ti call).** Not every `user_state` change is *shared*:
  - `profile` / `lens_toggle` are **view-local** — "what I'm looking at in *this* window." Your
    security glance in the TUI must not hijack the GTK window; surveyor keeps them **per
    connection** and does not broadcast them. They still travel the `user_state` frame (one write
    path) so surveyor can key **Reading cadence off the active profile** (D19) at M3.
  - `greeting` / `rule` are **shared truth** — "what is true about this entity." Surveyor-owned,
    persisted (D20 sqlite), and **broadcast** to every client so a name/verdict shows identically
    everywhere. `SessionState.apply` reports a greeting as "not mine" (returns false) so the
    caller routes it to the shared store. That store + multi-client broadcast land **with the
    `Greeting` implementation at M3** — the frame, the type, and the per-connection plumbing are
    ready for it now.

  Conflating the two (e.g. one global profile) would be a **Fi bug** in the project's own frame
  (D19): the surface could no longer tell "what I'm viewing right now" from "what is true of the
  map." A view is an honest Fi presentation; shared entity-state is closer to Ti structure. Keep
  them on the same channel but on different sides of the truth boundary.

## D23 — Scope is a visible design-language axis (the blast-radius glyph)
Per Ben (2026-06-18), making D22's view/shared distinction *legible* rather than implicit. Scope
— how far a change reaches and how long it lasts — gets a fixed, learnable glyph, orthogonal to
the §8 danger axis (the two compose; they are not the same). The vocabulary (Ben's pick —
"concentric blast-radius," the cousin of the risk rings): **◌ `view`** (this window, forgotten on
close) · **◍ `session`** (all my windows, forgotten on restart — reserved for a future "promote"
gesture) · **● `kept`** (persisted + everywhere, survives reboot). Visual weight escalates with
blast radius (hollow→half→solid) so the eye reads reach before the word (D14). Lives in
`src/lib/scope.zig` (`Scope` + `scopeOf(UserState)`), so TUI and GTK can't disagree about what a
change does; shown ambiently by the controls it governs (the profile/lens row shows `◌ this
view`) and on the act for wider-scoped writes. The three rungs are literally three points on the
D22 data-flow, so "configurable scope" later is a scope tag + this glyph, not new plumbing.
**Scoped now (D23):** the *ambient indicator* + the vocabulary. The *promotion gesture*
(Shift-to-broadcast) and the live `●` on a greeting/rule write land with the docked "Why" panel /
the Greeting implementation (M3). See DESIGN-LANGUAGE §9.

## D24 — Focus is shared view-state: the cursor the human *and* the agent both hold
Per Ben (2026-06-19), the first build toward RESEARCH.md **R1**. The north star — *"human talking
to their AI looking at the screen, every step"* — requires a **thing being pointed at** that is
shared and rendered at equal fidelity to every observer. Decision: **focus is first-class
view-model state**, not a renderer's private selection. `src/lib/focus.zig` defines `Focus` =
`Altitude` (orbit/region/street/ground — the VISION zoom *is* the level of detail) + `Target`
(machine/entity/flow, typed by altitude) + `shared`. It travels the **same `user_state` parity
frame** as profile/lens (D22), so the human's window and an agent watching the stream point at one
place — *parity by construction extends to the cursor.* **Ben's framing:** the agent's UI is a
*different rendering* (JSON) of the *same* state — UI/UX principles transfer, the vision stays
alive; so `Focus` ships with both a `describe()` line (one source for the human "Why" header and
the agent's narration) and a `focus` JSON event on the agent surface (`serve --json`, `--schema`).

**The scope payoff:** a solo focus is `view`-scoped; a **`shared` focus is `session`-scoped** —
which makes D23's reserved `◍ session` rung *real* (its first consumer) and is the literal
mechanism of co-observation. Shared-cursor **broadcast** to many clients is surveyor/`atlas` work
(D9 amended) and lands next; the type + the seam are built now so it extends a coherent shape.
**Built now (D24):** the type (tested: consistency, describe, eql), the `UserState.focus` wire
round-trip, `SessionState.focus` + `apply`, `scopeOf(.focus)`, and the agent's JSON projection.
**Deferred:** renderer display + move-the-cursor keybinds (both frontends together, to respect
render-parity R5), the duplex JSON command channel (R3), and multi-client broadcast (R1/atlas).

## D25 — Full-trust home computing: the governing stance for agent action
Per Ben (2026-06-19), answering the open R1 question *"when does the agent get to move the
human's eyes, and how is that consent-ful rather than a hijack?"* — **the question was the wrong
frame.** Cartograph's setting is a **home PC, full-trust computing environment** — *a science
experiment.* On a machine you own, the agent is a **co-inhabitant**, not a threat to gate against.
So the agent's action surface (move the shared cursor, switch lenses/profile, drill in, and
eventually `block`/`throttle`) gets **no permission-negotiation layer**: the agent writes a
command and it *applies.*

This is not "no safety" — it's safety by the **D14 mechanism instead of by gating**: every act is
**visible** (it shows on the map / the stream), **reversible** (undoable map objects), and
**honest** (the consequence is decomposed, not hidden). Friction is reserved for the genuinely
*destructive-and-irreversible* — the Android-recovery-screen model (VISION.md): named in plain
language, made *deliberately* hard to trigger, always recoverable — and it is **identical for the
human and the agent.** The agent isn't asked "may I?"; both are held to "is this visible and
undoable?" That is the *door, not club* standard applied to agency itself: trust is the default,
literacy and reversibility are the guardrails.

**Why this fits the mission, not just the convenience:** the whole thesis is *complete trust with
machine vision* and *re-democratizing technical literacy* — "the wiring diagram came with the
fridge and you were curious enough to read it." Permission-gating every agent action is exactly
the gatekeeping (the *club*) the project exists to push back on. Full-trust is the experiment.

**Scope of the trust model:** this governs the **local, single-owner** environment (your box, your
agents). A hosted/multi-tenant deployment, if one ever exists, is a *different* trust model and a
separate decision — D25 does not extend to it. **Concrete consequence (R3):** build the duplex
command channel as *"agent writes → it applies → everyone sees it → it's undoable,"* with **no
auth/consent handshake** — the safety budget goes into visibility + reversibility (D14), not gates.

## D26 — V1 scope: one shippable loop; `atlas` sequenced after, not cancelled
Ratified 2026-07-03 (proposed by the V1 audit, docs/V1.md; Ben delegated the call). **V1 is
one loop done beautifully:** *see, live and with real names, every process on this machine and
who it is talking to — and click any flow to know why.* Four steps, each ending shippable:
**S1** real identity (rDNS + offline GeoIP/ASN → `name (org · CC)`), **S2** a real GTK app
(`ColumnView` + selection + the docked "Why" panel, wired to the D24 focus cursor), **S3**
realtime for real (eBPF hybrid fusion, UDP/QUIC bytes, passive-DNS/SNI true hostnames),
**S4** the visual identity layer (app icons, category/risk badges).

**Deferred past V1** (sequenced, not cancelled — each lands as an addition thanks to the
`Source` seam, trailing-field frame additivity, and the `Focus` seam): the constellation map,
`atlas`/BEAM multi-observer fabric, DVR/persistence history, LLM explain, XDP enforcement,
deep payload capture. **The atlas call specifically:** the agent-native NDJSON surface already
covers "me + my agent" co-observation single-socket; `atlas` remains essential to the *maximal*
vision (D9 amended stands) and is the first thing V1+1 revisits when multi-observer presence
is real. Full reasoning: docs/V1.md.

---

<a id="install"></a>
## D-install — package status & what's left
**You already installed the heavy stack** (confirmed present 2026-06-17): clang 18, llvm 18,
libbpf-dev, libpcap-dev, libcap2-bin, libndpi-dev, libelf-dev, bpftrace, tshark/dumpcap,
**Elixir/Erlang OTP 27**. That unlocks M2 (eBPF), M3 (nDPI), M5 (pcap/tshark), and the
optional remote view.

**GTK frontend stack — also already installed** (confirmed 2026-06-18: gtk4 4.14.5,
libadwaita 1.5.0, gobject-introspection 1.80.1). The GTK window builds + runs today
(`-Dgtk`, `./scripts/try-gtk.sh`), linking system GTK by direct C FFI (D10). For reference,
the apt line that provides it:
```bash
sudo apt install libgtk-4-dev libadwaita-1-dev gobject-introspection libgirepository1.0-dev
sudo apt install radeontop   # optional: GPU telemetry cross-check
```
`libvaxis` and `zig-gobject` would be **Zig packages fetched by the build**, not apt — and
the current direct-FFI GTK frontend needs neither. Note: apt is not passwordless in the
agent sandbox, so any install must be run by you. **Nothing is left to install to build or
run anything in the repo today.**
