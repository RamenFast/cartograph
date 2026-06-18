# Cartograph — the agent / Unix interface (no AI left out)

> Origin: Ben, 2026-06-17 — *"deeply integrated with agent functionality through
> agent-understandable bash… like a real Unix program… no AI left out, easy to read/parse
> parameters, let the kids tinker with their machines."* This is the contract that makes that
> true. **The agent and the kid are the same user:** both want a legible, composable, honest
> program — not an SDK, not a plugin, not a glyph you must learn. `cartograph … --json | jq`
> is the kid learning *and* the agent reasoning, same pipe.

## The three surfaces, one view-model

Every surface is a *renderer* over `libcartograph`, so none can drift from the others (parity).

| surface | consumer | form | status |
|---|---|---|---|
| **human table** | a person at a TTY | colored, aligned, glyphs | ✅ `surveyor snapshot` |
| **NDJSON** | agents, scripts, `jq`, kids | one flow = one JSON object = one line | ✅ `surveyor snapshot --json` |
| **binary IPC** | the GUI/TUI hot path | length-prefixed frames | ✅ `surveyor serve` |

**Rule (the Unix `isatty` move):** pretty when stdout is a terminal; structured when it's a
pipe. Today the structured form is explicit (`--json`); auto-detection on a pipe is a near
follow-up. A real Unix program never makes you fight color codes in a pipeline.

## NDJSON schema (stable contract)

One flow per line. **Field names are stable**; breaking them is a versioned change, never a
silent one (a parser that breaks tomorrow on today's output is a Ti bug, and we don't ship those).

| field | type | notes |
|---|---|---|
| `proto` | string | `tcp` \| `udp` |
| `state` | string | `ESTAB`, `LISTEN`, `TIME_WAIT`, … |
| `category` | string | `web`/`dns`/`lan`/`loopback`/`listen`/… (the coarse color/glyph bucket) |
| `service` | string | daemon-precise service from ports, **attribution-independent**: `ssh`/`dns`/`ipp`/`http`/… (`unknown` if unrecognised). The `?`-flow answer — a `pid:0` flow is still named. |
| `exposure` | string | listener attack-surface: `none` (not a listener) · `loopback` · `network` · `internet` |
| `pid` | number | **`0` = unattributed** (kernel / other-user / short-lived) — see `service` |
| `uid` | number | owning user id |
| `comm` | string | process short name (may be empty) |
| `exe` | string | resolved executable path (may be empty) |
| `local` / `remote` | string | bare address, **no brackets** (v4 dotted, v6 compressed) |
| `local_port` / `remote_port` | number | port, separate from the address |
| `rx_bytes` / `tx_bytes` | number | cumulative bytes (inet_diag; TCP) |
| `rx_rate` / `tx_rate` | number | bytes/sec, derived between ticks |
| `rtt_us` | number | smoothed RTT, microseconds (`0` if unknown) |
| `fresh` | bool | first-seen this run (amber glow in the UI) |
| `first_seen_ms` / `last_seen_ms` | number | epoch milliseconds |

Numbers are numbers (not strings). No wrapper object, no envelope — pure NDJSON so it streams,
greps, and `jq`s without ceremony.

## Composability (what the kid and the agent both do)
```bash
surveyor snapshot --json | jq -c 'select(.category=="web") | {comm,remote,tx_bytes}'
surveyor snapshot --json | jq 'select(.pid==0)'          # what can't I attribute?
surveyor snapshot --json | jq -s 'sort_by(-.tx_bytes)[0]' # the loudest flow
watch -n1 'surveyor snapshot --json | jq -r ".[].remote" | sort -u'
```
An agent does the exact same thing — shell out, parse lines, reason. No integration code.

## Discovery & honesty (so no AI is left out)
- **No SDK, no glyphs, no special integration.** Any agent that can run bash and parse
  JSON/lines can drive it. Substrate-neutral by construction (this is the HCL "portable
  artifact" principle applied to a tool's interface — see Fi/Ti debugging).
- **Self-describing:** `--help` stays parseable; a `--schema` verb (emit this table as JSON) is
  planned so an agent can self-orient with zero prior training.
- **Exit codes mean something:** `0` ok, non-zero on error (documented per verb). A pipeline
  can branch on them.
- **The surface doesn't lie:** NDJSON is the *same* `Flow` the TUI draws — no agent-only fiction,
  no human-only fiction. One truth, many renderings.

## Roadmap for the surface
- ✅ `snapshot --json` (NDJSON projection of the live view-model).
- ⬜ `serve --json` — an NDJSON **event stream** (flow-upsert / closed / tick as lines), the
  text twin of the binary IPC, for agents that want to watch over time.
- ⬜ auto-structured-on-pipe (isatty); `--schema`; stable verb grammar (`watch`, `why`, `block`)
  with `--json` everywhere; commands *in* (set-filter, deep-capture) by flag/stdin.
- ⬜ When enforcement lands (M6): `block`/`allow`/`throttle` verbs return a JSON `Ruling` so an
  agent can act and *read back what it did* — visible, undoable, legible (D14, ONTOLOGY.md).
