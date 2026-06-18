# Cartograph — Vision (the creative north star)

> Not "another packet sniffer with a nicer skin." Cartograph treats your machine's
> network life as **territory to be mapped** — and lets you fly from orbit down to the
> bytes without ever changing tools or losing the thread of *why*.

## The core metaphor: cartography + continuous semantic zoom

Wireshark gives you a *list*. Cartograph gives you a *place*. The hero interaction is a
single, continuous zoom — the same gesture takes you from "who is my machine friends
with" to "this byte is the TCP window size":

```
  ORBIT      Your machine at the center of a constellation. Each thing it talks to is
  (L0)       rendered as its LOGO (GitHub, Telegram, Anthropic, your router), sized by
             traffic, colored by category (trust / CDN / tracker / p2p / OS-update).
             You read your network at a glance, like a star map.
                                   │  zoom in on an entity
  REGION     One entity expanded: the local apps talking to it (each with its desktop
  (L1)       ICON), their flows, protocols, ports, geo, ASN owner, first-seen/last-seen.
                                   │  zoom in on a flow
  STREET     One flow: a timeline of packets, RTT, TLS handshake, byte sizes over time,
  (L2)       the TCP state machine, retransmits — the life story of one conversation.
                                   │  zoom in on a packet
  GROUND     One packet: byte-level dissection, field tree, hex — Wireshark-grade depth
  (L3)       (via tshark interop for the long tail of protocols).
```

No mode switches. No second app. The altitude *is* the level of detail.

## The always-present "Why" panel

Whatever is selected, a docked panel narrates it in plain language, generated from the
attribution + enrichment data (and optionally sharpened by a local LLM — `ollama` is
already on this box, so explanations stay **offline and private**):

> **chrome** (PID 3983, started by *you* 14 min ago, parent: `cinnamon-session`)
> opened a **TLS 1.3** connection to **github.com** — *AS36459 GitHub, Inc.* in the US.
> Alive 6m12s, 38 KB up / 410 KB down. Category: **developer / trusted**. SNI matched a
> DNS answer your machine received 6m ago. No payload inspected (encrypted).

The three questions, always answerable:
1. **Why was it sent?** → process, exe path, cmdline, parent chain, user, cgroup/container,
   and the kernel event (socket/exec) that created it.
2. **Where is it / coming from?** → rDNS + your machine's own DNS answers + TLS SNI/QUIC,
   GeoIP, ASN owner, known-service fingerprint, confidence.
3. **What is it? (show me)** → local app icon (XDG/.desktop, offline) + remote logo
   (favicon/brand pack, cached), degrading to a category glyph when unknown.

## Visual language

- **Identity over addresses.** Default to `[Firefox] → [GitHub]`, not `34221 → 140.82.121.4`.
  IPs are available on hover/zoom, never the headline.
- **Category color + glyph** as the universal fallback so the map is always legible even
  for unknown endpoints: ☁ cloud/CDN · 👁 tracker/ad · ⇄ p2p · ⟳ OS/update · 🔒 trusted ·
  ⚠ unexpected/new.
- **Motion = truth.** Live flows pulse with throughput; new entities arrive with a subtle
  animation; a dying connection fades. The map *breathes* with your traffic.
- **Calm by default, deep on demand.** Orbit view is quiet and readable; firehose detail
  is always one zoom away but never forced on you.

## What makes it unique (and worth building)

- The **why/who/show-me layer** — nothing on Linux combines kernel-accurate process
  attribution, human identity with logos, and full dissection in one continuous view.
- **Tiered by design** so it's a featherweight always-on monitor *and* a deep analyzer:
  cheap eBPF counting always on; full packet capture only on the flow you click.
- **Private by construction** — enrichment and explanations run locally (offline MMDB,
  on-box LLM); logo fetches are cached/rate-limited/opt-in so the tool itself doesn't
  leak your browsing.
- **A genuinely cool stack** (Zig on the metal + BEAM for the live map) that is also the
  *right* engineering choice, not novelty for its own sake.

## Ethos

Fast, honest, and quiet. It should make a curious person say *"oh — so THAT's what my
laptop is doing"* within ten seconds of opening it, then reward them all the way down to
the byte when they want it. Beauty in service of truth, not decoration.

## Scope notes
- **Active blocking/firewalling is in scope** (you asked for it): observe-first, then
  per-app / host / flow **allow · block · throttle** via XDP — Little-Snitch-on-Linux, but
  *visual*. Rules are objects on the map you can see and undo, never buried in config.
- **Designed for X11 *and* Wayland from day one** (Wayland is coming for you): GTK4 is
  natively both; we avoid Xlib; any future overlay goes through wlr-layer-shell / XDG
  portals behind one runtime-selected trait. See [FRONTENDS.md](FRONTENDS.md).
- **Out of scope for v1:** TLS interception / payload decryption — huge trust + complexity
  cost, and metadata (SNI, cert, sizes, timing) is enough to be valuable. Revisit only as
  an explicit, local, opt-in keylog.

---

## Foresight — unique offerings for a *home* Linux machine (my picks, with conviction)

Not just a better monitor — a new kind of object on your desktop. These feed the
"computer-as-a-place-you-can-see" vision and, I think, are what would make people fall in
love with it:

1. **A home map that remembers.** Name & tag entities ("my NAS", "mom's VPN", "work").
   Over weeks the constellation becomes *yours* — a personal cartography of your digital
   home. First-time-seen things glow amber until you greet them.
2. **Time-travel (DVR for your network).** Scrub backward through the day's map. "What was
   my laptop doing at 3am?" Replay the constellation; watch a flow bloom and die. Memory,
   not just monitoring.
3. **The daily postcard.** Each morning, a one-paragraph, locally-generated (ollama)
   digest: *"Yesterday: 47 services across 9 countries, 3 new; a listener appeared on :8080
   (it was Steam). Nothing alarming."* Calm, narrative, private.
4. **Causality, not just connections — the "why-chain."** Click a flow → see its causal
   ancestry (*systemd timer → apt → a Canonical CDN*). The deepest form of "why was it
   sent": what *caused* this packet.
5. **"What can the world see of me?" — the mirror.** A sonar mode that flips to your
   **attack surface**: every listener, what's reachable from the LAN vs the internet,
   rendered as exposure. Most people have never seen this about their own machine.
6. **Cross-resource fusion (already proven via `sysmon.zig`).** Net + CPU + **GPU** + RAM +
   energy as one place. Watch a flow light up a core and VRAM; learn that "those 6 GB of
   VRAM are the local model explaining your traffic." The first brick of the visible OS.
7. **The connection passport.** Any flow → a shareable card (logo, identity, geo, risk
   rings, reasons) to save or hand to someone: *"is this safe?"* Makes the invisible
   forwardable.
8. **Blocking as storytelling.** Block something and the map *shows* the severed link;
   rules are visible, undoable objects — never opaque iptables.
9. **Ambient mode — the aquarium.** A calm, always-on visualization for a spare monitor:
   your machine's network life as living art. Makes the computer feel *alive and at home*.
10. **Private & honest by construction.** Offline GeoIP, on-box LLM, opt-in cached logos —
    the tool watching your privacy never sells you out, and shows its *own* traffic on the
    same map. No hypocrisy.

### Where this is going (your north star)
Cartograph is the **network chapter of a bigger idea: an operating system you can *see*** —
a point-and-click adventure where every packet, every byte of memory, every watt of
CPU/GPU has a face, a story, and a place. Making the computer feel like *home* — knowable,
legible, yours. We start with the network because it's the most mysterious and the most
revealing; the architecture (one core, many expressions, cross-resource lenses) is
deliberately built so the same approach extends to memory, processes, disk, and power next.
