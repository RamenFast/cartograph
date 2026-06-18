# Cartograph — Data streams / "Lenses" (togglable information layers)

You asked for new, togglable data categories for live presentation. Cartograph models
every information layer as a **lens** — an overlay/column/stream you switch on or off.
**Calm by default** (a handful on), **deep on demand** (stack as many as you want). Lenses
are the same in TUI and GTK because they're computed in `libcartograph`, not the UI.

## The catalog

### Identity (who/what is running it)
- App icon · executable path · command line · **parent-process chain** · user/UID ·
  cgroup/container · systemd unit · process start time & who launched it.

### Endpoint (where it's going)
- rDNS · **your machine's own DNS answer** (truthful name, not just PTR) · TLS **SNI** /
  QUIC SNI · certificate issuer/subject · **JA3/JA4** client fingerprint · GeoIP +
  country flag · **ASN owner** · service fingerprint ("GitHub / Telegram / NTP / router").

### Volume & performance (how much / how well)
- Throughput ↑/↓ (live sparkline) · total bytes · packet rate · **RTT/latency** ·
  retransmits / loss · TCP window · congestion state · connection age/lifetime.

### Classification (what kind of traffic)
- **nDPI app/protocol** (Netflix vs generic HTTPS, BitTorrent, etc.) · category ·
  encrypted? · **plaintext-leak detector** (credentials/tokens in the clear).

### Risk (how much should I care) — see DESIGN-LANGUAGE.md
- Impact score · confidence · novelty (first-seen) · threat-feed hits · **exposure**
  (are you listening to the world?) · exfil heuristic (upload-heavy to new host).

### System / cross-resource (the "see your whole computer" seed — proven: sysmon.zig)
- Per-process CPU% · **GPU correlation** (this flow vs amdgpu busy/VRAM/power) · estimated
  **energy & data cost** per app · process disk I/O. (e.g., "ollama is using 6 GB VRAM to
  explain your traffic" — self-aware and delightful.)

### Temporal (history & change)
- Live timeline · per-app daily totals · **"what changed since yesterday"** · DVR-style
  replay/scrub · retention windows.

### Security / attack surface
- Listening ports · **what the world can see of you** (inbound exposure map) · open
  inbound connections · new-listener alerts.

## Toggling & presets
- CLI: `--lens tls,geo,risk,gpu` (add) · `--lens=-volume` (drop) · `cartograph lens ls`.
- TUI: a lens bar; number keys toggle; `L` opens the picker.
- GTK: a lens side-panel with labeled switches; drag to reorder columns.
- **Profiles** (named bundles you can switch with one key):
  - **Calm** — identity + throughput + risk band only.
  - **Nerd** — + RTT, window, nDPI, JA4, ASN.
  - **Security** — + exposure, novelty, threat hits, plaintext detector.
  - **Privacy** — + trackers, third-party, geo, "who am I leaking to."
  - **Resource** — + CPU/GPU/energy correlation.

## Extensibility (later)
User-defined lenses via a tiny declarative rule format (match on fields → derive a
column/badge/score term). Lets the community add "is this a known ad network?" or
"flag anything talking to country X" without touching the core. Tracked in ROADMAP.
