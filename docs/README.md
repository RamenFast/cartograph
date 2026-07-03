# Cartograph docs — index & status map

> One screen so a fresh reader (human *or* any model from Opus to Gemma-12b) knows **where
> truth lives** and **what is built vs designed** before reading anything else. The docs run
> ahead of the code on purpose; this map keeps that lead from reading as a lie.

**Status key:** 🟢 built & verified · 🟡 partly built (a real seam exists) · ⬜ design only (aspirational).

## Start here
1. [NEXT-SESSION.md](NEXT-SESSION.md) — the operational handoff (the de-facto current-state source of truth).
2. [VISION.md](VISION.md) — the creative north star (an OS you can *see*; the "why was it sent" layer).
3. This file — the map.

## Where truth lives (when two docs disagree, trust the one named here)
- **Current state / what's actually built:** `NEXT-SESSION.md` + this status map (not the prose docs).
- **Locked decisions & their rationale:** `DECISIONS.md` (ADR ledger; amendments are dated inline).
- **The machine contract (fields/events/enums):** `surveyor --schema` — *generated from the code*, so it cannot drift. Prose mirror: `AGENT-INTERFACE.md`.
- **Why a type exists:** `ONTOLOGY.md`. **What's unsolved:** `RESEARCH.md`.

## The docs, by what they're for

| doc | purpose | build status |
|---|---|---|
| [VISION.md](VISION.md) | north star + foresight features | ⬜ vision (capture proven; map/why/logos unbuilt) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | components, privilege, IPC, tiered capture | 🟡 boundary+IPC built; enrichment/enforcement design |
| [FRONTENDS.md](FRONTENDS.md) | TUI+GTK parity; **`atlas` shared-presence layer**; X11/Wayland | 🟡 TUI+GTK live; atlas scaffold (essential, D9 amended) |
| [AGENT-INTERFACE.md](AGENT-INTERFACE.md) | the agent/Unix surface (NDJSON, `serve --json`, `--schema`) | 🟢 read surfaces shipped; ⬜ command verbs (RESEARCH R3) |
| [DECISIONS.md](DECISIONS.md) | ADR ledger D1–D23 (+ amendments) | 🟢 the record |
| [ONTOLOGY.md](ONTOLOGY.md) | the act ontology (Greeting/Rule/Reading/Ruling) | 🟡 types+IPC thin; no producer/consumer yet (RESEARCH R4) |
| [RESEARCH.md](RESEARCH.md) | foundational open problems (R1 shared focus … R6 UDP) | ⬜ the to-figure-out list |
| [DESIGN-LANGUAGE.md](DESIGN-LANGUAGE.md) | colors/rings/glyphs as data; consequence tree | 🟡 palette/scope in code; rings/tree unbuilt |
| [STATE.md](STATE.md) | persistence + privacy contract | ⬜ contract written; sqlite store unbuilt |
| [DATA-STREAMS.md](DATA-STREAMS.md) | lenses & profiles | 🟡 lens toggles + profiles live |
| [ROADMAP.md](ROADMAP.md) | milestones M0→M9 | 🟡 M1/M2 done; M3+ planned |
| [CLI.md](CLI.md) | the "Bloom" CLI/UX philosophy + verbs | ⬜ aspirational (no arg-parser yet; RESEARCH R3) |
| [GPU.md](GPU.md) | AMD: telemetry · render · compute | 🟡 telemetry proven; render/compute design (D13) |
| [STACK.md](STACK.md) | language/tooling survey + rationale | 🟢 analysis (carries dated historical notes) |
| [EXPERIMENTS.md](EXPERIMENTS.md) | what was tested + results (E1–E4) | 🟢 evidence (all in the capture layer) |
| [TOOLCHAIN.md](TOOLCHAIN.md) | Zig 0.16 freeze/longevity plan | 🟢 plan (D16) |
| [STRUCTURE.md](STRUCTURE.md) | repo layout + collaboration norms | 🟢 layout |
| [PLANNING.md](PLANNING.md) | historical deliberation (pre-rename) | ⬜ historical (working-title "netscope"; superseded) |

## The shape in one breath
**surveyor** (Zig, privileged) is the single producer of truth → **libcartograph** (Zig
view-model: every feature lives here) → rendered three ways that cannot drift from it: the
**local single-observer** expressions (TUI, GTK, agent NDJSON) and the **`atlas` many-observer
fabric** (Elixir/LiveView — the shared-presence layer that lets human + their AI(s) watch one
machine at once; essential, D9 amended). Parity is structural because all three are renderers
over one model.

## A note on the docs-ahead-of-code lead
This is a small codebase (~4.7k lines Zig) under a large design corpus. That's deliberate — the
seams are designed before they're filled — but it has a tax: docs drift when fast work isn't
re-threaded. Two rules keep it honest:
1. **Generated-over-asserted:** the machine contract is `surveyor --schema` (code-derived), not a
   table someone hand-maintains. Prefer code-derived facts wherever possible.
2. **Status-tagged:** every claim of a *feature* should be checkable against this map. If a doc
   says "the map shows…", that's ⬜ until this table says 🟢.
