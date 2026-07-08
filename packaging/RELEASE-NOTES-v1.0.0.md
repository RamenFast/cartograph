**Cartograph v1.0.0** — a living map of your machine's network: every process
and who it is talking to, live, by real name, with the *why* one click away.

![The GTK window: live attributed flows beside the Why panel](https://github.com/RamenFast/cartograph/raw/v1.0.0/assets/hero.png)

This is the first release. The one loop it ships, whole: **see** everything
(unprivileged out of the box; opt-in eBPF for short-lived flows and UDP/QUIC
bytes) → **by real name** (rDNS, passive DNS, offline GeoIP/ASN:
`160.79.104.10` becomes *Anthropic, PBC · US*) → **ask why** (a plain-language
panel narrating any flow: process, lineage, owner, traffic, latency, age).

| | in 1.0.0 |
|---|---|
| Per-process attribution (TCP+UDP, v4+v6, real byte counters + RTT) | ✅ |
| Identity: rDNS · passive DNS · offline GeoIP/ASN owner + country | ✅ |
| The "Why" panel (TUI and GTK, same narration) | ✅ |
| eBPF hybrid capture: short-lived flows, UDP/QUIC bytes (opt-in setcap) | ✅ |
| App icons, category colours, exposure risk badges, lens profiles | ✅ |
| Agent surface: `--schema`, NDJSON snapshot/stream, one-object `status` | ✅ |
| GTK app in the house Blossom Dark design language | ✅ |
| Man pages, desktop entry, icon set — a real installed application | ✅ |

**Not in 1.0.0, honestly:** the force-directed constellation map (the
orbit→street zoom), XDP blocking, decomposed risk *rings* (the exposure badge
ships; the scoring engine doesn't), nDPI classification, TLS SNI (deliberate —
ECH is eroding it), and `atlas`, the multi-observer LiveView layer. All on
[the roadmap](https://github.com/RamenFast/cartograph/blob/v1.0.0/docs/ROADMAP.md);
the honest-uncertainty ledger is
[docs/SERIOUS-TODOS.md](https://github.com/RamenFast/cartograph/blob/v1.0.0/docs/SERIOUS-TODOS.md).

## Install

```bash
# Debian / Ubuntu / Mint
sudo apt install ./cartograph_1.0.0_amd64.deb

# Fedora / openSUSE — built on Mint, payload rpm-verified; install reports welcome
sudo dnf install ./cartograph-1.0.0-1.x86_64.rpm
```

Verify: `surveyor --version` → `surveyor 1.0.0`. Then two optional one-liners
unlock the full picture (both degrade loudly, never silently, if skipped):

```bash
cartograph-fetch-geoip     # offline GeoIP/ASN names (DB-IP Lite, CC-BY)
sudo setcap cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep /usr/bin/surveyor
```

Building from source: see the
[README](https://github.com/RamenFast/cartograph/blob/v1.0.0/README.md#install)
(Zig 0.16 + scdoc; clang/libbpf-dev for eBPF, libgtk-4-dev for the window).

`SHA256SUMS` covers every asset: `sha256sum -c SHA256SUMS --ignore-missing`.

---

Built by Ben with **[Claude](https://claude.com/claude-code)** (Fable 5) and
**Nexus** (the standing critiques). GPLv3. *The map is not the territory — but
it should at least be live.*
