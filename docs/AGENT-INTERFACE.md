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
| **NDJSON (stream)** | an agent *watching over time* | one event = one line (`hello`/`posture`/`focus`/`flow`/`closed`/`tick`) | ✅ `surveyor serve --json` |
| **session daemon** | the human's window *and* the agent, together | binary frames on `<sock>`, duplex NDJSON on `<sock>.json` | ✅ `surveyor serve --socket <p>` |
| **command in** | an agent that *acts* | one JSON command per line in; `ack`/`error` out | ✅ the `.json` socket · `surveyor ctl` |
| **self-description** | a model with zero prior training | the whole contract as one JSON doc | ✅ `surveyor --schema` |
| **binary IPC** | the GUI/TUI hot path | length-prefixed frames | ✅ `surveyor serve` |
| **posture (status)** | an agent's situational check | ONE JSON envelope: capture posture + listeners + exposure badges + counts | ✅ `surveyor status` |

**`surveyor status`** (the station-convention one-shot, per `NEXUS-FORM-STATION.md`): the
"what's my machine doing right now?" answer in a single parse — a `status/tool/version/ts`
envelope carrying a `capture` posture object (source `polling`/`ebpf+polling`, which
enrichments are actually live), listener inventory with process attribution, per-listener
`exposure` (`loopback`/`network`/`internet`) and its risk-badge `badge` hex, plus
flow/exposure summary counts. Always JSON (a summary is data).
`surveyor status | jq '.listeners[] | select(.exposure != "loopback")'` = the attack surface.

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
surveyor serve --json | jq -c 'select(.event=="flow" and .fresh)'  # narrate new connections live
surveyor serve --socket /run/user/$UID/cartograph.sock             # …or host the shared session daemon
surveyor --schema | jq '.enums'                                    # learn every vocabulary, zero training
```

Every stream line self-identifies with a canonical `"event"` field (and carries a legacy
`"ev"` alias for parsers written against proto ≤ 4 — filter on either). Event shapes:
`{"event":"hello","proto_version":5,"tool":"surveyor","version":…}` ·
`{"event":"posture","source":"polling"|"ebpf+polling","pdns":…,"geoip_asn":…,"geoip_country":…}`
(capture-mode honesty: what this daemon can actually see) · `{"event":"flow", …every snapshot
field…}` · `{"event":"closed", proto/local/remote key}` · `{"event":"tick","at_ms":…,"ts":…,"flows":N}`
(a heartbeat even when nothing changed) · `{"event":"focus","altitude":…,"target":…,"desc":…}`
(the shared cursor — below) · `{"event":"ack","cmd":…}` / `{"event":"error","error":…,"fix":…}`
(replies to commands). The `flow` event carries the **identical** fields as `snapshot --json`,
so code that parses one parses the other.

### The shared cursor — `focus` (R1)

> *"Looking at the screen"* implies a **thing being looked at**. `focus` is the agent's
> equal-fidelity (JSON) rendering of the *same* cursor the human's window holds — what is in view
> (`target`: machine/entity/flow) and at what altitude (`orbit→region→street→ground`). `desc` is
> the identical plain-language line the human's "Why" header shows, so the agent narrates from one
> source. Emitted on connect (inherit-the-cursor); it moves as navigation changes.

```bash
surveyor serve --json | jq -c 'select(.event=="focus") | {altitude, target, desc}'
# {"altitude":"orbit","target":"machine","desc":"the whole machine (orbit)"}
```

**Read *and* move.** When observers share a session daemon (`serve --socket`), a `focus` with
`"shared":true` is the session's cursor: every window follows it — the GUI visibly selects the
row, the TUI moves its highlight, every NDJSON watcher gets the line. And the agent can *move*
it: write a focus command on the `.json` socket, or just shell out:

```bash
surveyor ctl focus app firefox          # "look at firefox" — the human's window follows
surveyor ctl focus asn 13335            # …the Cloudflare constellation
surveyor ctl focus flow tcp 192.168.1.9:38106 160.79.104.10:443 --altitude ground
surveyor ctl focus orbit                # back to the whole machine
```

`ctl` finds the default session socket (`$XDG_RUNTIME_DIR/cartograph.sock`), speaks one JSON
command line, and prints the daemon's `ack`/`error` reply. Exit `0` acked, `2` couldn't reach a
daemon, `3` you typed it wrong (stderr shows the grammar). On the raw socket the grammar is
one object per line: `{"cmd":"focus","target":"app","app":"firefox"}` — see `--schema`'s
`commands` array for every shape. Rejections come back as
`{"event":"error","error":…,"fix":…}` — the `fix` tells you how to repair the command.

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
| `ppid` | number | parent pid — *what launched this*; `0` = unknown |
| `pcomm` | string | parent process short name (`"steam"`, `"systemd"`); empty = unknown |
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
- **Self-describing:** `--help` stays parseable; `--schema` emits the whole contract — every
  field, event, command shape, and vocabulary — as one JSON doc, so an agent can self-orient
  with zero prior training.
- **Exit codes mean something:** `0` ok · `2` runtime/unavailable (stderr names the fix) ·
  `3` usage error (stderr shows the grammar). A pipeline can branch on them.
- **The surface doesn't lie:** NDJSON is the *same* `Flow` the TUI draws — no agent-only fiction,
  no human-only fiction. One truth, many renderings.

## Roadmap for the surface
- ✅ `snapshot --json` (NDJSON projection of the live view-model).
- ✅ `serve --json` — an NDJSON **event stream** (hello / posture / focus / flow / closed / tick
  as lines), the text twin of the binary IPC, for agents that want to watch over time.
- ✅ auto-structured-on-pipe (isatty); ✅ `--schema` (the self-describing contract).
- ✅ **Shared focus** — the agent and the human looking at *the same selection/zoom*, so "what
  the AI sees" === "what's on screen." The session daemon (`serve --socket`) multiplexes one
  capture core to every window and agent; `ctl focus …` moves the cursor for all of them.
- ✅ **The command surface (first verbs):** `watch` and `focus` land the duplex channel — an
  agent acts and *reads back the ack*. The grammar is stable and self-described in `--schema`.
- ⬜ More verbs as capability lands: set-filter, set-profile, deep-capture — the act
  ontology (ONTOLOGY.md) paying rent surface-first; see [RESEARCH.md](RESEARCH.md).
- ⬜ When enforcement lands (M6): `block`/`allow`/`throttle` verbs return a JSON `Ruling` so an
  agent can act and *read back what it did* — visible, undoable, legible (D14, ONTOLOGY.md).
