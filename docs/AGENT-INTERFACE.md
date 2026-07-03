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
| **NDJSON (snapshot)** | agents, scripts, `jq`, kids | one flow = one JSON object = one line | ✅ `surveyor snapshot --json` |
| **NDJSON (stream)** | an agent *watching over time* | one event = one line (`hello`/`flow`/`closed`/`tick`) | ✅ `surveyor serve --json` |
| **self-description** | a model with zero prior training | the whole contract as one JSON doc | ✅ `surveyor --schema` |
| **binary IPC** | the GUI/TUI hot path | length-prefixed frames | ✅ `surveyor serve` |

**Rule (the Unix `isatty` move):** pretty when stdout is a terminal; structured when it's a
pipe. ✅ **Now automatic** — `surveyor snapshot` emits NDJSON the moment stdout isn't a TTY
(tcgetattr/ENOTTY); `--json` still forces it. A real Unix program never makes you fight color
codes in a pipeline.

## The live watch (the north-star surface)

> *"Human talking to their AI looking at the screen, seeing an accurate representation of what's
> happening every step of the way."* The agent should not poll a Polaroid — it should watch the
> **same live view-model the GUI renders**. That is `serve --json`: the text twin of the binary
> IPC, byte-for-byte the same `Flow` data, one self-identifying event per line.

```bash
surveyor serve --json | jq -c 'select(.ev=="flow" and .fresh)'   # narrate new connections live
surveyor serve --json --socket /run/user/$UID/cg.sock            # …or watch a headless box remotely
surveyor --schema | jq '.enums'                                  # learn every vocabulary, zero training
```

Event shapes: `{"ev":"hello","proto_version":2}` · `{"ev":"flow", …every snapshot field…}` ·
`{"ev":"closed", proto/local/remote key}` · `{"ev":"tick","at_ms":…,"flows":N}` (a heartbeat
even when nothing changed) · `{"ev":"focus","altitude":…,"target":…,"desc":…}` (the shared
cursor — below). The `flow` event carries the **identical** fields as `snapshot --json`, so code
that parses one parses the other — filter on `.ev`.

### The shared cursor — `focus` (R1)

> *"Looking at the screen"* implies a **thing being looked at**. `focus` is the agent's
> equal-fidelity (JSON) rendering of the *same* cursor the human's window holds — what is in view
> (`target`: machine/entity/flow) and at what altitude (`orbit→region→street→ground`). `desc` is
> the identical plain-language line the human's "Why" header shows, so the agent narrates from one
> source. Emitted on connect (inherit-the-cursor); it moves as navigation changes.

```bash
surveyor serve --json | jq -c 'select(.ev=="focus") | {altitude, target, desc}'
# {"altitude":"orbit","target":"machine","desc":"the whole machine (orbit)"}
```

**Read today; move next.** The agent can *see* the cursor now. *Moving* it (the agent says "look
at the `:631` listener" and the human's screen follows) needs the duplex command channel — see
the command surface in the roadmap, and [RESEARCH.md](RESEARCH.md) R1/R3. The type, the wire
frame, and the scope semantics (a `shared` cursor is `session`-scoped — D24) are already in place.

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
| `remote_name` | string | the remote's hostname (rDNS today; SNI/passive-DNS upgrade it at S3); empty = unknown |
| `asn` | number | autonomous system number of the remote; `0` = unknown |
| `as_org` | string | AS organization — *who owns the remote* (`"GitHub, Inc."`); empty = unknown |
| `country` | string | ISO 3166-1 alpha-2 of the remote (`"US"`); empty = unknown |
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
- ✅ `serve --json` — an NDJSON **event stream** (hello / flow / closed / tick as lines), the
  text twin of the binary IPC, for agents that want to watch over time.
- ✅ auto-structured-on-pipe (isatty); ✅ `--schema` (the self-describing contract).
- ⬜ **The command surface (the next real step):** an agent can *read* everything now but cannot
  yet *act*. A stable verb grammar (`watch`, `why`, `select`, `block`) with `--json` everywhere,
  and commands *in* (set-filter, set-profile, deep-capture) by flag/stdin. This is where the act
  ontology (ONTOLOGY.md) stops being reserved and starts paying rent — see [RESEARCH.md](RESEARCH.md).
- ⬜ When enforcement lands (M6): `block`/`allow`/`throttle` verbs return a JSON `Ruling` so an
  agent can act and *read back what it did* — visible, undoable, legible (D14, ONTOLOGY.md).
- ⬜ **Shared focus** — the agent and the human looking at *the same selection/zoom*, so "what
  the AI sees" === "what's on screen." The deepest form of the north star; [RESEARCH.md](RESEARCH.md) R1.
