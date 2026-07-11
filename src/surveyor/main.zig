//! surveyor — Cartograph's capture core.
//!
//!   surveyor snapshot   one-shot attributed flow table (human-readable)
//!   surveyor serve      stream the live view-model as binary IPC frames to stdout
//!
//! `serve` is the (eventually privileged) producer a frontend consumes:
//!   surveyor serve | cartograph --ipc
//! The same frames will travel a Unix socket once surveyor runs as a setcap daemon.

const std = @import("std");
const cartograph = @import("cartograph");
const capture = @import("capture");
const bpf = @import("bpf"); // real loader with -Dbpf, else a stub that reports unavailable

const ipc = cartograph.ipc;

const RST = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Writing to a frontend that hung up must not kill the daemon: make EPIPE a normal
    // write error we handle, not a process-terminating signal.
    ignoreSigpipe();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv0
    const cmd = args.next() orelse "snapshot";

    // Simple, agent-legible flag scan (order-independent). See docs/AGENT-INTERFACE.md.
    // Unknown flags are an error, not a shrug — a typo'd `--sockte` must never silently
    // run something else (consistent-behavior law).
    var as_json = false;
    var want_bpf = false;
    var sock_path: ?[]const u8 = null;
    var geoip_dir: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, a, "--bpf")) {
            want_bpf = true;
        } else if (std.mem.eql(u8, a, "--socket")) {
            sock_path = args.next() orelse return fail(io, "--socket needs a path", .{});
        } else if (std.mem.eql(u8, a, "--geoip")) {
            geoip_dir = args.next() orelse return fail(io, "--geoip needs a directory", .{});
        } else {
            return fail(io, "unknown flag '{s}' — see `surveyor --help`", .{a});
        }
    }

    // Default GeoIP location: the XDG data dir scripts/fetch-geoip.sh writes to.
    // Missing databases degrade loudly inside the enricher — never silently.
    var geoip_buf: [1024]u8 = undefined;
    if (geoip_dir == null) {
        if (init.minimal.environ.getPosix("HOME")) |home| {
            geoip_dir = std.fmt.bufPrint(&geoip_buf, "{s}/.local/share/cartograph/geoip", .{home}) catch null;
        }
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        if (as_json) {
            if (sock_path) |p| try serveSocketJson(gpa, io, p, want_bpf, geoip_dir) else try serveJson(gpa, io, want_bpf, geoip_dir);
        } else if (sock_path) |p| try serveSocket(gpa, io, p, want_bpf, geoip_dir) else try serve(gpa, io, want_bpf, geoip_dir);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        try snapshot(gpa, io, as_json, want_bpf, geoip_dir);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try status(gpa, io, want_bpf, geoip_dir);
    } else if (std.mem.eql(u8, cmd, "--schema") or std.mem.eql(u8, cmd, "schema")) {
        try printSchema(io);
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "-V")) {
        try printVersion(io);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h")) {
        try usage(io, .stdout); // help was *asked for* → it's the output, not a complaint
    } else {
        try usage(io, .stderr);
        return fail(io, "unknown command '{s}'", .{cmd});
    }
}

/// `surveyor --version` — the injected build.zig.zon version, nothing else on the line
/// (scripts parse this; the packaging gate compares it to the package filename).
fn printVersion(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.print("surveyor {s}\n", .{cartograph.version});
    try fw.interface.flush();
}

/// A clean one-line failure: message to stderr, exit 2 — never a stack trace. A CLI's
/// error surface is part of its UI (the polished-consistent-behavior pass).
fn fail(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print("surveyor: " ++ fmt ++ "\n", fmt_args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(2);
}

/// The capture source behind the Observation seam: unprivileged inet_diag, or the
/// S3 **hybrid** — inet_diag baseline *fused with* the eBPF programs (when built
/// with -Dbpf and the process holds the caps). Neither the FlowTable nor any
/// frontend sees which — that is the point of the seam.
const Source = union(enum) {
    diag: capture.Capturer,
    hybrid: Hybrid,

    const Hybrid = struct {
        diag: capture.Capturer,
        bpf: bpf.BpfCapturer,
    };

    fn deinit(self: *Source) void {
        switch (self.*) {
            .diag => |*c| c.deinit(),
            .hybrid => |*h| {
                h.diag.deinit();
                h.bpf.deinit();
            },
        }
    }

    /// One capture tick. Hybrid fusion (S3): the diag rescan is the baseline (the
    /// existing table, TCP bytes, RTT), the eBPF drain adds what polling misses
    /// (births/deaths between ticks, short-lived flows, UDP/QUIC counters), and the
    /// generation sweep stays the single eviction authority.
    fn tick(self: *Source, table: *cartograph.FlowTable, now: i64, closed: *std.ArrayList(cartograph.FlowKey)) !void {
        table.beginCycle();
        switch (self.*) {
            .diag => |*c| try c.refresh(table, now),
            .hybrid => |*h| {
                try h.diag.refresh(table, now);
                try h.bpf.drain(table, now);
            },
        }
        try table.collectClosed(closed);
    }

    /// The passive-DNS filter program, when the eBPF half is live (pdns needs it).
    fn dnsFilterFd(self: *Source) ?i32 {
        return switch (self.*) {
            .hybrid => |*h| h.bpf.dns_filter_fd,
            else => null,
        };
    }
};

/// Choose the source: the eBPF hybrid if asked for *and* it actually loads (caps
/// present), else the inet_diag fallback. Loud about *why* — never a silent downgrade.
fn openSource(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool) !Source {
    if (want_bpf) {
        if (bpf.BpfCapturer.init(gpa)) |b| {
            return .{ .hybrid = .{ .diag = try capture.Capturer.init(gpa, io), .bpf = b } };
        } else |err| {
            warnBpfFallback(io, err);
        }
    }
    return .{ .diag = try capture.Capturer.init(gpa, io) };
}

/// Open the passive-DNS tap when the hybrid source is live. Its own caps failure
/// (CAP_NET_RAW) degrades loudly to rDNS-only names — never silently.
fn openPdns(io: std.Io, src: *Source) ?capture.pdns.Pdns {
    const pfd = src.dnsFilterFd() orelse return null;
    return capture.pdns.Pdns.init(pfd) catch |err| {
        var buf: [256]u8 = undefined;
        var fw = std.Io.File.stderr().writer(io, &buf);
        fw.interface.print("{s}note:{s} passive DNS unavailable ({s}; needs cap_net_raw) — names stay rDNS-only.\n", .{ DIM, RST, @errorName(err) }) catch {};
        fw.interface.flush() catch {};
        return null;
    };
}

fn warnBpfFallback(io: std.Io, err: anyerror) void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    const hint = if (!bpf.built)
        "built without -Dbpf"
    else switch (err) {
        error.BpfLoad, error.BpfAttach => "needs caps — setcap cap_bpf,cap_perfmon,cap_net_admin,cap_net_raw+ep surveyor",
        else => "see ARCHITECTURE.md",
    };
    w.print("{s}note:{s} eBPF source unavailable ({s}: {s}); using unprivileged inet_diag.\n", .{ DIM, RST, @errorName(err), hint }) catch return;
    w.flush() catch {};
}

fn usage(io: std.Io, sink: enum { stdout, stderr }) !void {
    var buf: [1024]u8 = undefined;
    const file = switch (sink) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll(
        \\surveyor — cartograph capture core
        \\
        \\usage:
        \\  surveyor status                 one-shot posture: ONE JSON object — listeners,
        \\                                  exposure/risk badges, flow counts (always JSON)
        \\  surveyor snapshot [--json]      one-shot attributed flow table
        \\                                  (auto-NDJSON when stdout is a pipe; force with --json)
        \\  surveyor serve                  stream live binary IPC frames to stdout (pipe to a frontend)
        \\  surveyor serve --json           stream the live view-model as NDJSON events
        \\                                  (hello/flow/closed/tick lines — the agent's live watch)
        \\  surveyor serve --socket <path>  serve frames over a Unix socket (the daemon boundary)
        \\  surveyor --schema               print the machine-readable contract of every surface
        \\  surveyor --version              print the version and exit
        \\
        \\flags: --bpf (use the eBPF source if caps allow)  --socket <path>  --json
        \\       --geoip <dir> (ASN+country mmdb dir; default ~/.local/share/cartograph/geoip —
        \\                      populate it once with cartograph-fetch-geoip)
        \\
    );
    try w.flush();
}

fn ignoreSigpipe() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

/// One-shot, human-readable table — the promoted spike, now tcp6/udp + bytes + RTT
/// + names/owners/countries (S1). `as_json` emits NDJSON instead: the agent/script
/// surface (`snapshot --json | jq`).
fn snapshot(gpa: std.mem.Allocator, io: std.Io, as_json: bool, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();
    var pdns = openPdns(io, &src);
    defer if (pdns) |*p| p.deinit();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);
    try src.tick(&table, capture.nowMs(io), &closed);
    if (pdns) |*p| p.poll(&enricher, capture.nowMs(io));

    const flows = try table.snapshot(gpa);
    defer gpa.free(flows);
    // One-shot gets one frame, so give rDNS a bounded head start — keep refilling
    // the small lookup pool until it idles or ~1 s passes. (The serve loops never
    // wait — names stream in on later ticks there.)
    enricher.decorate(flows, capture.nowMs(io));
    var budget: i64 = 1000;
    while (enricher.resolver.busy() and budget > 0) : (budget -= 100) {
        enricher.resolver.drainFor(100);
        enricher.decorate(flows, capture.nowMs(io));
    }

    var buf: [128 * 1024]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var fw = stdout.writer(io, &buf);
    const w = &fw.interface;

    // The Unix `isatty` move (AGENT-INTERFACE.md): pretty for a human at a TTY, structured
    // NDJSON the moment stdout is a pipe — so `surveyor snapshot | jq` just works, no flag
    // to remember. `--json` still forces it (e.g. when writing to a file). tcgetattr returns
    // ENOTTY on anything that isn't a terminal, which is exactly the isatty test.
    const stdout_is_tty = if (std.posix.tcgetattr(stdout.handle)) |_| true else |_| false;
    const emit_json = as_json or !stdout_is_tty;

    if (emit_json) {
        // NDJSON: one flow per line. No color, no header — pure, pipeable data.
        for (flows) |f| {
            try cartograph.json.writeFlow(w, f);
            try w.writeByte('\n');
        }
        try w.flush();
        return;
    }

    try w.print("{s}cartograph · surveyor{s} {s}— live attributed flows (inet_diag + /proc + rDNS/GeoIP)\n\n{s}", .{ BOLD, RST, DIM, RST });
    try w.print("{s}{s:<6} {s:<15} {s:<3} {s:<10} {s:<21} {s:<27} {s:<24} {s:>9} {s:>9} {s:>6}{s}\n", .{
        BOLD, "PID", "COMM", "·", "STATE", "LOCAL", "REMOTE", "WHO", "RX", "TX", "RTT", RST,
    });

    var attributed: usize = 0;
    var lbuf: [48]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    var wbuf: [48]u8 = undefined;
    var rxbuf: [16]u8 = undefined;
    var txbuf: [16]u8 = undefined;
    for (flows) |f| {
        if (f.attributed()) attributed += 1;
        const cat = f.category;
        const rtt_ms: f64 = @as(f64, @floatFromInt(f.rtt_us)) / 1000.0;
        try w.print("{s}{s}{d:<6}{s} {s:<15} {s}{s}{s} {s:<10} {s:<21} {s}{s:<27}{s} {s}{s:<24}{s} {s:>9} {s:>9} ", .{
            cat.ansi(),
            "",
            f.pid,
            RST,
            f.name(),
            cat.ansi(),
            cat.glyph(),
            RST,
            f.state.label(),
            localStr(f, &lbuf),
            cat.ansi(),
            remoteStr(f, &rbuf),
            RST,
            DIM,
            whoStr(f, &wbuf),
            RST,
            cartograph.humanBytes(&rxbuf, f.rx_bytes),
            cartograph.humanBytes(&txbuf, f.tx_bytes),
        });
        if (f.rtt_us != 0) {
            try w.print("{s}{d:>5.1}ms{s}\n", .{ DIM, rtt_ms, RST });
        } else {
            try w.print("{s}{s:>7}{s}\n", .{ DIM, "·", RST });
        }
    }
    try w.print("\n{s}{d}/{d} flows attributed to a local process (rest = other-user / kernel / closing).{s}\n", .{ DIM, attributed, flows.len, RST });
    try w.flush();
}

/// `surveyor status` — the box's posture as ONE JSON object (the station convention's
/// one-shot shape; the Nexus ask). Listener inventory + exposure/risk badges + flow
/// counts. Always JSON — a summary is data, there is no table twin. No rDNS wait:
/// listeners are local truth, names don't gate the answer.
fn status(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);
    const now = capture.nowMs(io);
    try src.tick(&table, now, &closed);

    const flows = try table.snapshot(gpa);
    defer gpa.free(flows);
    enricher.decorate(flows, now);

    var buf: [128 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try cartograph.json.writeStatus(w, flows, now);
    try w.writeByte('\n');
    try w.flush();
}

/// The shared `AS-org · CC` derivation, truncated to the snapshot's WHO column.
fn whoStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    const s = f.whoDisplay(buf);
    return s[0..@min(s.len, 24)];
}

fn localStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    return cartograph.endpoint(buf, f.key.local, f.key.local_port);
}

/// The S1 headline: `github.com:443` when we know the name, the address otherwise.
fn remoteStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    if (f.remote_name.len > 0) {
        var w = std.Io.Writer.fixed(buf);
        const name = f.remote_name.slice();
        const max_name = 26 - 6; // keep :port visible in the 27-wide column
        w.writeAll(name[0..@min(name.len, max_name)]) catch {};
        w.print(":{d}", .{f.key.remote_port}) catch {};
        return w.buffered();
    }
    return cartograph.endpoint(buf, f.key.remote, f.key.remote_port);
}

/// Poll one fd for readability with a millisecond timeout (the daemon's half of the
/// frontend↔surveyor full-duplex link — we write flows *and* read upstream user_state on
/// the same socket). Mirrors the TUI's `term.pollIn`, kept local so surveyor doesn't
/// depend on the TUI module.
fn pollReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    const rc = std.os.linux.poll(&fds, 1, timeout_ms);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    return fds[0].revents & std.os.linux.POLL.IN != 0;
}

/// Send the *authoritative* view-local session to a client as the minimal set of
/// `user_state` frames that reconstruct it: the `.profile` base, then a `.lens_toggle`
/// only for lenses that deviate from that profile's default. A connecting frontend thus
/// **inherits** surveyor's session instead of guessing — truth flows from one owner
/// (DECISIONS D22, the Seam-C anti-fork). Today every connection starts `.calm`; when
/// persisted greetings land (M3) this same channel carries them down on connect.
fn sendSession(w: *std.Io.Writer, s: cartograph.SessionState) !void {
    try ipc.sendUserState(w, .{ .profile = s.profile });
    inline for (std.enums.values(cartograph.lens.Lens)) |l| {
        if (s.lensOverridden(l))
            try ipc.sendUserState(w, .{ .lens_toggle = .{ .lens = l, .on = s.lenses.contains(l) } });
    }
    // Inherit-the-cursor (D24/R1): a client that connects mid-session starts where the
    // session's focus already is, not back at orbit. The default orbit is elided.
    if (!s.focus.eql(.{})) try ipc.sendUserState(w, .{ .focus = s.focus });
}

/// The upstream (frontend → surveyor) half of a client connection: the per-connection,
/// view-local `SessionState` (D22) plus the byte accumulator that reassembles the
/// `user_state` frames a frontend sends (profile switch, lens toggle). Greeting/Rule
/// frames are *shared truth* bound for surveyor's persisted store (M3); they are
/// recognised here and left for that store, never silently misapplied as view state.
const ClientLink = struct {
    fd: std.posix.fd_t,
    frames: ipc.FrameStream,
    session: cartograph.SessionState = .{},

    fn init(gpa: std.mem.Allocator, fd: std.posix.fd_t) ClientLink {
        return .{ .fd = fd, .frames = ipc.FrameStream.init(gpa) };
    }

    fn deinit(self: *ClientLink) void {
        self.frames.deinit();
    }

    /// Read whatever the frontend just sent (the fd is already poll-ready), fold any
    /// view-local `user_state` change into the session, and report whether it changed
    /// (so the caller echoes the new authoritative session back). `error.Closed` =
    /// the frontend hung up.
    fn pump(self: *ClientLink) !bool {
        var rbuf: [16 * 1024]u8 = undefined;
        const rc = std.os.linux.read(self.fd, &rbuf, rbuf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return false,
            else => return error.Closed,
        }
        if (rc == 0) return error.Closed; // EOF: frontend gone
        try self.frames.push(rbuf[0..rc]);

        var changed = false;
        while (try self.frames.next()) |frame| switch (frame) {
            .user_state => |us| if (self.session.apply(us)) {
                changed = true;
            },
            else => {}, // greeting/rule → shared store (M3); hello/flow_* never travel upstream
        };
        return changed;
    }
};

/// The capture→emit loop, writing IPC frames to `w` forever. Returns when the writer
/// errors (the consumer hung up) or capture fails. Transport-agnostic by construction:
/// `w` is a pipe (stdout) or an accepted Unix socket — the frames are byte-identical,
/// so a frontend renders the same view-model either way (parity, proven in tests).
///
/// `in_fd` is the readable half of a *full-duplex* client socket: when present, the loop
/// also drains upstream `user_state` frames and echoes the authoritative session back
/// (the bidirectional Seam-C path, D22). A pipe (`serve` to stdout) has no upstream, so
/// `in_fd` is null and the loop just paces the 1 Hz capture.
fn streamLoop(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, in_fd: ?std.posix.fd_t, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();
    var pdns = openPdns(io, &src);
    defer if (pdns) |*p| p.deinit();

    var link: ?ClientLink = if (in_fd) |fd| ClientLink.init(gpa, fd) else null;
    defer if (link) |*l| l.deinit();

    try ipc.sendHello(w);
    if (link) |*l| try sendSession(w, l.session); // inherit-on-connect (D22)
    try w.flush();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);

    var next_tick = capture.nowMs(io); // fire the first capture immediately
    while (true) {
        const now = capture.nowMs(io);
        if (now >= next_tick) {
            closed.clearRetainingCapacity();
            try src.tick(&table, now, &closed);
            if (pdns) |*p| p.poll(&enricher, now); // true hostnames before this tick decorates

            const flows = try table.snapshot(gpa);
            defer gpa.free(flows);
            enricher.decorate(flows, now); // S1: names/owners ride the same frames
            for (flows) |f| try ipc.sendFlowUpsert(w, f.*);
            for (closed.items) |k| try ipc.sendFlowClosed(w, k);

            try ipc.sendTick(w, now);
            try w.flush();
            next_tick = now + 1000;
        }

        // Wait out the rest of the tick — but stay responsive to upstream toggles.
        const remaining: i32 = @intCast(@max(0, @min(1000, next_tick - capture.nowMs(io))));
        if (link) |*l| {
            if (pollReadable(l.fd, remaining)) {
                const changed = l.pump() catch |e| switch (e) {
                    error.Closed => return, // frontend hung up; serveSocket waits for the next
                    else => return e,
                };
                if (changed) {
                    try sendSession(w, l.session); // echo authoritative state
                    try w.flush();
                }
            }
        } else {
            try io.sleep(std.Io.Duration.fromMilliseconds(@intCast(remaining)), .awake);
        }
    }
}

/// `surveyor serve` — frames to stdout: the pipe path, `surveyor serve | cartograph --ipc`.
/// A pipe is one-way, so there is no upstream `user_state` channel here (in_fd = null).
fn serve(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var buf: [256 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    streamLoop(gpa, io, &fw.interface, null, want_bpf, geoip_dir) catch |err| return exitIfHangup(err);
}

/// `surveyor serve --socket <path>` — the real privilege boundary. Bind a Unix socket
/// and serve each connecting (unprivileged) frontend the same frames. `setcap` raises
/// *this* process's capabilities (M2 eBPF); the frontend across the socket never does.
fn serveSocket(gpa: std.mem.Allocator, io: std.Io, path: []const u8, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    const lfd = try cartograph.usock.listen(path);
    defer cartograph.usock.close(lfd);

    var ebuf: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &ebuf);
    try ew.interface.print("{s}surveyor{s} serving IPC on unix:{s}  —  connect: cartograph --ipc --socket {s}\n", .{ BOLD, RST, path, path });
    try ew.interface.flush();

    while (true) {
        const cfd = cartograph.usock.accept(lfd) catch continue;
        defer cartograph.usock.close(cfd);
        var buf: [256 * 1024]u8 = undefined;
        var cf: std.Io.File = .{ .handle = cfd, .flags = .{ .nonblocking = false } };
        var fw = cf.writer(io, &buf);
        // The socket is full-duplex: we write flows down it and read upstream user_state
        // (profile/lens toggles) back up it (D22). A client that hangs up surfaces as a
        // write error or `error.Closed`; either way, just wait for the next.
        streamLoop(gpa, io, &fw.interface, cfd, want_bpf, geoip_dir) catch {};
    }
}

/// The NDJSON event loop — the text twin of `streamLoop`'s binary frames (AGENT-INTERFACE
/// §"serve --json"). Same view-model, same 1 Hz cadence, emitted as one self-identifying
/// JSON object per line so an agent watches the *exact same live truth* the GUI renders —
/// `surveyor serve --json | jq -c 'select(.ev=="flow" and .fresh)'` — instead of re-polling
/// `snapshot`. Read-only: a watching agent has no upstream channel, so there is no duplex.
fn streamLoopJson(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();
    var pdns = openPdns(io, &src);
    defer if (pdns) |*p| p.deinit();
    const J = cartograph.json;

    try J.writeHelloEvent(w, ipc.protocol_version);
    try w.writeByte('\n');
    // Inherit-on-connect: tell the agent the starting cursor (focus, R1), the same way the
    // binary path sends the session. Read-only today — focus moves once the duplex command
    // channel lands (RESEARCH R3); shipping the event shape now keeps that work additive.
    try J.writeFocusEvent(w, cartograph.Focus{});
    try w.writeByte('\n');
    try w.flush();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);

    var next_tick = capture.nowMs(io);
    while (true) {
        const now = capture.nowMs(io);
        if (now >= next_tick) {
            closed.clearRetainingCapacity();
            try src.tick(&table, now, &closed);
            if (pdns) |*p| p.poll(&enricher, now);

            const flows = try table.snapshot(gpa);
            defer gpa.free(flows);
            enricher.decorate(flows, now); // S1: the agent sees the same names
            for (flows) |f| {
                try J.writeFlowEvent(w, f);
                try w.writeByte('\n');
            }
            for (closed.items) |k| {
                try J.writeClosedEvent(w, k);
                try w.writeByte('\n');
            }
            try J.writeTickEvent(w, now, flows.len);
            try w.writeByte('\n');
            try w.flush();
            next_tick = now + 1000;
        }
        const remaining: i64 = @max(0, @min(1000, next_tick - capture.nowMs(io)));
        try io.sleep(std.Io.Duration.fromMilliseconds(@intCast(remaining)), .awake);
    }
}

/// `surveyor serve --json` — the live NDJSON event stream to stdout.
fn serveJson(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var buf: [256 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    streamLoopJson(gpa, io, &fw.interface, want_bpf, geoip_dir) catch |err| return exitIfHangup(err);
}

/// A consumer that stopped reading (`serve --json | head -1`, a bounded `jq`, an agent
/// sampling one tick) is a normal Unix ending, not a runtime failure (audit F19).
/// SIGPIPE is already ignored; here the resulting write error becomes a clean exit 0.
/// Anything else propagates — a real failure must stay loud.
fn exitIfHangup(err: anyerror) anyerror!void {
    return switch (err) {
        error.WriteFailed, error.BrokenPipe => std.process.exit(0),
        else => err,
    };
}

/// `surveyor serve --json --socket <path>` — the same NDJSON stream over a Unix socket, so a
/// remote/headless agent watches the live box exactly as `serve --json | jq` does locally.
fn serveSocketJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    const lfd = try cartograph.usock.listen(path);
    defer cartograph.usock.close(lfd);
    while (true) {
        const cfd = cartograph.usock.accept(lfd) catch continue;
        defer cartograph.usock.close(cfd);
        var buf: [256 * 1024]u8 = undefined;
        var cf: std.Io.File = .{ .handle = cfd, .flags = .{ .nonblocking = false } };
        var fw = cf.writer(io, &buf);
        streamLoopJson(gpa, io, &fw.interface, want_bpf, geoip_dir) catch {};
    }
}

/// `surveyor --schema` — the self-describing contract (D18, "no AI left out"). A model that
/// has never seen Cartograph runs this once and learns every field, event, and vocabulary.
fn printSchema(io: std.Io) !void {
    var buf: [16 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try cartograph.json.writeSchema(w);
    try w.writeByte('\n');
    try w.flush();
}
