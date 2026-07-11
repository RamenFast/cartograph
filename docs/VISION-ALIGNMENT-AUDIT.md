# Vision alignment audit

> **Handoff target:** Fable, next session  
> **Audit date:** 2026-07-11  
> **Scope:** substantial repository problems and inconsistencies, ranked by importance. This is an audit, not an implementation plan. It deliberately does not prescribe fixes.

## The project vision that should govern the next session

Cartograph should be **the local-first, living network operating surface for a home Linux machine**, not merely a polished connection table.

Its defining promise is one continuous, identity-first map of the machine's network life:

- **Orbit → region → street → ground** is one spatial interaction, from the whole machine to an entity, flow, packet, and byte.
- It answers three questions from the same truth model: **why was this sent, who/what is it, and where is it going?**
- Human and agent are equal co-inhabitants. They observe and control the same session, see the same focus and consequences, and neither is relegated to a lower-fidelity side channel.
- The system is **private, local, honest, reversible, and explainable**. Risk and confidence are decomposable rather than asserted. Degraded capture is visible rather than silent.
- Every meaningful capability is available through the visual UI **and** an easy native Bash CLI with human output, JSON/NDJSON, strict self-description, stable exit behavior, and visible UI feedback when an agent acts.
- One privileged capture core owns truth. Multiple human and agent observers render it without launching divergent captures or private state worlds.

The shipped V1 is a useful attributed-flow monitor and a credible foundation. It is not yet the defining Cartograph experience above. Future work should not let the phrase “V1 shipped” collapse the larger vision into the current table UI.

## Where the workspace-wide human/UI/JSON/agent-native ideal lives

Fable should treat these as the governing sources, in this order after Ben's in-the-moment direction:

1. **Workspace governance:** `/home/ben/Dev/ClaudeWorkspace/AGENTS.md`
   - §2 names the shared CLI standard and Concourse.
   - §3 requires UI actions for essential CLI functions.
   - §6 requires both-readable artifacts, checked claims, and errors that name the fix.
2. **Normative workspace CLI law:** `/home/ben/Dev/ClaudeWorkspace/AGENT-CLI-STANDARD.md`
   - Native Bash verbs, human/JSON duality, one-shot envelopes, NDJSON streams, `schema`, exit codes, fix-bearing errors, atomic mutation, and Concourse enforcement.
3. **Normative core convention:** `/home/ben/Dev/ClaudeWorkspace/NexusFormStationWork/CONVENTION.md`
4. **Live conformance check:** `concourse doctor --json`
5. **Visual/UI behavior law:** `/home/ben/.agents/skills/ben-ui-design/SKILL.md`
   - In particular, essential CLI actions must be visual buttons with feedback, not command snippets that send the human back to a terminal.

### Where Cartograph stands against that ideal

Cartograph is one of the historical sources of the standard and has a strong **read** surface: `snapshot`, `status`, `serve --json`, `--schema`, isatty-aware output, and a shared data model. It is not currently a conformant **control** surface.

At audit time, `concourse doctor --json` reported **61 pass, 3 warn, 0 fail**, with both Cartograph-specific warnings stating that `surveyor status` lacks canonical `version` and `ts`. The larger gap is not fully measured by Doctor: agents cannot drive the application through JSON commands, the GUI cannot show feedback for such actions, and the human/agent shared-focus promise is not operational.

---

## Ranked findings

### 1. The defining “map” experience does not exist yet

**Context:** `docs/VISION.md:7-30`, `docs/VISION.md:50-60`, `docs/V1.md:27-40`, `src/gtk/main.zig:451-544`, `src/tui/main.zig:355-465`, `assets/hero.png`.

The primary GTK surface is a dense list of flows with columns for app, endpoint, owner, rate, total, and RTT. The TUI is another table. Selecting a row changes a textual focus label, but there is no spatial orbit, entity region, flow timeline, packet ground layer, or continuous semantic zoom. The repository is honest in several places that the constellation map was deferred, but the public identity remains “a living map,” and the name/metaphor are load-bearing.

**Why it matters:** This is the feature that distinguishes Cartograph from a polished network monitor. Until it exists, the product's central differentiator is absent rather than incomplete.

**Confidence:** High.

### 2. The normal double-click GUI path never requests eBPF, so the advertised opt-in does not improve the main application

**Context:** `README.md:44-49`, `README.md:51-60`, `src/gtk/main.zig:846-869`, `src/surveyor/main.zig:150-160`.

The package tells users that granting capabilities to `/usr/bin/surveyor` unlocks short-lived flows, UDP/QUIC byte counters, and passive DNS. However, the GUI's private producer is spawned as exactly `surveyor serve`, without `--bpf`. An Xvfb process-tree verification showed:

```text
cartograph-gtk
└─ surveyor serve
```

The source only attempts the hybrid eBPF path when `want_bpf` is true, which is set by the `--bpf` flag. Merely granting capabilities does not make the desktop launcher use them.

**Why it matters:** The easiest and most visible product path silently remains the lower-fidelity polling path even after the user performs the documented privilege opt-in. This directly weakens the shipped V1 claims around realtime capture and true hostnames.

**Confidence:** High.

### 3. The agent can observe but cannot control the application through the promised Bash/JSON surface

**Context:** `docs/AGENT-INTERFACE.md:129-134`, `docs/RESEARCH.md:101-110`, `docs/NEXT-SESSION.md:61-64`, `src/surveyor/main.zig:551-626`, `man/cartograph.1.scd:26-45`, `man/cartograph-gtk.1.scd:27-34`.

There is no JSON command surface for `select`, `focus`, `why`, `set-profile`, lens control, greeting, rule creation, blocking, or any other UI state/action. `serve --json --socket` is an outbound stream only. The binary socket can receive a narrow `user_state` subset from the native frontends, but that is not an agent-legible Bash/JSON command interface. `cartograph` and `cartograph-gtk` have neither `--json` nor `schema`.

**Why it matters:** This is the largest gap against the workspace-wide ideal the user explicitly asked Fable to honor. Agents do not have equal control, and no agent action can produce visual UI feedback because no agent action path exists.

**Confidence:** High.

### 4. The shipped “shared cursor” does not connect the human's selection to the agent stream

**Context:** `src/gtk/main.zig:647-665`, `src/tui/main.zig:225-254`, `src/lib/focus.zig:54-60`, `src/lib/session.zig:70-85`, `src/surveyor/main.zig:407-448`, `src/surveyor/main.zig:551-574`, `docs/AGENT-INTERFACE.md:53-69`.

GTK and TUI construct selection focus without setting `shared = true`, so the focus is view-local by definition. If a truly shared focus arrives, `SessionState.apply` explicitly returns false, and `ClientLink.pump` ignores the frame because it only reacts when `apply` returns true. Separately, `serve --json` emits one default orbit focus on connection and never consumes or follows frontend focus changes.

The comments say row selection travels upstream so “surveyor + any watching agent follow along,” but the state flow does not do that.

**Why it matters:** Human-agent co-observation is not a future embellishment in the vision. It is the core full-trust experiment. The current implementation creates the vocabulary and visual label without delivering the shared behavior.

**Confidence:** High.

### 5. “One capture core, many observers” is false in the live daemon

**Context:** `README.md:58-60`, `docs/ARCHITECTURE.md:10-17`, `docs/NEXT-SESSION.md:65-67`, `src/surveyor/main.zig:529-548`, `src/surveyor/main.zig:617-627`.

Both binary and JSON socket servers accept one client and enter that client's infinite stream loop before accepting another. A live probe confirmed that the first client received data while a second connected client timed out until the first disconnected. Each accepted stream also constructs its own capture source, flow table, and enricher inside the stream loop.

**Why it matters:** The architecture does not yet provide one authoritative live truth to simultaneous GUI, TUI, agent, and atlas observers. It also makes the README's “many observers” usage example materially misleading.

**Confidence:** High.

### 6. The “Why” panel does not answer causal why

**Context:** `docs/VISION.md:31-49`, `docs/V1.md:18-25`, `src/lib/why.zig:33-112`, `src/gtk/main.zig:546-581`, `src/tui/main.zig:401-458`.

The current narration lists process, executable, parent, endpoint, owner, protocol/service, traffic, latency, and timestamps. That is useful attribution and description, but it does not establish why an application initiated the connection, what user/app event caused it, what request or subsystem owns it, or what consequence it serves. The label “Why” currently overstates a metadata inspector.

**Why it matters:** “Why was it sent?” is one of the three permanent questions and a headline uniqueness claim. Renaming metadata as causal explanation risks freezing an incomplete interpretation of the vision.

**Confidence:** High.

### 7. eBPF state events can attach an unrelated process identity

**Context:** `src/capture/bpf/event.h:7-19`, `src/capture/bpf/cartograph.bpf.c:69-77`, `src/capture/bpf.zig:82-100`, `src/lib/table.zig:63-83`.

The kernel program distinguishes `CG_CONNECT` from generic `CG_STATE` because only the connect transition is expected to run in reliable process context. Its own comment says other transitions may occur in softirq context and the current PID may be unrelated. Userspace carries `kind` in `CgEvent` but `toObservation` ignores it and forwards every PID/UID/comm into the shared table.

**Why it matters:** A wrong attribution is worse than an honest `pid:0`. The application's central promise is to tell the truth about which process caused network activity.

**Confidence:** Medium-high.

### 8. Exposure badges claim real reachability while only classifying bind addresses

**Context:** `src/lib/flow.zig:120-135`, `src/lib/identity.zig:218-256`, `src/lib/identity.zig:276-289`, `docs/STATE.md:70-94`.

The UI says `internet` means “reachable from the internet,” but the classifier does not inspect routes, firewall rules, NAT, interface role, or overlay networks. It treats any specific non-RFC1918 address as internet-exposed. `100.64.0.0/10` is not considered private, so a live Tailscale listener at `100.114.165.77` was emitted as `internet` with the red `#ff5f5f` badge. Conversely, `0.0.0.0` and `::` are always only `network`, even when a service may actually be internet-reachable.

**Why it matters:** This is a security-facing truth claim. False red alerts teach the user not to trust the risk language, while false amber can understate actual exposure.

**Confidence:** High.

### 9. The Unix socket exposes sensitive flow state to unauthenticated local clients

**Context:** `src/lib/usock.zig:40-58`, `src/surveyor/main.zig:473-495`, `src/surveyor/main.zig:529-548`, `src/lib/ipc.zig:86-116`.

The listener performs no explicit permission tightening and no peer credential check. A live probe observed a mode of `srwxrwxr-x`, and an unauthenticated local client received IPC bytes immediately. The stream contains PIDs, UIDs, process names, executable paths, local and remote endpoints, owners, and traffic counters.

**Why it matters:** Cartograph's privacy posture says the watcher must not become the leak. The socket is also intended as the future control boundary, so this becomes more consequential as mutation verbs arrive.

**Confidence:** High.

### 10. “Identity over addresses” is not achieved consistently

**Context:** `docs/VISION.md:50-56`, `docs/V1.md:18-21`, `src/gtk/main.zig:514-523`, `src/tui/main.zig:482-493`, `assets/hero.png`.

High-visibility rows frequently headline raw IP addresses or infrastructure PTR names. Offline ASN/country ownership improves context, but service identity remains weak, remote logos are absent, and CDN/infrastructure hostnames are not the same thing as “GitHub,” “Anthropic,” or the human-recognizable destination promised by the vision.

**Why it matters:** Identity is the main perceived-value leap that V1 was meant to close. The current implementation often provides ownership metadata rather than actual product/service identity.

**Confidence:** High.

### 11. The product still forgets everything when it stops

**Context:** `docs/STATE.md:9-44`, `docs/README.md:31-33`, `docs/ROADMAP.md:70-83`, `src/lib/session.zig:13-22`.

There is no implemented sqlite state, history/DVR, greeting store, rules store, readings/rulings log, or persistent identity verdicts. Live flows and all user-authored state disappear with the process.

**Why it matters:** The “witness voice,” time travel, postcards, “what changed,” durable trust decisions, and visible rules all depend on memory. This is a foundational product limitation, not merely another planned lens.

**Confidence:** High.

### 12. Orbit-to-byte stops at a row inspector

**Context:** `docs/VISION.md:18-29`, `docs/ROADMAP.md:107-109`, `docs/V1.md:27-40`, `src/lib/focus.zig:28-51`.

The type system names street and ground altitudes, but there is no per-flow packet timeline, on-demand payload capture, packet selection, field tree, hex view, pcap export, or tshark dissection. `ground` is a representable enum state without a working ground surface.

**Why it matters:** “All the way down to the byte without changing tools” is the second half of Cartograph's defining interaction.

**Confidence:** High.

### 13. Risk scoring, consequence explanation, and enforcement are mostly vocabulary without behavior

**Context:** `docs/DESIGN-LANGUAGE.md:28-48`, `docs/DESIGN-LANGUAGE.md:62-117`, `docs/ROADMAP.md:111-116`, `src/lib/ipc.zig:42-60`, `src/lib/ontology.zig:1-5`, `src/surveyor/main.zig:440-446`.

The application has category colors and a bind-scope badge, but not the decomposed impact/confidence engine, risk rings, consequence tree, durable allow/block/throttle rules, XDP enforcement, or undo history. Rule/Reading/Ruling frames are reserved and serializable, but there are no real producers/consumers, and surveyor ignores non-`user_state` upstream frames.

**Why it matters:** The UI currently looks more safety-aware than the underlying decision system is. The vision's honest, explainable action model is not operational.

**Confidence:** High.

### 14. Degraded capture and enrichment are invisible in the normal GUI

**Context:** `docs/SERIOUS-TODOS.md:25-42`, `src/gtk/main.zig:846-869`, `src/surveyor/main.zig:150-170`, `src/lib/json.zig:101-165`.

Missing GeoIP, eBPF fallback, passive-DNS failure, and capability posture are printed to stderr. A menu-launched GUI gives the user no visible indication of which data sources are active. `surveyor status` reports flow/listener counts but not capture mode, eBPF attachment, passive-DNS state, GeoIP database presence, or reason for degradation.

**Why it matters:** The human cannot tell whether “everything” means polling-only, no UDP counters, no passive DNS, or no owner geography. Silent-looking degradation undermines trust in the view.

**Confidence:** High.

### 15. “Every process” and “see everything” claims overstate real attribution coverage

**Context:** `README.md:3-4`, `docs/NEXT-SESSION.md:37-45`, `src/lib/flow.zig:223-229`, `src/lib/why.zig:50-65`.

A live `surveyor status` audit reported 61 attributed flows out of 126. The code explicitly represents `pid:0` for kernel, other-user, inaccessible, and already-gone processes. The known-service fallback makes these rows more legible, but it does not identify every process.

**Why it matters:** Complete attribution is the primary headline. Honest unknowns are acceptable, but absolute public wording is not aligned with observed behavior.

**Confidence:** High.

### 16. The shipped CLI violates the current workspace envelope and error contract

**Context:** `/home/ben/Dev/ClaudeWorkspace/AGENT-CLI-STANDARD.md:27-39`, `src/lib/json.zig:125-165`, `src/surveyor/main.zig:92-100`.

`surveyor status` emits `status`, `tool`, `proto_version`, and `ts_ms`, but no canonical tool `version` or ISO-8601 `ts`. Bad commands and bad arguments exit `2` rather than the required `3`. Errors are plain stderr text and do not provide structured `error` plus `fix` fields.

Live verification:

```text
concourse doctor: surveyor one-shot missing version
concourse doctor: surveyor one-shot missing ts
surveyor definitely-not-a-verb: exit 2
```

**Why it matters:** Cartograph is an exemplar and historical seed of the workspace standard. Drift in the flagship weakens every agent that expects one convention across applications.

**Confidence:** High.

### 17. `surveyor --schema` is descriptive prose, not the strict self-description contract the workspace standard now requires

**Context:** `/home/ben/Dev/ClaudeWorkspace/AGENT-CLI-STANDARD.md:37-39`, `src/lib/json.zig:265-370`.

The schema output has no standard one-shot envelope, no tool version or timestamp, no `additionalProperties: false`, no formal per-verb argument schema, no strict output object schemas, and only `0` versus `nonzero` exit-code documentation. It also describes `remote_name` as “SNI/passive-DNS later” even though passive DNS is shipped.

**Why it matters:** A zero-context agent can discover field names, but cannot reliably validate calls, distinguish argument failures, or reason about all supported options from this artifact alone.

**Confidence:** High.

### 18. NDJSON/event behavior remains inconsistent with the workspace convention

**Context:** `/home/ben/Dev/ClaudeWorkspace/AGENT-CLI-STANDARD.md:60-65`, `src/lib/json.zig:22-36`, `src/lib/json.zig:167-256`, `docs/AGENT-INTERFACE.md:47-51`.

Live stream lines use the grandfathered discriminator `ev` rather than canonical `event`, while snapshot NDJSON lines have no event discriminator at all. The schema simultaneously uses `protocol_version`, status uses `proto_version`, and the standard reserves `version` for the tool version.

**Why it matters:** These are small individually, but they force special-case parsers in the exact surface intended to eliminate per-tool special cases.

**Confidence:** High.

### 19. Normal short Unix consumers make `serve --json` look like it crashed

**Context:** `src/surveyor/main.zig:25-27`, `src/surveyor/main.zig:587-612`.

Although SIGPIPE is ignored deliberately, write/flush failure propagates to the top level. The safe probe:

```bash
surveyor serve --json | head -n 1
```

returned the hello object, then exited 1 and printed `error: WriteFailed` to stderr.

**Why it matters:** `head`, bounded `jq`, samplers, and agents that intentionally stop reading are ordinary Unix consumers. A normal disconnect should not resemble a runtime failure.

**Confidence:** High.

### 20. Accepted socket descriptors leak across client disconnects

**Context:** `src/surveyor/main.zig:538-548`, `src/surveyor/main.zig:620-627`.

`defer close(cfd)` is declared inside an infinite accept loop, so it does not execute at the end of each iteration. A runtime probe with sequential short clients increased the daemon's open descriptor count from 4 to 8 and left accepted socket descriptors behind.

**Why it matters:** Repeated observer connections slowly degrade a long-running daemon and can end in descriptor exhaustion.

**Confidence:** High.

### 21. The socket path handler can delete an arbitrary existing path before binding

**Context:** `src/lib/usock.zig:40-52`.

`listen(path)` unconditionally calls `unlink(path)` before `bind` and does not verify that the existing path is a stale socket owned by the current user. This was confirmed by code inspection and was not destructively reproduced.

**Why it matters:** A typo, bad script, or future agent command can delete a user-owned file. The risk is more serious because surveyor is designed to carry capabilities.

**Confidence:** High.

### 22. “Parity by construction” is true for portions of the data model, not for complete capabilities or interaction

**Context:** `docs/FRONTENDS.md:3-7`, `CARTOGRAPH-STATION.html:76-78`, `README.md:15-22`, `src/gtk/main.zig`, `src/tui/main.zig`, `src/lib/json.zig`.

GTK has clickable header controls, app icons, and a docked panel. TUI has sparklines and terminal navigation. The agent stream has fields but no Why narration or control verbs. The default GUI and local TUI launch different capture configurations. Shared derivations reduce data drift, but the broader claim that a capability added once “appears everywhere” is not true.

**Why it matters:** Overstating structural parity can hide real accessibility and agent-equality work because the architecture is assumed to guarantee behavior it does not guarantee.

**Confidence:** High.

### 23. The station page documents commands but does not control the application

**Context:** `/home/ben/.agents/skills/ben-ui-design/SKILL.md` hard rule 7, `CARTOGRAPH-STATION.html:63-95`.

The station signpost provides command blocks and `jq` recipes for status, snapshot, stream, and schema. Its interactive elements are theme switching and informational popouts. It has no buttons that execute the essential flows or display live results and action feedback.

**Why it matters:** This directly violates the house rule that an essential CLI action must also be a button. It also leaves the workspace's central human interface disconnected from Cartograph's working agent surface.

**Confidence:** High.

### 24. The GTK theme is a hardcoded Blossom Dark skin rather than the house theme family

**Context:** `/home/ben/.agents/skills/ben-ui-design/SKILL.md` hard rule 5, `src/gtk/main.zig:154-226`, `docs/NEXT-SESSION.md:20-23`.

The native app embeds one dark CSS palette. It has no Blossom default plus maintained light/dark alternates, no theme control, and no integration with the active Blossom family selection. The station HTML does have three themes, so the project's own surfaces differ.

**Why it matters:** Theme consistency is part of the shared application language, not merely decoration. A single hardcoded skin prevents system-level visual coherence and accessibility choice.

**Confidence:** High.

### 25. Test totals are healthy, but the public applications and daemon behavior are largely outside the test target

**Context:** `build.zig:153-162`.

`zig build test` runs the library, capture, and optional BPF module tests. It does not test the `surveyor`, TUI, or GTK entry points; CLI parsing and exits; JSON envelopes; process spawning; default desktop capture mode; socket accept lifecycle; multi-client behavior; shared focus end to end; broken pipes; packaging; or installed behavior. The suite passed 73/73 base and 78/78 with BPF while several high-impact runtime defects above remained present.

**Why it matters:** The current green count creates more confidence than the coverage supports. Critical integration promises are only verified manually and can regress unnoticed.

**Confidence:** High.

### 26. There is no continuous-integration gate for a shipped multi-surface system

**Context:** repository file inventory and absence of `.github/workflows`, other CI YAML, or equivalent checked-in automation.

The repo ships Zig library code, CLI contracts, eBPF compilation, GTK, desktop metadata, man pages, deb/rpm packaging, and release assets, but none are exercised automatically on repository changes.

**Why it matters:** Architecture-, kernel-, distro-, and packaging-sensitive behavior has no durable regression gate beyond the maintainer's current machine.

**Confidence:** High.

### 27. The current-state documentation hierarchy points to stale and contradictory documents

**Context:** `docs/README.md:14-18`, `docs/README.md:22-39`, `docs/NEXT-SESSION.md:37-74`, `docs/NEXT-SESSION.md:149-174`, `docs/ROADMAP.md:70-133`, `docs/V1.md:90-143`, `docs/DECISIONS.md:195-201`.

The docs index calls itself and `NEXT-SESSION.md` the current-state authority, but its status table still says the map/Why/logos are unbuilt, CLI is aspirational, and M3+ is planned. Later sections of `NEXT-SESSION.md` send the next session toward work its opening section says already shipped. ROADMAP leaves app icons, narration, and packaging in future milestones. V1 describes `GtkColumnView` and TLS SNI while the shipped code uses `GtkListBox` and deliberately omits SNI. Decision records retain both zig-gobject and direct-C-FFI statements.

**Why it matters:** A new agent following the explicitly documented truth order can be sent into completed work, rely on unbuilt behavior, or misunderstand the current architecture.

**Confidence:** High.

### 28. The atlas “scaffold” is an empty directory

**Context:** `docs/README.md:26`, `docs/DECISIONS.md:70-96`, `docs/FRONTENDS.md:66-89`, `docs/STRUCTURE.md:22`, `atlas/`.

Multiple documents call `atlas/` a scaffold, but the directory contains no files and is not represented in the tracked file inventory. It is a placeholder path, not a runnable or inspectable scaffold.

**Why it matters:** Atlas is the named home of multi-observer presence and shared focus. Calling an empty directory a scaffold makes the central co-observation work appear started when it is not.

**Confidence:** High.

### 29. Release usability has acknowledged but still material gaps

**Context:** `docs/SERIOUS-TODOS.md:19-42`, `packaging/build-deb.sh:32-52`, `packaging/build-rpm.sh:30-59`, `README.md:44-49`.

The RPM has not been installed on an RPM-native distribution. The single package imposes GTK on headless users. eBPF capability setup is an out-of-band command and there is no first-run doctor/UI path that confirms the result. The normal GUI then fails to request eBPF anyway, as finding 2 describes.

**Why it matters:** The release exists and builds cleanly, but “easy to use” is not yet true for the highest-value capture mode or for non-GTK deployments.

**Confidence:** High.

### 30. The published hero and the screenshot privacy contract are in tension

**Context:** `assets/hero.png`, `docs/STATE.md:63-68`, `docs/NEXT-SESSION.md:9-14`.

The hero visibly includes process names, `/home/ben/...` executable paths, PID/UID, local addresses, remote endpoints, Tailscale infrastructure names, traffic totals, and timestamps. The repository says the image was endpoint-reviewed and the privacy contract explicitly discusses endpoint review, but the screenshot exposes substantially more machine state than endpoints alone.

**Why it matters:** Even if every visible endpoint was judged acceptable, the review contract and actual sensitive surface are not aligned. This matters for every future screenshot of a tool whose purpose is to reveal private machine activity.

**Confidence:** Medium-high.

### 31. The visual hierarchy remains log-like and does not surface “what should I care about?” strongly enough

**Context:** `docs/VISION.md:57-60`, `docs/DESIGN-LANGUAGE.md:3-6`, `src/gtk/main.zig:499-544`, `assets/hero.png`.

Most flow rows carry similar visual weight. Newness, unexpected identity, listener exposure, upload-heavy behavior, attribution uncertainty, and actionable risk do not dominate the scan. Category color and a fresh dot exist, but the information hierarchy is still primarily a sortable feed.

**Why it matters:** The product promise is calm understanding within ten seconds, not merely a more attractive firehose.

**Confidence:** Medium-high.

### 32. Aspirational CLI and frontend documents are easy to mistake for shipped reference material

**Context:** `docs/CLI.md:27-56`, `docs/DATA-STREAMS.md:44-54`, `docs/FRONTENDS.md:20-39`, actual `cartograph --help` and man pages.

The docs describe verbs such as `orbit`, `watch`, `why`, `peek`, `trace`, `block`, `lens`, `ambient`, `replay`, and `doctor`; lens flags; semantic zoom keys; mouse support; kitty graphics; confidence arcs; and other behavior not present in the binaries. Some documents label parts as deferred, but the command tables themselves read like reference documentation.

**Why it matters:** Human and agent readers can form incorrect executable assumptions. The repository's docs-ahead-of-code policy needs sharper separation between design source and operational reference.

**Confidence:** High.

---

## Verified baseline so Fable does not repeat the audit

The following passed during this audit:

- `./toolchain/zig-x86_64-linux-0.16.0/zig build test --summary all` → **73/73 tests passed**.
- `./toolchain/zig-x86_64-linux-0.16.0/zig build test -Dbpf=true --summary all` → **78/78 tests passed**.
- Full build with `-Dbpf=true -Dgtk=true` → **11/11 build steps succeeded**.
- GTK launched successfully under private Xvfb.
- `surveyor status`, `snapshot --json`, `--schema`, and `serve --json` emitted parseable JSON/NDJSON in their successful paths.
- `concourse doctor --json` → **61 pass, 3 warn, 0 fail**. Cartograph warnings were missing canonical `version` and `ts`; the third warning was unrelated (`ollama` unavailable).
- Repository was clean before this audit file was added.

The green unit/build baseline is real. The audit findings are primarily integration, truth-model, product-vision, privacy, and interface-contract failures that the current test graph does not cover.

## Final orientation for Fable

Do not treat all 32 findings as equal-size work items. The ranking is intentional. The first session should preserve the larger product identity while recognizing that the most damaging current failures are the ones where the software **claims shared truth or higher-fidelity capture but silently does something else**.

The highest alignment pressure is therefore:

1. the real map rather than table-only product identity;
2. equal human/agent control with visible shared feedback;
3. one authoritative multi-observer capture/session;
4. truthful capture, attribution, exposure, and degradation semantics;
5. only then the accumulated contract, documentation, packaging, and visual-polish drift.

This document intentionally stops at naming problems and context. Fable should decide the implementation sequence in the next session from the governing vision and standards above.
