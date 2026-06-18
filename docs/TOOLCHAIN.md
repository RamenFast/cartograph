# Cartograph — toolchain (Zig 0.16) notes & longevity plan

> Origin: Nexus critique v3 §5.6 — the Zig-0.16 churn knowledge was buried in EXPERIMENTS E1
> ("a place people don't look"). It lives here now. We are on **Zig 0.16.0 ahead of the wider
> ecosystem** (libvaxis targets 0.15.1; zig-gobject is moving; most projects sit on 0.13–0.15).
> That bet is paying off in velocity — but being early has a cost when 0.17 ships, so the plan
> below is explicit instead of "decided by whoever upgrades first."

## The freeze/longevity plan  (see DECISIONS.md D16)

- **Freeze `toolchain/zig` at the vendored 0.16.0** (it's gitignored — re-fetch via bootstrap).
  The compiler is pinned; nothing auto-upgrades.
- **Follow Zig's *stable* channel** for upgrades — adopt 0.17+ only once our deps (libvaxis,
  zig-gobject) track it, on a deliberate branch, never mid-milestone.
- **Patch upstream deps as needed, in-tree**, and record the patch here. The native TUI was
  chosen partly to *avoid* a hard libvaxis dependency on the hot path (see FRONTENDS.md / D9).
- **If we must live on 0.16 for a year:** that's fine. The std API we depend on is small and
  listed below; carrying it is cheap. Don't chase 0.17 for its own sake.

## Std 0.16 churn that bit us (verified working patterns)

The 0.16 std had a large I/O / fs / process redesign vs older docs. Patterns this codebase
relies on (so the next contributor doesn't rediscover them):

- **`main`:** `pub fn main(init: std.process.Init) !void`. Use `init.io` (`std.Io`),
  `init.gpa`, `init.arena`. **Args:** `std.process.Args.Iterator.init(init.minimal.args)`.
- **No `std.posix.socket/send/recv`** — gone. Raw syscalls live in `std.os.linux`
  (`socket/sendto/recvfrom/close/read/poll/ioctl`), each returns `usize`; check
  `linux.errno(rc) == .SUCCESS`. (`std.posix.tcgetattr/tcsetattr` still exist.)
- **No `std.time.milliTimestamp`.** Time is via `std.Io`:
  `std.Io.Timestamp.now(io, .real).toMilliseconds()`; sleep via
  `io.sleep(std.Io.Duration.fromMilliseconds(n), .awake)`.
- **`std.ArrayList(T)` is the *unmanaged* one** — `.empty`, methods take the allocator
  (`append(gpa, x)`, `deinit(gpa)`, `toOwnedSlice(gpa)`). Managed = `std.array_list.Managed(T)`.
- **Reader/Writer:** `std.Io.Reader.fixed` / `std.Io.Writer.fixed`; `w.buffered()` returns
  written bytes; `r.takeInt/takeArray/takeByte/take`; `w.writeInt/writeAll/print/flush`.
  File writer: keep the `File.Writer` state stable, use `&state.interface` (self-referential
  via `@fieldParentPtr` — never copy the interface out).
- **`refAllDeclsRecursive` removed** — only `refAllDecls`; re-exporting submodules as
  `pub const` already pulls their tests into `zig build test`.
- termios lflag is a packed struct (`raw.lflag.ICANON = false`); terminal size via
  `linux.ioctl(fd, linux.T.IOCGWINSZ, …)`.

*(Build-system shape: see `build.zig` — modules `cartograph` + `capture`, exes `surveyor` +
`cartograph`, steps `run`/`serve`/`snapshot`/`test`.)*
