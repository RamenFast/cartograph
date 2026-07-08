# Cartograph — next session (start here)

> Updated 2026-07-08 (**v1.0.0 RELEASED**). New here? Read [docs/V1.md](V1.md) (the scope call +
> the S1→S4 build log), then [docs/README.md](README.md) (index + status map). Everything builds +
> tests green: **`zig build test` = 73, `-Dbpf=true` = 78.**

## 🚢 v1.0.0 SHIPPED (2026-07-08) — the crystallize wave

**The release is real:** <https://github.com/RamenFast/cartograph/releases/tag/v1.0.0> —
deb + rpm (identical payloads by construction, `packaging/stage.sh`) + source tarball +
SHA256SUMS, notes from `packaging/RELEASE-NOTES-v1.0.0.md`, hero from the exact released
bits (endpoint-reviewed under STATE.md §5). Installed and verified on this box: all three
`--version`s answer 1.0.0, man pages render, the desktop entry validates, the icon caches
are fresh, eBPF caps granted and attach verified (stderr clean, no fallback).

The wave itself (branch merged `--no-ff`, then deleted — one-branch law):
- **The double-click path actually opens** — menu launchers hand apps `/dev/null`, which is
  no tty *and* no pipe; detection is now fstat-based (FIFO/socket/regular file = frames on
  stdin; anything else spawns a private `surveyor serve` that dies with the window).
- **The GTK app wears the house Blossom Dark** (ben-ui-design; canon = phosphor theme.rs):
  sharp corners, hairline frames, headerbar brand + carved stone profile button + lens
  toggle rail (buttons and keys drive the same D22 session), engraved Why plate, gold
  headline numbers, rose shared cursor. Category/exposure data hues unchanged (D14).
- **The icon came home**: same constellation concept, re-grounded in the app's own palette;
  flows are great-circle arcs; the machine is the ringed rose home star. Guard-band 0,
  RGBA all sizes, verified at 256/64/32/16.
- **Layout hardened**: header + rows ellipsize; the list never h-scrolls; the full lens
  column set fits the default pane (the v6-street-focus pane-shove bug is dead).
- **D8 RATIFIED** — the name is Cartograph. README rewritten compact + evergreen (~120
  lines, agent-legible, every command run verbatim). Governance founded: docs/ASKS.md +
  docs/SERIOUS-TODOS.md (read the latter before trusting anything shaky).

**Post-ship state on this box:** the package is installed system-wide; `/usr/bin/surveyor`
holds `cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep` (the deliberate opt-in, performed
and reported 2026-07-08).

## ⭐ V1 IS DONE (2026-07-03) — the one loop, shipped

*See, live and by real name, every process on this machine and who it's talking to — and click
any flow to know why.* Built S1→S4 (docs/V1.md), each step verified live on this box:

- **S1 — real identity.** `src/lib/mmdb.zig` (pure-Zig MaxMind reader) + `src/capture/enrich.zig`
  (threaded rDNS resolver + offline GeoIP/ASN) turn `160.79.104.10` into *Anthropic, PBC · US*.
  `flow_upsert` grew `remote_name/asn/as_org/country` (proto v3, trailing-additive); on the wire,
  in `--schema`, and in the TUI/GTK/snapshot renderers. `scripts/fetch-geoip.sh` (DB-IP Lite).
- **S2 — the GTK app.** The label wall → a `GtkListBox` (per-row updates) + a docked **"Why" panel**
  (`src/lib/why.zig`, a pure narration shared with the TUI). Row-select moves the **shared cursor**
  (D24): street focus → `user_state{focus}` upstream. Parent lineage (ppid/pcomm) added (proto v4).
- **S3 — realtime.** eBPF now **fuses** into the inet_diag table (not either/or): short-lived flows,
  UDP/QUIC byte counters (`udp_*` fexit → LRU map), and **passive DNS** (`src/capture/pdns.zig` —
  the box's own :53 answers → true hostnames that outrank rDNS). Fixed a real M2 kernel bug (v6
  addresses were 1-byte-truncated). `table.observe` is fusion-safe (no counter regression).
- **S4 — the visual layer.** `src/lib/appicon.zig` resolves exe/comm → XDG icon name (offline);
  GTK rows wear the app's real icon; the Why panel shows a category chip + a colour-graded
  **exposure risk badge** for listeners (`Exposure.hex()`).

## What to build next (post-V1, the vision resumes)

V1 was built so each of these lands as an addition, not a rewrite. In rough priority:

1. **The duplex command channel (R3).** `serve --json` is still read-only. Let the agent *move*
   the shared cursor it can already see: an upstream NDJSON command on `serve --json --socket`
   (`{"cmd":"focus",...}` → `UserState` → apply). No auth handshake (D25). First agent *write* verb;
   wire it generically so `set-profile`/`lens` come free.
2. **Multi-client broadcast (R1 / atlas).** Surveyor serves one client at a time. For a `shared`
   cursor to reach every observer, add a client registry + fan-out — the natural home for `atlas`
   (D9/D26: essential to the *maximal* vision, out of V1). Start with a Zig multi-client accept loop.
3. **The constellation map.** The force-directed orbit→region→street zoom — the hardest 20% V1
   deliberately deferred, and the thing that makes it *a map*. The `Focus`/`Altitude` seam is built.
4. **Scoring → risk rings.** `Reading`s (impact/confidence) feeding the confidence/impact rings
   (DESIGN-LANGUAGE §2/§4). V1 ships the exposure *badge*; the decomposed rings need the score engine.

See [RESEARCH.md](RESEARCH.md) R1/R3, [V1.md](V1.md) (deferred column), and DECISIONS **D24/D25/D26**.

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
