# Cartograph — CLI & the "Bloom" terminal UX philosophy

> **Bloom:** the tool opens as a single calm flower and *unfolds* as you lean in. Nothing
> is required to start; every step deeper is discoverable, forgiving, and a little
> delightful. Verbs read like sentences. Help is beautiful. You never memorize flags —
> you *guess right*.

## Bloom principles
1. **Zero-friction start.** `cartograph` with no args just works (launches the best
   available expression and shows the orbit). No required flags, ever.
2. **Verbs, not flag-soup.** You *do* things: `why`, `watch`, `trace`, `peek`, `block`.
   Subcommands read as intent.
3. **Progressive disclosure.** `-h` is a calm one-screen bloom; `--help` unfolds the full
   garden; `cartograph <verb> --explain` narrates what it'll do before doing it.
4. **Forgiving & guessable.** Sensible aliases (`cartograph map` == `orbit`), did-you-mean
   suggestions, every short flag has an obvious long twin, `--dry-run` on anything that acts.
5. **Honest & quiet.** Defaults are safe and observe-only; actions (block/capture) are
   explicit and confirmable. Output is gorgeous but pipeable (`--json`/`--plain`).
6. **Self-aware.** `cartograph doctor` checks the environment; `cartograph why --me` answers
   "what is *my* machine leaking right now?"

## Grammar
```
cartograph [global-opts] <verb> [target] [--lens …] [--since …] [--theme …]
```

## Verbs (the garden)
| Verb | Does | Example |
|---|---|---|
| `orbit` (default) | launch the living map | `cartograph` · `cartograph orbit --gtk` |
| `watch` | live attributed flow list | `cartograph watch --app firefox` |
| `why` | explain a flow/host/pid in plain language | `cartograph why pid:3983` · `why github.com` |
| `peek` | identity/geo/risk card for a host | `cartograph peek 140.82.113.26` |
| `trace` | deep-capture one flow (T2) | `cartograph trace flow:8a3f --export out.pcap` |
| `block`/`allow`/`throttle` | firewall a selector (XDP) | `cartograph block app:telemetry-daemon` |
| `lens` | list/toggle/save lenses & profiles | `cartograph lens save nerd` |
| `ambient` | calm always-on visualization (screensaver) | `cartograph ambient` |
| `replay` | DVR scrub of past traffic | `cartograph replay --since 3h` |
| `doctor` | environment & capability check | `cartograph doctor` |

## Flags (each short has a human long twin)
```
  -g, --gtk            force the GTK expression          -t, --tui    force the terminal expression
  -l, --lens LIST      enable lenses (tls,geo,risk,gpu)  -p, --profile NAME   calm|nerd|security|privacy|resource
  -a, --app NAME       filter to an app                  -s, --since DUR      1h, 30m, today
      --theme NAME     bloom|mono|matrix|paper               --no-fetch       never fetch remote logos (privacy)
      --explain        narrate the action, then ask          --dry-run        show what would happen
  -j, --json           machine-readable out              -P, --plain          no color/glyphs (pipes, logs)
  -v, -vv              verbosity                              --me             scope to "what am I leaking now"
```

## Delightful touches
- `cartograph why --me` → a plain-language paragraph of your machine's current outward life.
- `cartograph peek github.com` → a printable "passport" card (logo, ASN, geo, risk rings).
- `cartograph block app:foo --explain` → shows the severed-connection preview before acting.
- Tab-completion + `did you mean` + man pages that are actually fun to read.

## Man pages (we ship them, and they're a pleasure)
- `cartograph(1)` — the umbrella: philosophy, verbs, examples. **Draft: `surveyor/cartograph.1`.**
- `cartograph-why(1)`, `cartograph-block(1)`, `cartograph-lens(7)` — per-verb depth.
- `surveyor(8)` — the privileged daemon (capabilities, socket, security).
Examples sections are first-class; man pages open with a worked story, not a wall of options.
