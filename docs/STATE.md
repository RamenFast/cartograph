# Cartograph — state, persistence & privacy contract

> Origin: Nexus critique v3 §5.3/§5.4 + §4 Seam A. **The implementation can be incremental;
> the contract must be early.** One paragraph per persistence slot, plus the privacy posture
> they all inherit. Commit to this at **M2** (when the capture core first becomes worth the
> persistence cost). Until a slot is built it is "in-memory only" — and that is fine, as long
> as the *contract* below is the thing we build toward.

## Why early

`FlowTable` is an in-memory `AutoHashMapUnmanaged`. The whole witness-voice promise — a map
that *remembers*, a postcard, time-travel — is impossible without an on-disk story, and the
**`Greeting` type ([ONTOLOGY.md](ONTOLOGY.md)) is the persistence seam made concrete.** If we
let amber-glow/score/rule state accrete in memory first and bolt on persistence later, we pay
a migration tax three times. So: decide *where state lives and what survives a reboot* now;
build it slot by slot.

## Persistence slots (one paragraph each)

> **Backend locked (DECISIONS D20, 2026-06-18):** one on-disk **sqlite** database. State
> slots (greetings, rules) are **mutable** tables; act-log slots (readings/rulings,
> history/DVR) are **append-only** — the audit trail must not be rewritable, or the log
> would lie about what the system did (a Fi bug). Retention windowing prunes from the tail,
> never edits a past row. Implementation stays incremental (a slot is "in-memory only" until
> built); the *contract* below is what we build toward.

| slot | survives reboot? | format (D20) | owner |
|---|---|---|---|
| **Live flows** | no — ephemeral by design | in-memory `FlowTable` | surveyor |
| **Greetings** | **yes** | sqlite (`greetings`), or append-only log | surveyor (writes), frontends (read via IPC) |
| **Rules** | **yes** | sqlite (`rules`) — must reload + re-arm XDP on boot | surveyor |
| **History / DVR** | yes, bounded | sqlite ring or columnar, retention-windowed | surveyor |
| **Readings/Rulings log** | yes, bounded | append-only event log (powers postcard + replay) | surveyor |
| **Logo/icon cache** | yes | on-disk blob cache, opt-in, rate-limited | frontend/enrichment |

- **Greetings** — user labels + verdict-state for entities. Written once via `user_state` IPC;
  read by every renderer so the name "mom's VPN" shows identically in TUI and GTK. The single
  source of truth for "have I greeted this?" Backs foresight #1, the postcard, the passport.
- **Rules** — allow/block/throttle objects. Must be reloaded **and re-armed in XDP** on boot,
  or a "blocked" host silently un-blocks after a reboot (a safety bug, not a cosmetic one).
- **History/DVR** — bounded per-app/per-entity totals + a replayable event stream. Retention
  is a user setting; default conservative. Time-travel (foresight #2) reads this.
- **Readings/Rulings log** — the append-only act log; the postcard and "what changed since
  yesterday" are queries over it.

## Privacy posture (the contract every slot inherits)

Cartograph watches your privacy; it must not become the thing that leaks.

1. **Local by construction.** All of the above lives on-box. Nothing syncs anywhere by
   default. Cross-machine sync, if ever built, is explicit, user-keyed, opt-in — a separate
   decision, not a default.
2. **Export & clear are first-class.** The user can export their Greetings/Rules/history to a
   readable file and **wipe any slot**. "Forget this entity," "clear last night," "reset the
   map" are supported verbs, not buried files.
3. **The tool shows its own traffic.** Logo/favicon fetches (the only outbound traffic
   Cartograph itself makes) appear on the same map, attributed to Cartograph — no hypocrisy.
4. **The LLM sees a whitelist, never raw flow.** The "Why"/postcard model sees only the active
   profile's lenses ∪ user overrides ∪ the entity's identity/risk/system fields ∪ the user's
   own `Greeting.label`. **Never** raw flow bytes, DNS history, or packets. (Critique §4 Seam
   B. Two surfaces, two contracts: the *live "explain this flow"* verb is the local model's
   voice; the *postcard template* is the user's voice — don't conflate them.)

## The unattributed (`?`) flow is a privacy case, not a feature gap

E2's `?` rows on Ben's box are `sshd:22`, `cups:631`, `systemd-resolved:53`, `nginx:80` — the
four most security-relevant daemons on a personal Linux box. `flow.zig` encodes `pid: u32 = 0`
("unattributed"); there is **no notion of "unattributed but a known daemon."** Consequences if
left unhandled:
- DNS via `systemd-resolved` shows up unattributed → Cartograph can't say *"your DNS is
  forwarding to 1.1.1.1."*
- `cups` on the LAN unattributed → the "what can the world see of me" mirror is **wrong by
  omission** on a service with recent CVEs.

**Therefore:** M2 (eBPF) must answer *"what does the user do about an unattributed flow?"* as a
first-class design question, and the answer must live in `libcartograph` (so TUI and GTK don't
diverge). The eBPF attribution, the `Greeting` type, and this privacy posture are **one design
question wearing three labels.**

> **✅ Answered in M2 (view-model half).** `identity.service(key,state)` names the daemon-precise
> service (ssh/dns/ipp/http/…) **independent of attribution**, and `identity.exposure(key,state)`
> grades a listener's reach (loopback/network/internet). Both are pure derivations from fields
> already on the wire, live in `libcartograph` (so every renderer agrees), and surface on the NDJSON
> agent contract (`service`, `exposure`). A `pid:0` flow is now legible, not a `?` dead-end:
> `surveyor snapshot --json | jq 'select(.pid==0 and .service!="unknown")'` lists the known-but-
> unattributed daemons, and `… | jq 'select(.exposure=="network" or .exposure=="internet")'` is the
> attack-surface mirror. The *eBPF* half (actually attributing those rows to a PID in-kernel) is the
> capture-source work; the *legibility* half no longer depends on it.

## CLI surface caveat (don't write checks the build can't cash)

`--no-fetch` and friends in CLI.md are **aspirational** — there is no arg-parser module in the
tree yet (critique §5.7). Do **not** write privacy guarantees assuming a flag works. When a
privacy flag lands, it lands *with* its test in the same change:
`cartograph watch --no-fetch` must produce **zero** Cartograph-originated rows.
