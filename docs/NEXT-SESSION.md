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

## Open questions to settle with Ben + Nexus (before coding the types)
- Ontology names: keep `Greeting/Rule/Reading/Ruling`? (Categories data/state/act stay.)
- Does `Greeting` pass the type test vs `Identity`, or fold in? (ONTOLOGY.md §type test.)
- Persistence backend: sqlite vs append-only log per slot? (STATE.md table.)
- `Reading` emission cadence: every rescore vs threshold-cross? (IPC volume.)

## House rules reminder
- Git is handled automatically (commit/branch/push) — see the memory note; flag only a
  *public* flip.
- Respect collaborators' files; suggest cleanups via STRUCTURE.md, never delete.
- A feature goes in `src/lib`, never in a frontend.
