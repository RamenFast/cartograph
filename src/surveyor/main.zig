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
    var as_json = false;
    var want_bpf = false;
    var sock_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, a, "--bpf")) {
            want_bpf = true;
        } else if (std.mem.eql(u8, a, "--socket")) {
            sock_path = args.next();
        }
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        if (sock_path) |p| try serveSocket(gpa, io, p, want_bpf) else try serve(gpa, io, want_bpf);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        try snapshot(gpa, io, as_json, want_bpf);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try usage(io);
    } else {
        try usage(io);
        return error.UnknownCommand;
    }
}

/// The capture source behind the Observation seam: unprivileged inet_diag, or the
/// eBPF program (when built with -Dbpf and the process holds the caps). Neither the
/// FlowTable nor any frontend sees which — that is the point of the seam.
const Source = union(enum) {
    diag: capture.Capturer,
    bpf: bpf.BpfCapturer,

    fn deinit(self: *Source) void {
        switch (self.*) {
            inline else => |*s| s.deinit(),
        }
    }

    /// One capture tick: fold the current observations into `table`, and collect the
    /// keys of flows that died. diag rescans + sweeps; bpf drains kernel events.
    fn tick(self: *Source, table: *cartograph.FlowTable, now: i64, closed: *std.ArrayList(cartograph.FlowKey)) !void {
        switch (self.*) {
            .diag => |*c| {
                table.beginCycle();
                try c.refresh(table, now);
                try table.collectClosed(closed);
            },
            .bpf => |*c| try c.refresh(table, now, closed),
        }
    }
};

/// Choose the source: eBPF if asked for *and* it actually loads (caps present), else
/// the inet_diag fallback. The fallback is loud about *why* — never a silent downgrade.
fn openSource(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool) !Source {
    if (want_bpf) {
        if (bpf.BpfCapturer.init(gpa)) |b| {
            return .{ .bpf = b };
        } else |err| {
            warnBpfFallback(io, err);
        }
    }
    return .{ .diag = try capture.Capturer.init(gpa, io) };
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

fn usage(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll(
        \\surveyor — cartograph capture core
        \\
        \\usage:
        \\  surveyor snapshot [--json]      one-shot attributed flow table (NDJSON with --json)
        \\  surveyor serve                  stream live IPC frames to stdout (pipe to a frontend)
        \\  surveyor serve --socket <path>  serve frames over a Unix socket (the daemon boundary)
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

/// One-shot, human-readable table — the promoted spike, now tcp6/udp + bytes + RTT.
/// `as_json` emits NDJSON instead: the agent/script surface (`snapshot --json | jq`).
fn snapshot(gpa: std.mem.Allocator, io: std.Io, as_json: bool, want_bpf: bool) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);
    try src.tick(&table, capture.nowMs(io), &closed);

    const flows = try table.snapshot(gpa);
    defer gpa.free(flows);

    var buf: [128 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    if (as_json) {
        // NDJSON: one flow per line. No color, no header — pure, pipeable data.
        for (flows) |f| {
            try cartograph.json.writeFlow(w, f);
            try w.writeByte('\n');
        }
        try w.flush();
        return;
    }

    try w.print("{s}cartograph · surveyor{s} {s}— live attributed flows (inet_diag + /proc)\n\n{s}", .{ BOLD, RST, DIM, RST });
    try w.print("{s}{s:<6} {s:<15} {s:<3} {s:<10} {s:<21} {s:<21} {s:>9} {s:>9} {s:>6}{s}\n", .{
        BOLD, "PID", "COMM", "·", "STATE", "LOCAL", "REMOTE", "RX", "TX", "RTT", RST,
    });

    var attributed: usize = 0;
    var lbuf: [48]u8 = undefined;
    var rbuf: [48]u8 = undefined;
    var rxbuf: [16]u8 = undefined;
    var txbuf: [16]u8 = undefined;
    for (flows) |f| {
        if (f.attributed()) attributed += 1;
        const cat = f.category;
        const rtt_ms: f64 = @as(f64, @floatFromInt(f.rtt_us)) / 1000.0;
        try w.print("{s}{s}{d:<6}{s} {s:<15} {s}{s}{s} {s:<10} {s:<21} {s}{s:<21}{s} {s:>9} {s:>9} ", .{
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

fn localStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    return cartograph.endpoint(buf, f.key.local, f.key.local_port);
}

fn remoteStr(f: *cartograph.Flow, buf: []u8) []const u8 {
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
}

/// The upstream (frontend → surveyor) half of a client connection: the per-connection,
/// view-local `SessionState` (D22) plus the byte accumulator that reassembles the
/// `user_state` frames a frontend sends (profile switch, lens toggle). Greeting/Rule
/// frames are *shared truth* bound for surveyor's persisted store (M3); they are
/// recognised here and left for that store, never silently misapplied as view state.
const ClientLink = struct {
    gpa: std.mem.Allocator,
    fd: std.posix.fd_t,
    acc: std.ArrayList(u8) = .empty,
    session: cartograph.SessionState = .{},

    fn deinit(self: *ClientLink) void {
        self.acc.deinit(self.gpa);
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
        try self.acc.appendSlice(self.gpa, rbuf[0..rc]);

        var start: usize = 0;
        var changed = false;
        while (self.acc.items.len - start >= 4) {
            const len = std.mem.readInt(u32, self.acc.items[start..][0..4], .little);
            if (self.acc.items.len - start < 4 + @as(usize, len)) break;
            var r = std.Io.Reader.fixed(self.acc.items[start .. start + 4 + len]);
            if (try ipc.readFrame(&r)) |frame| switch (frame) {
                .user_state => |us| if (self.session.apply(us)) {
                    changed = true;
                },
                else => {}, // greeting/rule → shared store (M3); hello/flow_* never travel upstream
            };
            start += 4 + len;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, self.acc.items, self.acc.items[start..]);
            self.acc.items.len -= start;
        }
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
fn streamLoop(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, in_fd: ?std.posix.fd_t, want_bpf: bool) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();

    var link: ?ClientLink = if (in_fd) |fd| .{ .gpa = gpa, .fd = fd } else null;
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

            const flows = try table.snapshot(gpa);
            defer gpa.free(flows);
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
fn serve(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool) !void {
    var buf: [256 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try streamLoop(gpa, io, &fw.interface, null, want_bpf);
}

/// `surveyor serve --socket <path>` — the real privilege boundary. Bind a Unix socket
/// and serve each connecting (unprivileged) frontend the same frames. `setcap` raises
/// *this* process's capabilities (M2 eBPF); the frontend across the socket never does.
fn serveSocket(gpa: std.mem.Allocator, io: std.Io, path: []const u8, want_bpf: bool) !void {
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
        streamLoop(gpa, io, &fw.interface, cfd, want_bpf) catch {};
    }
}
