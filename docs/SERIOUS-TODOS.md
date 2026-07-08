# Serious TODOs — the honest "what am I not confident about" ledger

Things a careful maintainer would want written down (AGENTS.md §6): not
roadmap items (ROADMAP.md has those), but places where today's confidence
is genuinely limited. Each entry names the risk and the fix.

## Open

1. **`zig build test` prints an alarming-but-benign "failed command:" block.**
   The geodb degrade test *intentionally* writes two `note:` lines to stderr
   (its name says so), and zig 0.16-dev's build runner forwards that stderr
   under a header that reads like a failure — on fully green runs (verified:
   exit 0, 73/73 + 78/78, ~40 runs incl. cold-cache). It cost a session 20
   minutes of false-flake hunting on 2026-07-07 and will confuse any CI reader.
   *Fix:* let tests inject the note sink (a writer param on `GeoDb.open`), or
   re-check at the next toolchain bump (D16 freeze) whether the runner's
   wording improved.

2. **The rpm is verified on a dpkg box only.** Receipts: payload extracts
   (`rpm2cpio | cpio`), ELF-derived Requires read sane, `rpm -qpi` clean —
   but no real `dnf install` on an RPM distro has run. The release notes say
   so honestly. *Fix:* one friendly Fedora/openSUSE install report, or a CI
   container job.

3. **Menu-launched windows have no visible degrade surface.** The spawned
   surveyor's stderr (missing GeoIP note, eBPF fallback note) goes to the
   session log, which nobody reads from a double-click. A menu user with no
   GeoIP data just sees rDNS-only names, unexplained. *Fix:* surface degrade
   state in the UI — a quiet line in the Why panel's orbit view (the natural
   home once `Reading`s land).

4. **One package, hard GTK dependency.** `Depends: libgtk-4-1` drags the GTK
   stack onto headless boxes that only want `surveyor` + the TUI. Right for
   one artifact; wrong the day a server wants it. *Fix:* split
   `cartograph-core` / `cartograph-gtk` when someone actually asks.

5. **eBPF capabilities are an out-of-band step.** postinst prints the setcap
   line but deliberately never runs it (no silent capability grants — D25's
   *visible* half). Users who skip the note run unprivileged and may not
   realize short-lived/UDP capture is off. *Fix:* the M9 first-run "doctor"
   verb (`surveyor status` already reports posture; doctor makes it a
   conversation).

## Closed

- ~~The double-click launch closed instantly (tty-vs-/dev/null heuristic).~~
  Fixed 2026-07-07 (fstat-based detection), Xvfb-verified both paths.
- ~~`scripts/fetch-geoip.sh` named in degrade notes but not on PATH when
  installed.~~ Ships as `cartograph-fetch-geoip`; notes renamed (2026-07-07).
- ~~Man pages referenced `planisphere` (doesn't exist) and a missing
  `cartograph-gtk(1)`.~~ Cut / written, staged into both packages (2026-07-07).
