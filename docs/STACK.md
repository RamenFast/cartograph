# netscope — power tools, real-time, and esoteric-language stack

Answers three questions raised during planning:
1. Is Wireshark the right foundation? What's faster / more extensible for *our* use?
2. Is real-time achievable?
3. What "weird cool unique" language should this be in — and is that a good idea?

---

## 1. Is Wireshark good? (yes — but as a *peer*, not a foundation)

Wireshark is the gold standard for **dissection**: its `epan`/`libwireshark` engine has
~3,000+ protocol dissectors, the deepest decode anywhere, and it's battle-tested.

But it is the wrong *base* for what we're building, because:
- It's a capture-then-analyze tool, not a streaming engine. Live capture at high packet
  rates bogs the UI; it's not designed for always-on, low-overhead monitoring.
- **No process attribution** (which app sent this?), **no identity/logo layer**,
  **no intent** — exactly the gap netscope exists to fill.
- The engine is a large GPL monolith; you embed *into* Wireshark (C dissectors + Lua),
  you don't cleanly embed *it* into a new product.

**Right relationship: interop, not inheritance.** Build our own lightweight, streaming
core; let users export a chosen flow to `.pcap` / pipe to `tshark` for the
3000-dissector deep dive when they truly need it. Reuse Wireshark's brain on demand;
don't live inside its body.

## 2. "Most powerful / faster / more extensible" tools — the real toolbox

Capture & speed (fastest → most extreme):
| Tool | What it gives | Fit |
|---|---|---|
| libpcap / AF_PACKET | classic full-payload capture | baseline, simple |
| **eBPF (kprobes/tracepoints) + ring buffers** | in-kernel counting + **per-PID attribution**, microsecond-latency event stream, near-zero overhead | **our default** — the modern power tool; how Cilium/Pixie/bandwhich/OpenSnitch do live monitoring |
| **XDP** | process at the earliest RX point, line-rate, can drop/redirect | for high-pps + future blocking |
| AF_XDP | userspace fast-path, near kernel-bypass speed | overkill for a desktop, available if needed |
| DPDK / PF_RING | full kernel-bypass, 10–100 Gbps | overkill for a single host; real complexity |

Depth & classification ("what is this?") — power tools to *borrow*, not rebuild:
- **nDPI** (ntop) — deep packet inspection / app-protocol ID for 280+ apps (Netflix,
  BitTorrent, WhatsApp, etc.). Directly serves the "what is it" goal. C lib → easy FFI.
- **Zeek** (ex-Bro) — scriptable, event-driven network-analysis framework; rich
  connection logs + protocol analyzers. Could be an optional backend "brain."
- **Suricata** — multi-threaded IDS, fast app-layer protocol detection, real-time EVE
  JSON output. Another optional power source / alerting engine.
- **tshark / libwireshark** — the deep-dissection escape hatch (export-and-open).

Verdict: the "most powerful" stack for *us* is **eBPF/XDP for capture+attribution+speed**
+ **nDPI (and optionally Zeek/Suricata) for classification depth** + **Wireshark/tshark
for on-demand deep dissection** — not building on Wireshark itself.

## 3. Is real-time achievable? — yes, decisively, on a desktop

- eBPF does counting/aggregation **in-kernel** and streams compact events to userspace
  via ring buffers at microsecond latency with negligible CPU. This is exactly how
  live eBPF observability tools work today.
- A single desktop's traffic — even a saturated gigabit link — is comfortably
  real-time on modern hardware *as long as you don't full-payload-capture-and-dissect
  everything continuously* (Wireshark's model). That's precisely why netscope is
  **tiered**: Tier 0 always-on + cheap; Tier 2 deep capture only on the flow you click.
- BEAM (Elixir) adds soft-real-time orchestration + push-to-UI (LiveView) that was
  built for exactly this kind of live, many-entity dashboard.

So: real-time isn't a stretch goal — it's the natural design point. The discipline is
keeping the hot path payload-free until the user explicitly asks to go deep.

---

## 4. Esoteric language options (the fun part — and they can be *good* choices)

This app is two machines: (A) a privileged, zero-GC, low-level **capture/attribution
hot path**, and (B) a soft-real-time **enrichment + UI** layer. Languages differ wildly
on which half they're good at.

### Zig — best for half A (the core)
- No GC, manual memory, deterministic latency; trivial C interop → call libbpf, libpcap,
  nDPI directly. Comptime + error unions make it genuinely novel ("weird cool").
- **Can target eBPF**: Zig uses LLVM, which has a BPF backend, so the in-kernel programs
  *and* the userspace loader can share one Zig codebase — a rare, cohesive story.
- Weak native-GUI ecosystem (you'd bind Dear ImGui or GTK via C).
- → Ideal core; not ideal whole-app.

### Elixir / Phoenix LiveView — best for half B (real-time + UI)
- BEAM/OTP: millions of cheap processes, fault-tolerance, supervision; model **each flow
  as a process**. Soft-real-time is its home turf.
- **LiveView** gives a live, server-rendered, logo-rich dashboard with push updates and
  almost no JS — a superb fit for "real-time network map with icons/logos."
- Not for the packet hot path → pair with a **Port** (talk to a Zig/C helper over a
  pipe) or a **NIF** (in-process native; Rustler/Zigler).
- → Ideal orchestration+UI; needs a native capture helper.

### Haskell — most elegant for dissection; hardest for GUI/eBPF
- Parser combinators make protocol decoders beautiful and correct; strong types catch
  bugs; STM for concurrency. GC means soft (not hard) real-time — fine here.
- eBPF only via FFI to libbpf; GUI options are niche (monomer/threepenny/web frontend).
- → Intellectually the richest for the *dissection* layer; steepest overall, weakest UI.

### Honorable mentions
- **OCaml** — fast, real networking pedigree (MirageOS), great FFI; less "weird."
- **Gleam** — typed language on BEAM; Elixir's runtime with static types; very new/hip.
- **Nim** — compiles to C, low-level + GTK/web capable, pragmatic; less weird.

### Recommended directions
1. **Polyglot (recommended): Zig core + Elixir/LiveView UI.** Each language on its home
   turf; weird *and* optimal; best real-time story; clean privileged/unprivileged split
   maps onto the language boundary. Cost: two languages + an IPC seam.
2. **Zig everywhere.** One esoteric language, max performance/control, hand-rolled
   ImGui UI; you build more of the UI + concurrency yourself.
3. **Elixir everywhere + tiny Zig/C capture NIF.** Max productivity for the live UI;
   the hot path still needs a small native helper.
4. **Haskell-centric.** Most elegant dissection; accept GUI/eBPF friction and a steeper
   learning curve.

---

## Sources
- eBPF/ring-buffer real-time monitoring (OpenSnitch): https://lwn.net/Articles/988401/ · https://deepwiki.com/evilsocket/opensnitch
- Zig → eBPF / LLVM BPF backend; aya for reference: https://github.com/aya-rs/aya
- nDPI: https://github.com/ntop/nDPI · Zeek: https://zeek.org · Suricata: https://suricata.io
- Phoenix LiveView (real-time UI): https://www.phoenixframework.org/
- Wireshark/tshark dissection engine: https://www.wireshark.org/
