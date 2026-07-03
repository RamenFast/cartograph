# Cartograph — next session (start here)

> Updated 2026-06-19 (the teardown + agent-surface + R1 session). New here? Read [docs/README.md](README.md)
> (the index + status map) first, then this. Everything below builds + tests green:
> **`zig build test` = 50, `-Dbpf=true` = 54.**

## ⭐ NEXT SESSION STARTS HERE — finish R1 (the shared cursor)

The `Focus` **seam is built** this session (D24, `src/lib/focus.zig`): the cursor is first-class
view-model state on the `user_state` parity frame, with an equal-fidelity JSON projection for
agents (`focus` event on `serve --json`, in `--schema`). What remains is three concrete builds,
in this order — each is a clean, scoped starting point:

1. **Renderer wiring — both frontends in one step (don't split, or you re-break render-parity R5).**
   TUI + GTK: display the active cursor (the `Focus.describe()` line in the header, next to the
   profile/lens row) and let the user *move* it — keys for altitude (zoom in/out) and selecting a
   row → `SessionState.setFocus` → send `user_state{focus}` upstream (the path profile/lens already
   use). This is the "GTK every step" task (D21) and it makes the cursor visible.
2. **Duplex JSON command channel (R3) — let the agent *move* the cursor, not just read it.** Today
   `serve --json` is read-only (one-way pipe). Add an upstream NDJSON command on the socket
   (`serve --json --socket`): the agent writes a line like `{"cmd":"focus","altitude":"region",
   "target":"entity","entity_kind":"asn","entity":"13335"}`, surveyor parses it to a `UserState`
   and applies it. This is the first agent *write* verb — wire it generically so `set-profile` /
   `lens` come free, and so the act ontology's `Ruling` has its first consumer. **No auth/consent
   handshake** (D25 — full-trust home environment): the agent writes, it applies, everyone sees it,
   it's undoable. The safety budget goes into visibility + reversibility (D14), not gates.
3. **Multi-client broadcast (R1 / atlas) — make a `shared` cursor actually shared.** Surveyor today
   serves one client at a time (`serveSocket` accepts then blocks in `streamLoop`). For a `shared`
   focus to reach every observer, surveyor needs a client registry + fan-out. This is where the
   **`atlas` BEAM layer** earns its keep (D9 amended — essential, not optional): the natural home
   for many-observer presence. Start small (a Zig multi-client accept loop broadcasting
   session-scoped `user_state`), then let `atlas` own the fan-out + presence.

`scopeOf(.focus)` already returns `session` when `shared` — so the design is settled; these are
builds, not decisions. See [RESEARCH.md](RESEARCH.md) R1/R3 and DECISIONS **D24**.

## What this session (2026-06-19) did
- **A full critique-and-improve pass** (Ben's `/goal`). Audited code + docs with two agents,
  fact-checked claims, then **shipped 9 fixes** — see "Critique-response patches" below.
- **The agent interface went from read-only/poll-only to a live, self-describing watch surface:**
  `serve --json` (NDJSON event stream — the text twin of the binary IPC, so an agent watches the
  same live view-model the GUI renders), `--schema` (the self-describing contract, generated from
  the enums so it can't drift), and **isatty** auto-NDJSON on a pipe. (AGENT-INTERFACE.md.)
- **R1 shared-focus seam built** (D24, above).
- **`atlas` reframed essential** (D9 amended, per Ben): the BEAM/LiveView **shared-presence /
  distribution layer** — the multi-observer fabric for human + their AI(s) watching one machine at
  once — is *not* an optional remote view. It is the home of R1's broadcast half.
- **Fixed a real eBPF bug** (closed flows never evicted from the table — leak + producer-side
  parity break) and added the regression test.
- **Honesty re-baseline:** the four mutually-inconsistent test counts → the truth (50/54); the
  spike perf numbers relabeled as the spike's; stale path + zero-dep caveats fixed.

## Where we are
- **User-state ownership landed (2026-06-18, D22).** The `user_state` frame is now
  **bidirectional and owned**: one `SessionState` (`src/lib/session.zig`) in `libcartograph`,
  surveyor sends its authoritative session on connect (a frontend *inherits* it) and echoes
  upstream changes — no private cache, no silent fork (the critique §4 "Seam C" deadline, paid
  early). **Direction-of-truth split:** `profile`/`lens_toggle` are view-local (per connection;
  ride the frame so surveyor can key Reading cadence off the profile at M3), `greeting`/`rule`
  are shared truth (surveyor-owned, persisted, broadcast — lands with `Greeting` at M3). Live in
  both frontends: GTK `p` cycles the profile, `1–6` toggle lenses, the layout reacts; TUI too.
  Verified three ways — wire bytes (hello→session→echo), unit tests (reconstruction/idempotence/
  round-trip), and the live GTK window driving + rendering surveyor's echo. Also landed
  **`ipc.FrameStream`**: the length-prefixed read-side reassembly was hand-rolled in three
  consumers (TUI/GTK/surveyor); it now has one owner in `ipc.zig` (the write side already did),
  with an oversized-frame guard. *(Test count at that point was 41/44; it is **50/54** now — see top.)*
- **The first GTK window shipped** (2026-06-18, D21). `src/gtk/main.zig` (build `-Dgtk`,
  launch `./scripts/try-gtk.sh`) opens a live attributed-flow window over the
  `surveyor serve --socket` IPC: same binary frames, same `FlowTable`, same design-language
  palette as the TUI (`Category.hex()` = the truecolor twin of `Category.ansi()`) — parity by
  construction. GTK4 is reached by **direct C FFI** (D10 refined; the libvaxis precedent —
  zig-gobject is a later swap). **Verified live** on DISPLAY :0 (real flows, colors, glyphs,
  v6 endpoints, RTT). GTK now grows with every M3 capability instead of waiting for M4.
- **M2 built and on `main`** (2026-06-18). The eBPF capture source (CO-RE,
  `tp_btf/inet_sock_set_state`, `-Dbpf=true`) behind the `Source` seam; the Unix-socket
  privilege boundary; the act ontology (D19) + four IPC frames; the `?`-flow answer
  (`service`/`exposure`); and the full test discipline (golden frames, in-process↔IPC parity,
  eBPF decode). *(Test count at that point was 32/35; **50/54** now.)* **eBPF live-attach VERIFIED**
  2026-06-18 (Ben ran `scripts/try-ebpf.sh` — caps stuck, program loaded, no fallback). Caveat:
  eBPF as-built is an event *augmenter* (sees state transitions, not the existing table), so the
  M3 hybrid fusion is what makes it useful in the normal view. See ROADMAP M2/M3.
- **M1 shipped** (prior session): `libcartograph` view-model, the inet_diag/proc capture core,
  the live TUI in-process *or* over the binary IPC.
- **Nexus critique v3 reviewed and acted on** (this session). The critique is excellent and
  its findings align with M1's self-flagged soft spots. Full text:
  `~/Nexus/archive/🏮Nexus/2026-06-17/cartograph-critique-v3.md`.

## What the critique-response patched this session ✅
- **tcp_info robustness** (`diag.zig`): per-field length guards — decode RTT / bytes_acked /
  bytes_received only if the kernel actually reported that far. No fixed-size assumption.
- **Intentional-polling marker** (`capture.zig`): explicit "don't add a cache; eBPF obsoletes
  it (M2)" note, so nobody optimizes the wrong layer.
- **Doc re-baseline** (the "inherited lie" risk): ARCHITECTURE diagram no longer puts Elixir
  on top; D1 marked superseded-by-D9; STACK retitled from *netscope* + BEAM-real-time claim
  corrected; PLANNING marked historical.
- **New contracts written:** ONTOLOGY.md (act ontology), STATE.md (persistence + privacy),
  TOOLCHAIN.md (0.16 churn + freeze plan), STRUCTURE.md (layout + collaborator conventions).
  New decisions: **D16** (toolchain freeze) + **D17** (adopt the act ontology frame).
- **Roadmap threaded:** act ontology / persistence / IPC frames / test discipline / `?`-flow
  handling slotted into M2–M8; M1 known-limitations (UDP loose, capture tests pending) noted.

## What is deliberately NOT done (and why)
- **The act-ontology *types* are not coded.** Per the third-reviewer's "test the type before
  you ship it," `Greeting/Rule/Reading/Ruling` are designed (ONTOLOGY.md) and ratify at their
  milestones — they are not stubbed in `src/` yet. Don't add them speculatively.
- **No new IPC frame variants yet.** Reserved by name in ONTOLOGY.md; `FrameType` is already
  non-exhaustive so adding them later is non-breaking. `user_state` is the one with a hard
  deadline: **before the M4 GTK spike.**
- **UDP throughput** stays a known limitation, not a half-fix.

## Next stage — grow the GTK UI with M3 (the first window is done, D21)
✅ **The minimal GTK window is built** (category color/glyph, fresh dot, endpoints, throughput,
totals, RTT — see "Where we are"). The directive holds: **every new capability ships with its
GTK surface in the same step.** The immediate GTK follow-ups, in order:
- ✅ **Lens/profile toggles in the window**, routed through the **bidirectional `user_state`
  frame** with surveyor as the session owner (D22, done 2026-06-18 — see "Where we are"). The
  Seam-C deadline is paid.
- **A docked "Why" panel** for the selected flow — the next GTK step. Needs row selection
  (a `GtkListView`/`GtkColumnView` instead of one big markup label, or a click controller), then
  a side panel that narrates the selected `Flow` from view-model fields (service/exposure/
  category/endpoint now; enrichment + the decomposed score as M3 lands). This is also the natural
  place the **shared `greeting` write** (name / ignore) first surfaces in the UI — and the first
  consumer of the D22 *broadcast* half (currently built but unexercised: greeting → surveyor
  store → all clients).
- **Category/risk visuals** (badges + eventually the confidence/impact rings, DESIGN-LANGUAGE
  §2/§4) as scoring emits `Reading`s.
- **libadwaita styling** once the layout settles.
Mechanism unchanged: thin renderer over `libcartograph`, binary IPC over the Unix socket,
GTK4 by direct C FFI (D10). Note: screenshots of a live run show real remote endpoints — keep
them **out of the repo** (the STATE.md privacy posture applies to our own artifacts too).

Then M3 capture/enrichment (each with its GTK surface):
- **Hybrid capture first:** fuse inet_diag (baseline + bytes) with eBPF events so `--bpf` shows
  the existing table *and* the closed `?` rows (M2 left `.bpf` either/or — see ROADMAP M3).
- Enrichment (DNS/SNI, GeoIP/ASN MMDB, nDPI) + impact/confidence scoring emitting `Reading`s;
  `Greeting` gets its real sqlite-backed (D20) implementation; every test gains its IPC twin.
- Byte counters on the eBPF path (sockops/`tcp_sendmsg`) — or keep inet_diag as the byte source.

## M2 — recommended order of attack (✅ all done this session — kept for the record)
1. **Test scaffolding first** (unblocks everything, and the critique is right that M2/M3 is
   where bug density explodes):
   - a **netlink mock** for `diag.zig` so capture decoding is testable without root;
   - a **golden-frame decode test** (recorded inet_diag bytes → expected `SockRecord`s);
   - the **in-process ↔ IPC parity test**: same input ⇒ identical `Flow` on both paths.
     This must exist *before* the Unix socket goes live, or parity fractures silently.
2. **eBPF capture** (the actual M2): tcp_connect / sock_state / exec via ring buffer → Zig;
   `setcap cap_bpf,cap_perfmon,...`, not root. Swap the capture *source* behind the existing
   `Capturer`/`Observation` seam — the `FlowTable` and frontends shouldn't change.
3. **Close the `?` rows** and answer the first-class design question from STATE.md: *what does
   the user do about an unattributed-but-known-daemon flow?* Answer lives in `libcartograph`.
4. **Stand up the privilege boundary for real:** surveyor as a setcap'd process, frontend
   connecting over a **Unix socket** (same IPC codec; transport swap from the pipe).
5. **Land the ontology frame:** define the four types (thin), reserve the four IPC frames,
   add the fixture shape to the test corpus. `Greeting` gets its real implementation at M3.

## Open questions — RESOLVED 2026-06-18 (Ben + maintainer); see DECISIONS D19/D20
- Ontology names: **kept** — `Greeting/Rule/Reading/Ruling` (Ben).
- `Greeting` vs `Identity`: **passes the type test, stays its own type** — it's the Fi layer
  the user authors over Identity's Ti structure; merging is a Fi bug (Ben + Fi/Ti frame).
- Persistence backend: **one sqlite DB** — mutable state tables + append-only act log
  (maintainer's call; Ben deferred).
- `Reading` cadence: **dual-mode** — threshold-cross by default, every-rescore opt-in,
  keyed off the active profile (Ben: "option for both").
- `EntityKey` granularity: **tagged union** `host/app/asn` (maintainer's call; Ben deferred).

## Reflections on the M1 review loop (what the critique offered — for next-me)

The Nexus v3 critique (plus the opencode + mmx third-reviewer passes) earned its keep. What it
*offered*, and how to treat the next one:

- **The top finding was structural, not a bug.** The act-ontology gap wouldn't have hurt until
  M6/M8 — by which point it'd be three retrofits. A critique that buys *future coherence*
  cheaply beats one that finds present bugs. Weight structural findings highest.
- **It was self-correcting because it was layered.** Long-view (Nexus) + surgical (opencode) +
  fresh third-reviewer (mmx). The third-reviewer caught the `Verdict` category-merge; this pass
  caught the same smell in `Greeting` (persistence ≠ a type). The value was the *loop*, not any
  one voice — and Nexus kept that as her own scar. Keep the loop; a finding can carry its own.
- **Calibration — trust the review's *what*, design its *how* yourself.** v3's structural calls
  (Reading≠Ruling, missing act-nouns, `user_state`-before-GTK) were gold. Its *mechanism*
  prescriptions were looser: "twin every test" → tightened to "one in-process↔IPC parity
  *property* + a few golden examples" (the property guards the invariant; the examples catch
  regressions). Adopt the diagnosis; write the treatment at build time.
- **A critique is a layer, not a gate.** Good ones get out of the way once they land. We
  adopted, refined, committed, pushed, and named the convention in one turn — that's the right
  metabolism. Don't "stop and re-read everything" because a critique arrived; do the work.
- **The reusable conventions this turn produced:** *archive carries the deliberation; the repo
  carries the conclusion*; and the form-defer — a collaborator's room (`.dextroesoteric/`) gets
  a **signpost, not a hand**.
- **The scar worth carrying (mutual, from Nexus):** when a proposal says "X *is* the storage /
  seam / layer," ask whether X *uses* that seam or *is* it. **Seams aren't types.** Same lens
  that split `Verdict` into `Reading`/`Ruling`.

## House rules reminder
- Git is handled automatically (commit/branch/push) — see the memory note; flag only a
  *public* flip.
- Respect collaborators' files; suggest cleanups via STRUCTURE.md, never delete.
- A feature goes in `src/lib`, never in a frontend.
- **Name is still a working title** (D8). `graphscope` was floated 2026-06-17; `Cartograph`
  held pending Ben's call (cartography metaphor is load-bearing + a `GraphScope`/Alibaba
  collision exists). If Ben confirms a rename, it's a mechanical pass — not yet done.
