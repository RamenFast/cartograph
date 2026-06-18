# Cartograph — Design language: colors mean something, icons say what & how-much

Goal you set: **bridge the gap of understanding** for a human at a glance — *what is this,
and how much should I care?* — while staying **fully capable** underneath. The rule:
**nothing is ever just decorative.** Every color, glyph, ring, and badge encodes data, and
every encoding is one click/keypress away from the raw truth behind it.

> **Why fixed meanings?** Because a standard you learn once and trust everywhere is what makes
> truth *teachable* — the black-and-red skull on the back of the microwave. Consistency is the
> point, not the constraint. See VISION.md → "the deeper why — consistency, and the wiring
> diagram in the fridge."

## 1. Color = meaning (fixed, learnable, accessible)

A small fixed palette. A color never means two things; meaning never relies on color
alone (every state also has a glyph + position → colorblind-safe).

| Color | Meaning | Example |
|---|---|---|
| 🟢 **Green** | Known & trusted — you approved it, or it's first-party/signed | your synced browser → its own sync host |
| 🔵 **Blue** | Infrastructure you rely on | DNS, NTP, your router, OS updates |
| 🟦 **Teal** | Content / CDN delivery | Akamai, Cloudflare, Fastly assets |
| 🟡 **Amber** | Unknown / first-seen / wants a look | a host this app never contacted before |
| 🟣 **Purple** | Peer-to-peer / direct peer | torrent, WebRTC, LAN peer |
| 🔴 **Red** | Suspicious / high potential impact | known-bad host, plaintext creds, unexpected listener |
| ⚪ **Dim grey** | Idle / closed / historical | a flow that ended, a past connection |

## 2. The two rings: Confidence and Impact (your "deduced % of potential impact")

Each entity/flow icon is wrapped by up to two thin arcs — a glanceable dial, exact number
on hover/zoom:

```
        ╭───────╮        outer arc  = IMPACT   (0–100): how much it would matter
        │  ⬡   │ ◜       if this turned out hostile (data volume, exposure, plaintext,
        │ logo │  ◞      destination reputation, exfil shape)
        ╰───────╯        inner arc  = CONFIDENCE (0–100): how sure we are of the identity
         ▰▰▰▱▱            (DNS+SNI agreement, ASN match, known-brand, signed process)
```

- Arc **length** = the percentage; arc **color** = the band (green/amber/red for impact;
  solid/dashed for confidence). So "78% impact, 60% confidence" reads instantly as a
  three-quarter red-ish outer arc + a half inner arc.
- **Never a black box.** Selecting the ring shows the line-item breakdown:
  `Impact 78 = plaintext(+30) · 4.2 MB uploaded(+20) · first-seen ASN(+15) · reputation:clean(+0)…`
  The local LLM (ollama) can narrate it in a sentence. Confidence and "this is an
  *estimate*" are always shown — we inform, we don't cry wolf.

## 3. Glyphs — identity first, category fallback

- **Identity (preferred):** the local app's real icon (XDG/.desktop) and the remote
  service's logo (favicon/brand pack, cached). `[Firefox] → [GitHub]`.
- **Category glyph (when identity unknown):** so the map is *always* legible —
  ☁ cloud/CDN · 👁 tracker/ad · ⇄ p2p · ⟳ update · 🔒 trusted · 🛰 infra · 🌐 web ·
  ✉ mail · 🎮 game · 📞 voip · ❓ unknown.

## 4. Corner badges — fast status flags

Small badges on an entity/flow tile: ✦ new · 🔒 encrypted · ⚠ plaintext · 📡 listening/exposed ·
⛔ blocked · 🐢 throttled · 🌍 unexpected-country · ⬆ heavy-upload.

## 5. The impact/confidence scoring model (transparent + explainable)

Inputs (each contributes a weighted, *named* term so the total is always decomposable):
- destination reputation (offline threat-feed / known-bad lists)
- novelty (first time this app↔this ASN/host?)
- encryption (TLS/QUIC vs plaintext; plaintext credentials = big jump)
- volume & direction (upload-heavy to a new host = exfil shape)
- exposure (is this a *listener* the outside world can reach?)
- process trust (system/signed vs user-dropped binary; parent chain sanity)
- ASN/geo expectation (sudden new country/ASN for a known app)
- nDPI class (e.g., "BitTorrent from your banking app" = incoherent → flag)

Outputs: **Impact 0–100** and **Confidence 0–100**, each with a "because…" list. Scores
are advisory estimates, recomputed live as evidence arrives.

## 6. Same language, native in each frontend

- **GTK:** vector rings, smooth motion (pulse = throughput, fade = closing, bloom-in =
  new), real logos, hover tooltips with the breakdown.
- **TUI:** the ring becomes colored Unicode arc segments + a `[▰▰▰▱▱]` confidence bar +
  glyph + badges; logos via kitty-graphics where available, else the category glyph.
- The numbers, reasons, and colors are **identical** — they come from `libcartograph`,
  not the renderer.

## 7. Motion & sound (GTK, optional)
Calm by default. Motion is information: a connection being born blooms; a dying one fades;
throughput modulates a gentle pulse. Optional subtle audio cue only for red-band events
(off by default). Beauty in service of truth.
