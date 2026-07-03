# Cartograph — project structure & collaboration

> For everyone working here — Ben, Claude, **Nexus, hermes**, and any hand that joins. The
> goal is a repo where you can tell *where a thing goes* without asking. Conventions below;
> nothing here is sacred — propose changes in a PR or an `.md`. **We add structure over time,
> we don't enforce it retroactively by deleting.**

## Where things live

```
cartograph/
├── build.zig · build.zig.zon   ← build graph (modules, exes, steps)
├── src/
│   ├── lib/        ← libcartograph: the view-model (ALL features live here)
│   ├── capture/    ← the capture core (inet_diag + /proc today; eBPF in M2)
│   ├── surveyor/   ← the capture CLI (snapshot | serve)
│   └── tui/        ← the first frontend (more frontends = sibling dirs)
├── docs/           ← design + decisions + contracts (the source of truth for intent)
├── man/            ← man pages (installed by the build)
├── experiments/    ← throwaway probes / proofs (named, dated in EXPERIMENTS.md)
├── assets/         ← icons, logo packs, glyphs (logo-cache is gitignored)
├── atlas/          ← shared-presence layer: Elixir/LiveView multi-observer fan-out (essential, D9 amended; scaffold)
└── toolchain/      ← vendored Zig 0.16.0 (gitignored; re-fetch via bootstrap)
```

**The one rule that matters:** a feature lives in `src/lib` (the view-model), never in a
frontend. Renderers are thin. That's what makes TUI/GTK parity structural (D9, FRONTENDS.md).

## Docs conventions
- **Design intent** → a `docs/*.md`. New cross-cutting contract → its own doc (e.g.
  ONTOLOGY, STATE, TOOLCHAIN), linked from README and the relevant ROADMAP milestone.
- **A decision** → an ADR entry in `DECISIONS.md` (Dn), short, with rationale.
- **Superseded** content stays, with a one-line "superseded by Dn" banner — we keep the
  paper trail (see D1). Don't silently rewrite history; annotate it.
- Stale docs are a liability (a future doc inherits the lie). If you spot drift, fix the
  banner or open a note — don't let it rot.

## Collaborator scratch (Nexus / hermes)
- Your durable archive lives **outside** the repo (`~/Nexus/...`) — correct, keep it there.
- In-repo working artifacts (HTML renders, critique drafts, scratch) go under
  **`.dextroesoteric/`**, which is **gitignored** — on disk for you, out of the committed
  history. When a critique produces a *decision*, fold the decision into `docs/` (an ADR or a
  contract doc) and let the long-form critique live in your archive. That way the repo carries
  the *conclusion*, your archive carries the *deliberation*.

## Suggested cleanups (suggestions only — nothing deleted)
Per Ben's standing note: **suggest removal via this file; never delete a collaborator's work.**

- `.dextroesoteric/critique-v3.html` (54 KB generated visual) — now gitignored, so it won't
  enter history. It's already mirrored as markdown in `~/Nexus/archive/🏮Nexus/2026-06-17/`.
  *Suggestion:* keep the markdown as the canonical form; regenerate the HTML on demand rather
  than storing it in the project. No action taken — your call.
- (Future) if `atlas/` stays an empty scaffold past M4, *suggest* either fleshing the remote
  view or moving the scaffold note into a doc and removing the empty dir. Not now.

If you'd rather a different convention, say so — this doc is a starting point, not a verdict.
