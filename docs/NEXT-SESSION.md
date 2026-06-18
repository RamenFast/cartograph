# Cartograph — next session (start here)

> Written at the end of the M1 + critique-response session (2026-06-17). Read this first, then
> ONTOLOGY.md and STATE.md. Goal of next session: **start M2 on the frame the critique gave us.**

## Where we are
- **M1 shipped and is on `main`** (private repo `RamenFast/cartograph`): `libcartograph`
  view-model, a capture core (inet_diag byte counters + RTT + /proc attribution), and a live
  TUI that runs in-process *or* over the binary IPC. `zig build` / `run` / `test` all green.
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

## M2 — recommended order of attack
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
