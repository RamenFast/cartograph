# Cartograph — Research (the foundational open problems)

> The questions a single session can't close — written down so they get *dedicated* work
> instead of being quietly designed-around. Each is real, each is load-bearing on the north
> star (*"human talking to their AI looking at the screen, seeing an accurate representation
> of what's happening every step of the way"*), and each is honestly un-finished today.

Status legend: 🔴 open · 🟡 partial (a seam exists) · 🟢 closed (moves out of this doc).

---

## R1 — Shared focus: one cursor the human *and* the agent both hold  🟡

> **Update 2026-06-19 — the seam is built.** `Focus` is now a first-class view-model type
> (`src/lib/focus.zig`): `Altitude` (orbit/region/street/ground) + `Target` (machine/entity/flow)
> + `shared`, with a `describe()` line that is *one source* for the human "Why" header and the
> agent's narration. It travels the **same `user_state` parity frame** as profile/lens
> (`UserState.focus`, IPC round-trip tested), lives in `SessionState`, and — crucially —
> `scopeOf(.focus)` returns **`session`** when `shared`, giving the (previously dead) `◍ session`
> scope rung its first real consumer. The agent gets its **equal-fidelity JSON rendering**: a
> `focus` event on `serve --json` (and in `--schema`), emitted inherit-on-connect. *Per Ben: the
> agent's UI is a different rendering (JSON) of the same shared state — UI/UX principles transfer.*
>
> **What's left (the next-session halves):** (1) **renderer wiring** — both TUI and GTK display
> the cursor and let the user move it (keys → `setFocus` → upstream), done in *one* step for both
> so render-parity (R5) isn't broken; (2) the **duplex JSON command channel** so an agent can
> *move* the cursor, not just read it (R3); (3) **multi-client broadcast** of a `shared` focus —
> surveyor holding one session cursor and pushing it to every observer, which is the `atlas`
> fan-out job (D9 amended). The type and scope semantics below are settled; these three are the
> remaining build.

**Original framing (kept for the full problem statement):**


**The problem.** "Looking at the screen, every step" implies a *shared* object of attention.
Today the human's GUI has a selection/zoom (which entity, which flow, which altitude:
orbit→region→street→ground) and the agent has… a flat list of flows. They are not looking at
the same thing. For the vision to be literally true, three things must exist:

1. **A focus the model can read** — "the human has selected `chrome → github.com`, at STREET
   altitude." The agent should be able to answer *"what am I looking at?"* the way the human can.
2. **A focus the model can move** — the agent says "look at the unattributed `:631` listener,"
   and the human's screen *moves there*, visibly. (Undoable, never jarring — DESIGN-LANGUAGE §8.)
3. **Presence** — when two minds share a screen, each should see the other's cursor. Human sees
   "the agent is examining this flow"; agent sees "the human just selected that one."

**Why it's foundational, not a feature.** This is a *type* and a *transport*, not a widget.
Focus/selection/altitude is **user-authored view state** — exactly the category `SessionState`
(D22) already made first-class for profile+lenses. The natural shape: extend the view-model with
a `Focus { entity/flow key, altitude, selection }`, carry it on the existing `user_state` frame,
and it inherits the parity-by-construction property for free.

**The "consent gate" question — RESOLVED (D25).** I had flagged the hard part as *"when does the
agent get to move the human's eyes — how is that consent-ful rather than a hijack?"* Per Ben, that
was the wrong frame: this is a **full-trust home computing environment, a science experiment.** The
agent is a co-inhabitant, so it moves the cursor **freely — no permission gate.** Safety is the D14
mechanism (visible · reversible · honest), *not* gating; friction is reserved for the
destructive-and-irreversible and is identical for human and agent. So R1's remaining work is pure
*build* (renderer + transport + broadcast), with **no auth/consent layer to design.**

**Where it lives: `atlas` (D9 amended).** Shared presence across many observers is precisely the
BEAM/OTP/LiveView job. A single local socket is one observer; the presence layer is where *N*
observers' cursors are tracked, broadcast, and reconciled. R1 is the concrete reason `atlas` is
*essential*, not optional: it is the home of the shared cursor.

**First step that's cheap and safe:** add a read-only `focus` to the view-model + `user_state`
frame and expose it on the agent surface (`surveyor … --json` could emit a `focus` event; a future
`select <key>` verb writes it). Read before write: let the agent *see* the human's focus well
before it's allowed to *move* it.

**Open sub-questions:** altitude semantics when the map doesn't exist yet (it's a table today);
multi-observer conflict (two cursors, one screen); whether focus is per-observer or one shared
"table cursor" everyone follows.

---

## R2 — What does an agent "see" of a *visual* map?  🔴

**The problem.** The hero is a spatial scene — a constellation with positions, sizes, colors,
edges, and a continuous zoom. NDJSON gives an agent the *flows* (the data), but not the *scene*
(the spatial truth the human is actually looking at). If the human says "what's that big red node
top-left?", the agent has no notion of "top-left" or "big." The flat table is the right **data**
surface and the wrong **scene** surface.

**The tension.** We do *not* want to ship pixels to the model (bloated, model-specific, defeats
"legible to Gemma-12b"). We want a **structured projection of the scene**: nodes with stable ids,
category/size/risk, layout coordinates (or relative positions: "cluster A, periphery"), edges, and
the current viewport (center, altitude, what's on-screen vs off). The research question: *what is
the minimal, model-agnostic scene description that lets any model reason about the same picture the
human sees* — without rendering, without a screenshot, without a vendor SDK?

**Why now (cheaply):** even pre-map, define the **scene-graph schema** as a first-class projection
of the view-model (a `--scene --json` twin of `--schema`), so when the map lands it has an agent
surface *by construction* instead of three retrofits (the same lesson the act ontology is betting
on — R4).

---

## R3 — The command surface: let the agent *act*, and *read back what it did*  🟡

**The problem.** The agent can now *read* everything (`snapshot --json`, `serve --json`, `--schema`)
but cannot *act*. There is no `why`, `select`, `set-profile`, `block`, `watch` verb. The vision's
"every step of the way" includes the AI *doing* steps — drilling in, asking why, blocking a flow —
and the human seeing each act land on the screen.

**Why it's partly solved already.** The act ontology (ONTOLOGY.md) was built for exactly this:
`Ruling` exists so *"an agent can act and read back what it did — visible, undoable, legible."*
The frame slots are reserved. **The missing piece is the verb grammar + a JSON result type.** A
clean shape: every verb takes `--json`, mutates via a `user_state`/`rule` write, and returns a
`Ruling`/`Reading` object the agent (and the human's screen) both observe. This is where the
reserved ontology *stops being speculative and starts paying rent* (see R4).

**Hard parts** (note: *not* permission/consent — that's resolved full-trust, D25): the write verbs
apply without a gate, so the real work is (a) the genuinely-destructive case (`block`) getting the
DESIGN-LANGUAGE §8 consequence tree — *reversibility + friction, identical for human and agent*, not
a "may I?"; (b) idempotency (re-issuing a command); (c) authority/ordering when many observers issue
commands at once (back to R1/atlas — last-writer-wins on a session-scoped value is the simple start).

---

## R4 — Keeping the act ontology honest (designed-ahead-of-use risk)  🟡

**The problem.** `Greeting / Rule / Reading / Ruling` are defined *thin* with full IPC codecs and
round-trip tests, but **no producer emits them and no consumer handles them** (the frontends and
surveyor `else => {}` every one). That is design-ahead-of-need by ~3–6 milestones. Nexus argued for
it ("design the seam once, avoid three retrofits — one afternoon"); the counter-argument is YAGNI:
the wire format is now committed to features whose requirements aren't known, and the additive/
unknown-frame design (proven in `ipc.zig`) already lets them be added later without a break.

**The research question (genuinely unresolved):** *which speculative types earn their early
existence, and which should wait?* The project has a good internal test for this — the "type test"
in ONTOLOGY.md (a type earns its name only if it carries state existing types can't). Apply it
ruthlessly per type, and **give each surviving type a real consumer as early as possible** so it's
validated by use, not by imagination. The fastest real consumer available today is **the agent
command surface (R3)** — wiring `Reading`/`Ruling` to verbs would convert the most speculative
types into used ones in the nearest milestone. That is the recommended way to de-risk R4.

**A note on cosmology vs engineering.** The `Reading≠Ruling` (shown vs done) and `Greeting≠Identity`
(mine vs derived) distinctions are real and worth their types. The surrounding apparatus — the
Fi/Ti metaphysics embedded in load-bearing code comments, the locked-but-"provisional" names — adds
learning cost for exactly the *"legible to any model from Opus to Gemma-12b"* audience the project
prizes. Open question: how much of that framing belongs in the *code* vs in a single design essay
the code links to.

---

## R5 — Parity-by-construction at the *render* layer  🟡

**The problem.** "A capability can never exist in one UI but not another — parity by construction"
is the project's headline claim, asserted in ~8 doc-comments. It is **true at the view-model/wire
layer** (proven well in `parity.zig`) and **false at the render layer**: the TUI's `render` and the
GTK's `renderMarkup` are hand-duplicated ~130-line functions that have *already drifted* (column
widths disagree; GTK has no sparkline). Parity is currently by *copy-paste*, and the copies diverge.

**The fix is known, the question is scope.** Lift the column model + row-field formatting into
`libcartograph` as pure functions over an emit-style trait (text/ANSI for TUI, Pango markup for
GTK), leaving renderers to differ *only* in escaping and color encoding — then a single golden-
render test pins both. The research/eng question: the right trait boundary in Zig 0.16 (comptime
vs fn-pointer) that keeps the GTK FFI renderer thin without a perf or ergonomics cost. Until then,
the honest phrasing is *"parity by construction at the view-model; renderers are thin but
hand-written"* — and the claim should not be repeated as if it covers rendering.

---

## R6 — UDP, and the byte-counter source under eBPF  🟡

**The problem.** `inet_diag` gives TCP byte counters + RTT; UDP shows as sockets without counters,
and the eBPF `inet_sock_set_state` hook is the *state machine*, not the *data path* (byte counters
stay 0 there — honest, but incomplete). A `sockops`/`tcp_sendmsg`/`udp_sendmsg` counter program is
the real source. Open question: the lowest-overhead always-on counter path that keeps T0 "cheap"
(VISION's tiered promise) without copying payloads. Ship UDP's limitation *loudly* in the meantime.

---

## How these connect (the one-paragraph synthesis)

R1 (shared focus) and R3 (command surface) are the two halves of "the AI is *in* the loop, not
*beside* it"; R2 (scene graph) is what they reason over once the map exists; **`atlas` is the fabric
all three ride on for the multi-mind case**; R4 (honest ontology) is how the act vocabulary that R3
needs stays trustworthy; R5 (render parity) is the integrity of the picture everyone shares; R6 is
making the underlying numbers complete. Closing R1+R3 is what turns *"human talking to their AI
looking at the screen"* from a tagline into a running program.
