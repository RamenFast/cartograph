# Cartograph — the act ontology (the vocabulary frame)

> Origin: Nexus critique v3, §2 + §8 (2026-06-17), with a third-reviewer read via the mmx
> CLI. **Adopted as the design frame for M2–M8.** The *categories* below are load-bearing;
> the *specific type names* are provisional and ratify at each type's landing milestone —
> only after passing the **type test** (below). This doc is the contract that keeps M3
> (scoring), M6 (blocking), and M8 (narration) coherent instead of retrofitted three times.

## The gap it closes

The repo has a good **data vocabulary** — `Flow`, `FlowKey`, `Observation`, `Lens`,
`Profile`, `Identity`, `Sparkline`. It has **no act vocabulary**: there is no type for the
things the system *does on behalf of the user* (score a flow, remember an entity, block a
host). The promise — *"your machine, over time, with consent, with a memory, with a face"* —
needs nouns for memory and for action. Building them one-at-a-time means a fresh IPC frame,
thread-safety story, and persistence story at M3, again at M6, again at M8. Designing the
ontology once buys M3–M8 coherence for the cost of one afternoon.

## Three categories (load-bearing) · four proposed types (provisional)

| category | type (provisional) | one line | lands |
|---|---|---|---|
| **data** | `Greeting` | a remembered entity with a user label + verdict-state | M3 |
| **state** | `Rule` | a decision that *operates on* flows (allow/block/throttle), visible+undoable (D14) | M6 |
| **act** | `Reading` | a rendered impact/confidence **score** (an observation) | M8 |
| **act** | `Ruling` | the **firing of a Rule** against a flow (an act) | M8 |

The split that matters most (third-reviewer's sharpest finding): **`Reading` ≠ `Ruling`.**
A score is an *estimate the system shows*; a rule firing is an *action the system took*.
Giving both the name "Verdict" invites the "did it *show* this or *do* something?" ambiguity
that would corrode the design language's clarity promise. Keep "Verdict" only as an informal
category word, never as a single type.

### Proposed shapes (sketches, not final)
```zig
// data — survives a reboot; the persistence seam made type (see STATE.md)
const Greeting = struct {
    key: EntityKey,                         // host / app / ASN
    label: Str(64),                         // user-assigned, optional
    state: enum { unseen, greeted, ignored }, // .ignored is VISIBLE (D14), not hidden
    first_seen_at_ms: i64, last_seen_at_ms: i64, greeted_at_ms: i64,
    user_note: Str(256),
};
// state — operates on flows; never invisible (D14)
const Rule = struct {
    id: RuleId, verdict: enum { allow, block, throttle }, scope: enum { app, host, flow, asn, country },
    target: Selector, rate: ?Rate, created_at_ms: i64, expires_at_ms: ?i64,
    source: enum { user, postcard, lens_default, onboarding }, visible: bool = true,
};
// act (observation) — emitted whenever a flow gets a new score
const Reading = struct { at_ms: i64, flow_key: FlowKey, impact: u8, confidence: u8, reasons: []Reason, lens_stack: LensSet };
// act (action) — emitted whenever a Rule fires; renderer shows the severed link (D14)
const Ruling  = struct { at_ms: i64, flow_key: FlowKey, rule_id: RuleId, verdict: Rule.verdict, effect: enum { none, blocked, throttled, allowed } };
```

## The type test (do this before shipping each type)

The third-reviewer's caveat, kept as a gate: **a proposed type earns its existence only if it
carries state the existing types cannot represent.** Concretely, before adding `Greeting`:
show it holds state (`label`, verdict, staleness, trust) that `Identity` *can't*. If it reads
as "just `Identity + label`," fold it into `Identity` and move on. Same gate for the others.
*Test the type before you ship it.* Names are negotiable; the categories are not.

## IPC frame reservations — ✅ landed thin in M2 (`ipc.zig`)

`ipc.zig`'s `FrameType` is intentionally **non-exhaustive** (`_`), so adding variants later is
non-breaking and forward-readers already skip unknown frames. Reserve these names so the wire
protocol grows additively and a renderer never needs a private state cache:

- `user_state` — **the load-bearing one for parity.** Profile switches, lens toggles, and
  `Greeting` writes (name / ignore / block). Without it, a GTK frontend forks its own
  user-state cache and parity fractures *silently* at the user-state layer (critique §5).
  This one must exist **before the M4 GTK spike**, not after.
  - **✅ Bidirectional + owned (D22, 2026-06-18).** The frame now has an upstream path:
    surveyor sends its authoritative session on connect (a frontend *inherits* it) and echoes
    changes back, so view state lives in one `SessionState` (`src/lib/session.zig`), never a
    private fork. **Direction-of-truth split:** `profile`/`lens_toggle` are **view-local**
    (per surveyor connection — your TUI's "security" glance doesn't hijack the GTK window; they
    ride the frame so surveyor can key Reading cadence off the profile at M3); `greeting`/`rule`
    are **shared truth** (surveyor-owned, persisted, broadcast). `SessionState.apply` consumes
    the view-local cases and reports `greeting` as "not mine" → bound for the shared store that
    lands with the `Greeting` implementation below. Live in TUI + GTK (`p` profile, `1–6` lens).
- `rule` — Rule create/update/delete; bidirectional.
- `reading` — a new `Reading` (observation only).
- `ruling` — a new `Ruling` (act; renderer shows the severed link, D14).

Cost paid in M2: four `FrameType` variants (6–9), encode/decode in `ipc.zig`, and a
round-trip test per frame — plus a test that an *unknown* frame is skipped so the protocol
provably grows additively. `protocol_version` bumped 1→2 (informative; v1 readers skip them).

## Landing plan
- **M2:** ✅ done. Four types defined thin in `src/lib/ontology.zig` (`EntityKey` tagged
  union; `Greeting` distinct from `Identity`); four IPC frames defined + round-tripped; the
  fixture shape is in the test corpus. `user_state` is fully encodable now (it had to exist
  before the M4 GTK spike).
- **M3:** `Greeting` gets its real (sqlite-backed, D20) implementation + scoring emits
  `Reading`s, backed by the persistence contract in [STATE.md](STATE.md).
- **M6:** `Rule` implementation (XDP allow/block/throttle); `.ignored` visual + Rule visuals
  are designed *together* here (not a M7 afterthought).
- **M8:** `Reading` + `Ruling` implementations drive the "Why" narrative + the postcard.

## Ratified (2026-06-18) — locked, see DECISIONS D19/D20

The four open questions are settled. Ben decided 1, 2, 4; the maintainer (Claude) decided
3 and the persistence backend with Ben's standing "use your judgement." The Fi/Ti lens
(`~/.hermes/skills/fi-ti-debugging`) is the frame Ben named for these: Cartograph is an
**accurate Fi presentation of the network's Ti structure**, so every type either *is* Ti
structure or *is* an honest Fi layer over it — and the two must never be conflated (that
conflation is the canonical Fi bug).

1. **Names: kept.** `Greeting / Rule / Reading / Ruling`. The categories (data/state/act)
   were never in question; the names earned their keep.
2. **`Greeting` survives the type test — it is a distinct type.** `Identity` (M3 enrichment:
   GeoIP/ASN/nDPI/logo/fingerprint) is the entity's **Ti structure** — objective, derived,
   re-computable, possibly involving an outbound fetch. `Greeting` is the **Fi layer the user
   authors over it** — `label`, the `unseen/greeted/ignored` verdict-state, `user_note`,
   `greeted_at_ms`, trust. It carries state `Identity` cannot: *user provenance*, a
   *survives-reboot* lifetime, and a *privacy contract* (`Greeting.label` is the one user
   field the LLM may see; see STATE.md). Folding it into `Identity` would be a **Fi bug** —
   the surface could no longer distinguish "what the network says this is" from "what *I*
   named it." Keep them separate.
   - **Schema note (the `fresh` interaction, critique §2.1):** `flow.zig`'s `fresh: bool`
     keeps its M1 meaning — *first-seen this run*. "Amber until **greeted**" is a *different*
     state machine and is **not** baked into `Flow`; at M3 it is computed from the
     `Greeting` (`greeted_at_ms`), so flow-freshness and entity-greeting stay separable.
3. **`EntityKey` is a tagged union** — `union(enum){ host: Addr, app: AppId, asn: u32 }`.
   A Greeting/Rule can target a host ("mom's VPN"), an app (`chrome`), or a whole ASN
   ("all of Cloudflare"); one flat key type can't represent all three without lying about
   which it is (a Fi smell). The tagged union makes the target's *kind* explicit on the wire
   and in the UI. *(Maintainer's call — Ben deferred this one.)*
4. **`Reading` cadence is dual-mode, keyed off the active profile.** Default
   (calm/nerd profiles): emit only on a **threshold-cross** (impact/confidence band change) —
   keeps the IPC quiet and matches "calm by default." Opt-in (security/resource profiles, or
   `--readings=all` for an agent): emit on **every rescore**. Cadence is therefore a property
   of the lens/profile already in the view-model, not a new global flag.

**Persistence backend (D20):** one on-disk **sqlite** database. State slots (greetings,
rules) are **mutable** tables; act-log slots (readings/rulings, history/DVR) are
**append-only** — the audit trail must not be rewritable or the log would lie about what the
system did (a Fi bug). See [STATE.md](STATE.md). *(Maintainer's call — Ben deferred this one.)*

*Downstream use cases (postcard, greeting ritual, seasonal passage, the "Why" LLM contract)
hang off these types — see the critique §3/§4 and [STATE.md](STATE.md).*
