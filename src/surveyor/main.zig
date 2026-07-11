//! surveyor — Cartograph's capture core.
//!
//!   surveyor snapshot   one-shot attributed flow table (human-readable)
//!   surveyor serve      stream the live view-model as binary IPC frames to stdout
//!   surveyor serve --socket <path>   the shared session daemon: ONE capture core,
//!                       many simultaneous observers — binary frontends on <path>,
//!                       NDJSON agents on <path>.json — all following one shared cursor
//!   surveyor ctl        drive the live session from a shell/agent (focus …)
//!
//! `serve` is the (eventually privileged) producer a frontend consumes:
//!   surveyor serve | cartograph --ipc
//! The same frames travel the Unix socket when surveyor runs as a setcap daemon.

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

    // `ctl` owns its own grammar (verb + positional args), so branch before the flag scan.
    if (std.mem.eql(u8, cmd, "ctl")) return ctl(gpa, io, init.minimal.environ, &args);

    // Simple, agent-legible flag scan (order-independent). See docs/AGENT-INTERFACE.md.
    // Unknown flags are an error, not a shrug — a typo'd `--sockte` must never silently
    // run something else (consistent-behavior law).
    var as_json = false;
    var want_bpf = false;
    var exit_idle = false;
    var sock_path: ?[]const u8 = null;
    var geoip_dir: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, a, "--bpf")) {
            want_bpf = true;
        } else if (std.mem.eql(u8, a, "--exit-idle")) {
            exit_idle = true;
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
        if (sock_path) |p| {
            // The shared session daemon (F5): one capture core, many observers. The
            // binary frames live at <p>; the NDJSON agent surface lives at <p>.json —
            // unless --json asked for NDJSON at exactly <p> (agents-only).
            var jbuf: [128]u8 = undefined;
            if (as_json) {
                try daemon(gpa, io, null, p, want_bpf, geoip_dir, exit_idle);
            } else {
                const jp = std.fmt.bufPrint(&jbuf, "{s}.json", .{p}) catch
                    return fail(io, "socket path too long for its .json twin", .{});
                try daemon(gpa, io, p, jp, want_bpf, geoip_dir, exit_idle);
            }
        } else if (as_json) {
            try serveJson(gpa, io, want_bpf, geoip_dir);
        } else {
            try serve(gpa, io, want_bpf, geoip_dir);
        }
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
    var buf: [2048]u8 = undefined;
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
        \\  surveyor status                 one-shot posture: ONE JSON object — capture mode,
        \\                                  listeners, exposure/risk badges, flow counts
        \\  surveyor snapshot [--json]      one-shot attributed flow table
        \\                                  (auto-NDJSON when stdout is a pipe; force with --json)
        \\  surveyor serve                  stream live binary IPC frames to stdout (pipe to a frontend)
        \\  surveyor serve --json           stream the live view-model as NDJSON events
        \\                                  (hello/posture/flow/closed/tick lines — the agent's live watch)
        \\  surveyor serve --socket <path>  the shared session daemon: many simultaneous observers —
        \\                                  binary frontends on <path>, NDJSON duplex agents on <path>.json
        \\                                  (--json: NDJSON directly on <path>; --exit-idle: quit when
        \\                                  the last observer disconnects)
        \\  surveyor ctl <verb> [args…]     drive the live session (default socket, or --socket <path>):
        \\    ctl focus orbit                       back to the whole machine
        \\    ctl focus flow <proto> <l> <lp> <r> <rp> [street|ground]
        \\    ctl focus app <comm> · ctl focus asn <n> · ctl focus host <addr>
        \\  surveyor --schema               print the machine-readable contract of every surface
        \\  surveyor --version              print the version and exit
        \\
        \\flags: --bpf (use the eBPF source if caps allow)  --socket <path>  --json  --exit-idle
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
/// one-shot shape; the Nexus ask). Capture-mode truth (F14) + listener inventory +
/// exposure/risk badges + flow counts. Always JSON — a summary is data, there is no
/// table twin. No rDNS wait: listeners are local truth, names don't gate the answer.
fn status(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool, geoip_dir: ?[]const u8) !void {
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
    const now = capture.nowMs(io);
    try src.tick(&table, now, &closed);

    const flows = try table.snapshot(gpa);
    defer gpa.free(flows);
    enricher.decorate(flows, now);

    var buf: [128 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try cartograph.json.writeStatus(w, flows, now, derivePosture(&src, pdns != null, &enricher));
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

/// Send the *authoritative* view-local session to a client as the minimal set of
/// `user_state` frames that reconstruct it: the `.profile` base, then a `.lens_toggle`
/// only for lenses that deviate from that profile's default. A connecting frontend thus
/// **inherits** surveyor's session instead of guessing — truth flows from one owner
/// (DECISIONS D22, the Seam-C anti-fork).
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

// ---- the shared session daemon (audit F5: one capture core, many observers) --------

/// One connected observer — a binary frontend (GTK/TUI) or an NDJSON agent. Both watch
/// the same capture core and the same shared cursor; only the rendering differs.
const Observer = struct {
    fd: i32,
    kind: enum { binary, ndjson },
    /// This observer's view-local session (profile/lens — D22) plus the cursor it holds.
    session: cartograph.SessionState = .{},
    /// Upstream reassembly: binary frames from a frontend…
    frames: ipc.FrameStream,
    /// …or JSON command lines from an agent.
    inbuf: std.ArrayList(u8) = .empty,
    wbuf: []u8,
    out: std.Io.File.Writer,
    dead: bool = false,

    fn create(gpa: std.mem.Allocator, io: std.Io, fd: i32, kind: @FieldType(Observer, "kind")) !*Observer {
        const ob = try gpa.create(Observer);
        errdefer gpa.destroy(ob);
        const wbuf = try gpa.alloc(u8, 128 * 1024);
        errdefer gpa.free(wbuf);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        ob.* = .{
            .fd = fd,
            .kind = kind,
            .frames = ipc.FrameStream.init(gpa),
            .wbuf = wbuf,
            .out = file.writer(io, wbuf),
        };
        return ob;
    }

    fn destroy(ob: *Observer, gpa: std.mem.Allocator) void {
        cartograph.usock.close(ob.fd); // F20: every accepted fd is closed exactly once
        ob.frames.deinit();
        ob.inbuf.deinit(gpa);
        gpa.free(ob.wbuf);
        gpa.destroy(ob);
    }

    fn w(ob: *Observer) *std.Io.Writer {
        return &ob.out.interface;
    }
};

/// The daemon's whole mutable state, so the per-event handlers stay small.
const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    observers: std.ArrayList(*Observer) = .empty,
    shared: cartograph.atlas.SharedSession = .{},
    posture: ipc.Posture,

    fn deinit(d: *Daemon) void {
        for (d.observers.items) |ob| ob.destroy(d.gpa);
        d.observers.deinit(d.gpa);
    }

    /// Greet a just-accepted observer with everything it needs to render truthfully:
    /// protocol hello, capture posture (F14), its inherited session, and the shared
    /// cursor if one is set (D24 inherit-on-connect).
    fn welcome(d: *Daemon, ob: *Observer) !void {
        if (d.shared.worthAnnouncing()) ob.session.focus = d.shared.focus;
        switch (ob.kind) {
            .binary => {
                try ipc.sendHello(ob.w());
                try ipc.sendPosture(ob.w(), d.posture);
                try sendSession(ob.w(), ob.session);
            },
            .ndjson => {
                const J = cartograph.json;
                try J.writeHelloEvent(ob.w(), ipc.protocol_version);
                try ob.w().writeByte('\n');
                try J.writePostureEvent(ob.w(), d.posture);
                try ob.w().writeByte('\n');
                try J.writeFocusEvent(ob.w(), ob.session.focus);
                try ob.w().writeByte('\n');
            },
        }
        try ob.w().flush();
    }

    /// The shared cursor moved (a human clicked a row, or an agent sent `ctl focus`):
    /// tell *every* observer, each in its own tongue. This is F4 — the broadcast that
    /// makes co-observation real. Write failures mark the observer dead; the sweep reaps.
    fn broadcastFocus(d: *Daemon) void {
        for (d.observers.items) |ob| {
            if (ob.dead) continue;
            _ = ob.session.apply(.{ .focus = d.shared.focus });
            const res = switch (ob.kind) {
                .binary => blk: {
                    ipc.sendUserState(ob.w(), .{ .focus = d.shared.focus }) catch |e| break :blk e;
                    break :blk ob.w().flush();
                },
                .ndjson => blk: {
                    cartograph.json.writeFocusEvent(ob.w(), d.shared.focus) catch |e| break :blk e;
                    ob.w().writeByte('\n') catch |e| break :blk e;
                    break :blk ob.w().flush();
                },
            };
            res catch {
                ob.dead = true;
            };
        }
    }

    /// Route one upstream act from a binary frontend (atlas.route — the one routing
    /// decision). Returns true if this observer's own session changed (echo it back).
    fn routeUserState(d: *Daemon, ob: *Observer, us: cartograph.ontology.UserState) bool {
        switch (cartograph.atlas.route(us)) {
            .view_local => return ob.session.apply(us),
            .shared => {
                if (d.shared.applyFocus(us.focus)) d.broadcastFocus();
                return false; // the broadcast already reached this observer
            },
            .store => return false, // persisted shared truth — the M3 store's seam
        }
    }

    /// Drain a readable binary frontend. `error.Closed` = it hung up.
    fn pumpBinary(d: *Daemon, ob: *Observer) !void {
        var rbuf: [16 * 1024]u8 = undefined;
        const rc = std.os.linux.read(ob.fd, &rbuf, rbuf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            else => return error.Closed,
        }
        if (rc == 0) return error.Closed;
        try ob.frames.push(rbuf[0..rc]);

        var changed = false;
        while (try ob.frames.next()) |frame| switch (frame) {
            .user_state => |us| {
                if (d.routeUserState(ob, us)) changed = true;
            },
            else => {}, // greeting/rule → shared store (M3); hello/flow_* never travel upstream
        };
        if (changed) {
            try sendSession(ob.w(), ob.session); // echo the authoritative session
            try ob.w().flush();
        }
    }

    /// Drain a readable NDJSON agent: JSON command lines in, ack/error lines out (F3).
    fn pumpNdjson(d: *Daemon, ob: *Observer) !void {
        var rbuf: [16 * 1024]u8 = undefined;
        const rc = std.os.linux.read(ob.fd, &rbuf, rbuf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            else => return error.Closed,
        }
        if (rc == 0) return error.Closed;
        try ob.inbuf.appendSlice(d.gpa, rbuf[0..rc]);
        if (ob.inbuf.items.len > 64 * 1024) return error.Closed; // a "line" that never ends is not a client

        const J = cartograph.json;
        while (std.mem.indexOfScalar(u8, ob.inbuf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, ob.inbuf.items[0..nl], " \t\r");
            if (line.len > 0) {
                switch (cartograph.agentcmd.parse(d.gpa, line)) {
                    .command => |cmd| switch (cmd) {
                        .watch => try J.writeAckEvent(ob.w(), "watch"),
                        .focus => |f| {
                            try J.writeAckEvent(ob.w(), "focus");
                            if (d.shared.applyFocus(f)) {
                                try ob.w().writeByte('\n');
                                try ob.w().flush();
                                d.broadcastFocus();
                                std.mem.copyForwards(u8, ob.inbuf.items, ob.inbuf.items[nl + 1 ..]);
                                ob.inbuf.shrinkRetainingCapacity(ob.inbuf.items.len - (nl + 1));
                                continue;
                            }
                        },
                    },
                    .err => |e| try J.writeErrorEvent(ob.w(), e.msg, e.fix),
                }
                try ob.w().writeByte('\n');
                try ob.w().flush();
            }
            std.mem.copyForwards(u8, ob.inbuf.items, ob.inbuf.items[nl + 1 ..]);
            ob.inbuf.shrinkRetainingCapacity(ob.inbuf.items.len - (nl + 1));
        }
    }

    /// Send this tick's truth to every observer, each in its own tongue.
    fn emitTick(d: *Daemon, flows: []const *cartograph.Flow, closed: []const cartograph.FlowKey, now: i64) void {
        const J = cartograph.json;
        for (d.observers.items) |ob| {
            if (ob.dead) continue;
            const res: anyerror!void = switch (ob.kind) {
                .binary => blk: {
                    for (flows) |f| ipc.sendFlowUpsert(ob.w(), f.*) catch |e| break :blk e;
                    for (closed) |k| ipc.sendFlowClosed(ob.w(), k) catch |e| break :blk e;
                    ipc.sendTick(ob.w(), now) catch |e| break :blk e;
                    break :blk ob.w().flush();
                },
                .ndjson => blk: {
                    for (flows) |f| {
                        J.writeFlowEvent(ob.w(), f) catch |e| break :blk e;
                        ob.w().writeByte('\n') catch |e| break :blk e;
                    }
                    for (closed) |k| {
                        J.writeClosedEvent(ob.w(), k) catch |e| break :blk e;
                        ob.w().writeByte('\n') catch |e| break :blk e;
                    }
                    J.writeTickEvent(ob.w(), now, flows.len) catch |e| break :blk e;
                    ob.w().writeByte('\n') catch |e| break :blk e;
                    break :blk ob.w().flush();
                },
            };
            res catch {
                ob.dead = true;
            };
        }
    }

    /// Reap dead observers — the F20 fix made structural: removal is the *only* place
    /// an observer is destroyed, and destroy() is the only place its fd closes.
    fn sweep(d: *Daemon) void {
        var i: usize = 0;
        while (i < d.observers.items.len) {
            if (d.observers.items[i].dead) {
                d.observers.swapRemove(i).destroy(d.gpa);
            } else i += 1;
        }
    }
};

/// `surveyor serve --socket <path>` — the shared session daemon (audit F5). ONE capture
/// core — one source, one FlowTable, one enricher — fanned out to every simultaneous
/// observer: binary frontends on `bin_path`, NDJSON agents (and `surveyor ctl`) on
/// `json_path`. All of them hold the same shared cursor; any of them can move it.
/// `exit_idle` ends the daemon when its last observer disconnects (the GUI-spawned
/// private daemon must not outlive the window that spawned it).
fn daemon(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin_path: ?[]const u8,
    json_path: []const u8,
    want_bpf: bool,
    geoip_dir: ?[]const u8,
    exit_idle: bool,
) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();
    var pdns = openPdns(io, &src);
    defer if (pdns) |*p| p.deinit();

    const bin_lfd: ?i32 = if (bin_path) |p| try cartograph.usock.listen(p) else null;
    defer if (bin_lfd) |fd| cartograph.usock.close(fd);
    const json_lfd = try cartograph.usock.listen(json_path);
    defer cartograph.usock.close(json_lfd);
    if (bin_lfd) |fd| cartograph.usock.setNonblocking(fd);
    cartograph.usock.setNonblocking(json_lfd);

    var d = Daemon{ .gpa = gpa, .io = io, .posture = derivePosture(&src, pdns != null, &enricher) };
    defer d.deinit();

    {
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &ebuf);
        var pbuf: [64]u8 = undefined;
        if (bin_path) |p| {
            try ew.interface.print("{s}surveyor{s} session daemon [{s}]\n  frontends: cartograph --socket {s}   (binary frames)\n  agents:    surveyor ctl --socket {s} …  or connect {s} (NDJSON duplex)\n", .{
                BOLD, RST, d.posture.describe(&pbuf), p, p, json_path,
            });
        } else {
            try ew.interface.print("{s}surveyor{s} session daemon [{s}]\n  agents: connect {s} (NDJSON duplex)\n", .{ BOLD, RST, d.posture.describe(&pbuf), json_path });
        }
        try ew.interface.flush();
    }

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);
    var pfds: std.ArrayList(std.os.linux.pollfd) = .empty;
    defer pfds.deinit(gpa);

    var had_observer = false;
    var next_tick = capture.nowMs(io); // fire the first capture immediately
    while (true) {
        // ---- capture + fan out, once per second -------------------------------
        const now = capture.nowMs(io);
        if (now >= next_tick) {
            closed.clearRetainingCapacity();
            try src.tick(&table, now, &closed);
            if (pdns) |*p| p.poll(&enricher, now);
            const flows = try table.snapshot(gpa);
            defer gpa.free(flows);
            enricher.decorate(flows, now);
            d.emitTick(flows, closed.items, now);
            next_tick = now + 1000;
        }

        d.sweep();
        if (d.observers.items.len > 0) had_observer = true;
        if (exit_idle and had_observer and d.observers.items.len == 0) return; // the window closed

        // ---- wait for: a new connection, upstream bytes, or the next tick -----
        pfds.clearRetainingCapacity();
        const IN = std.os.linux.POLL.IN;
        if (bin_lfd) |fd| try pfds.append(gpa, .{ .fd = fd, .events = IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = json_lfd, .events = IN, .revents = 0 });
        const fixed = pfds.items.len;
        for (d.observers.items) |ob| try pfds.append(gpa, .{ .fd = ob.fd, .events = IN, .revents = 0 });

        const remaining: i32 = @intCast(@max(0, @min(1000, next_tick - capture.nowMs(io))));
        const prc = std.os.linux.poll(pfds.items.ptr, @intCast(pfds.items.len), remaining);
        if (std.os.linux.errno(prc) != .SUCCESS or prc == 0) continue;

        // new observers (drain each ready listener fully — poll is level-triggered)
        var pi: usize = 0;
        if (bin_lfd != null) {
            if (pfds.items[pi].revents & IN != 0) acceptAll(&d, bin_lfd.?, .binary);
            pi += 1;
        }
        if (pfds.items[pi].revents & IN != 0) acceptAll(&d, json_lfd, .ndjson);

        // upstream bytes from existing observers (the observer list is append-only
        // within one iteration, and sweep() runs before the next poll builds)
        for (pfds.items[fixed..], 0..) |pfd, oi| {
            if (pfd.revents == 0) continue;
            const ob = d.observers.items[oi];
            const res = switch (ob.kind) {
                .binary => d.pumpBinary(ob),
                .ndjson => d.pumpNdjson(ob),
            };
            res catch {
                ob.dead = true;
            };
        }
    }
}

/// Accept every pending connection on a ready listener; failures (a raced-away client,
/// a non-owner peer) skip that connection, never kill the daemon.
fn acceptAll(d: *Daemon, lfd: i32, kind: @FieldType(Observer, "kind")) void {
    while (true) {
        const maybe = cartograph.usock.acceptNonblocking(lfd) catch return;
        const cfd = maybe orelse return;
        const ob = Observer.create(d.gpa, d.io, cfd, kind) catch {
            cartograph.usock.close(cfd);
            return;
        };
        d.welcome(ob) catch {
            ob.destroy(d.gpa);
            return;
        };
        d.observers.append(d.gpa, ob) catch {
            ob.destroy(d.gpa);
            return;
        };
    }
}

/// What the capture stack is *actually* doing (F14) — derived from the live objects,
/// so it can never drift from the truth it describes.
fn derivePosture(src: *Source, pdns_live: bool, enricher: *capture.enrich.Enricher) ipc.Posture {
    return .{
        .source = switch (src.*) {
            .diag => .diag,
            .hybrid => .hybrid,
        },
        .pdns = pdns_live,
        .geoip_asn = enricher.geo.asn != null,
        .geoip_country = enricher.geo.country != null,
    };
}

/// The capture→emit loop for the one-way pipe (`surveyor serve | …`), writing IPC
/// frames to stdout forever. Returns when the consumer hangs up or capture fails.
/// The socket path uses `daemon` instead — same frames, many observers.
fn streamLoop(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var src = try openSource(gpa, io, want_bpf);
    defer src.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();
    var enricher = capture.enrich.Enricher.init(gpa, io, geoip_dir);
    defer enricher.deinit();
    var pdns = openPdns(io, &src);
    defer if (pdns) |*p| p.deinit();

    try ipc.sendHello(w);
    try ipc.sendPosture(w, derivePosture(&src, pdns != null, &enricher)); // capture-mode truth (F14)
    try sendSession(w, .{});
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
        const remaining: i64 = @max(0, @min(1000, next_tick - capture.nowMs(io)));
        try io.sleep(std.Io.Duration.fromMilliseconds(@intCast(remaining)), .awake);
    }
}

/// `surveyor serve` — frames to stdout: the pipe path, `surveyor serve | cartograph --ipc`.
/// A pipe is one-way, so there is no upstream `user_state` channel here.
fn serve(gpa: std.mem.Allocator, io: std.Io, want_bpf: bool, geoip_dir: ?[]const u8) !void {
    var buf: [256 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    streamLoop(gpa, io, &fw.interface, want_bpf, geoip_dir) catch |err| return exitIfHangup(err);
}

/// The NDJSON event loop — the text twin of `streamLoop`'s binary frames (AGENT-INTERFACE
/// §"serve --json"). Same view-model, same 1 Hz cadence, emitted as one self-identifying
/// JSON object per line so an agent watches the *exact same live truth* the GUI renders —
/// `surveyor serve --json | jq -c 'select(.ev=="flow" and .fresh)'` — instead of re-polling
/// `snapshot`. Read-only: stdout is one-way; the duplex agent surface is the daemon's
/// `.json` socket (`serve --socket` / `surveyor ctl`).
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
    try J.writePostureEvent(w, derivePosture(&src, pdns != null, &enricher)); // capture-mode truth (F14)
    try w.writeByte('\n');
    // Inherit-on-connect: tell the agent the starting cursor (focus, R1), the same way the
    // binary path sends the session.
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

// ---- `surveyor ctl` — the agent's hands (audit F3) ---------------------------------

/// `surveyor ctl <verb> [args…] [--socket <path>]` — drive the live session from a
/// shell or an agent. Connects to the daemon's NDJSON socket, sends one command line
/// (built by the same `agentcmd` codec the daemon parses — no drift possible), prints
/// the daemon's ack/error line, and exits 0/2/3 accordingly. The default socket is the
/// box's well-known session rendezvous, so `surveyor ctl focus app firefox` just works
/// next to a double-clicked GUI.
fn ctl(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, args: *std.process.Args.Iterator) !void {
    _ = gpa;
    var verb: ?[]const u8 = null;
    var pos: [8][]const u8 = undefined;
    var npos: usize = 0;
    var sock_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--socket")) {
            sock_path = args.next() orelse return failUsage(io, "--socket needs a path", .{});
        } else if (std.mem.startsWith(u8, a, "--")) {
            return failUsage(io, "unknown flag '{s}' — see `surveyor --help`", .{a});
        } else if (verb == null) {
            verb = a;
        } else if (npos < pos.len) {
            pos[npos] = a;
            npos += 1;
        } else return failUsage(io, "too many arguments — see `surveyor --help`", .{});
    }
    const v = verb orelse return failUsage(io, "ctl needs a verb — try: surveyor ctl focus orbit", .{});

    // Build the focus from the shell grammar. Same targets as the JSON command surface.
    var focus: cartograph.Focus = undefined;
    if (std.mem.eql(u8, v, "focus")) {
        focus = parseCtlFocus(io, pos[0..npos]);
    } else {
        return failUsage(io, "unknown ctl verb '{s}' — supported: focus", .{v});
    }

    // The daemon's NDJSON socket: --socket as given, else its .json twin, else the
    // well-known default (where the double-clicked GUI hosts its session).
    var pbuf: [128]u8 = undefined;
    var jbuf: [136]u8 = undefined;
    const path: []const u8 = blk: {
        if (sock_path) |p| {
            // accept either the binary path (append .json) or the .json path directly
            if (std.mem.endsWith(u8, p, ".json")) break :blk p;
            const twin = std.fmt.bufPrint(&jbuf, "{s}.json", .{p}) catch break :blk p;
            if (std.Io.Dir.cwd().access(io, twin, .{})) |_| break :blk twin else |_| {}
            break :blk p;
        }
        const def = cartograph.usock.defaultPath(&pbuf, environ.getPosix("XDG_RUNTIME_DIR"));
        const twin = std.fmt.bufPrint(&jbuf, "{s}.json", .{def}) catch break :blk def;
        break :blk twin;
    };

    const fd = cartograph.usock.connect(path) catch
        return failCtl(io, "no live session at '{s}'", .{path}, "start one: surveyor serve --socket <path>, or open cartograph-gtk");
    defer cartograph.usock.close(fd);

    // one command line out…
    {
        var cbuf: [512]u8 = undefined;
        var cw = std.Io.Writer.fixed(&cbuf);
        cartograph.agentcmd.writeFocusCommand(&cw, focus) catch return failUsage(io, "command too long", .{});
        cw.writeByte('\n') catch return failUsage(io, "command too long", .{});
        const bytes = cw.buffered();
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.os.linux.write(fd, bytes.ptr + off, bytes.len - off);
            if (std.os.linux.errno(rc) != .SUCCESS)
                return failCtl(io, "the session hung up mid-command", .{}, "retry; if it persists, restart the daemon");
            off += rc;
        }
    }

    // …the daemon's answer back: skip stream events, print the first ack/error line.
    // Exit 0 on ack, 2 on error (the daemon named the problem + fix on the line).
    var acc: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    var deadline: i32 = 5000;
    while (deadline > 0) {
        var fds = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const prc = std.os.linux.poll(&fds, 1, 100);
        deadline -= 100;
        if (std.os.linux.errno(prc) != .SUCCESS or prc == 0) continue;
        if (used == acc.len) break;
        const rc = std.os.linux.read(fd, acc[used..].ptr, acc.len - used);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) break;
        used += rc;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, acc[0..used], start, '\n')) |nl| {
            const line = acc[start..nl];
            start = nl + 1;
            const is_ack = std.mem.indexOf(u8, line, "\"ev\":\"ack\"") != null;
            const is_err = std.mem.indexOf(u8, line, "\"ev\":\"error\"") != null;
            if (!is_ack and !is_err) continue; // hello/posture/flow/… — stream noise for ctl
            var obuf: [16 * 1024]u8 = undefined;
            var fw = std.Io.File.stdout().writer(io, &obuf);
            try fw.interface.print("{s}\n", .{line});
            try fw.interface.flush();
            std.process.exit(if (is_ack) 0 else 2);
        }
        std.mem.copyForwards(u8, &acc, acc[start..used]);
        used -= start;
    }
    return failCtl(io, "no answer from the session within 5s", .{}, "is the daemon healthy? restart it and retry");
}

/// The shell grammar for `ctl focus` — positional, human-typeable, mapped onto the
/// same Focus the JSON command carries.
fn parseCtlFocus(io: std.Io, pos: []const []const u8) cartograph.Focus {
    if (pos.len == 0) return failUsage(io, "ctl focus needs a target — orbit, flow, app, asn, or host", .{});
    const t = pos[0];
    if (std.mem.eql(u8, t, "orbit")) {
        if (pos.len != 1) return failUsage(io, "ctl focus orbit takes no arguments", .{});
        return .{ .shared = true };
    }
    if (std.mem.eql(u8, t, "app")) {
        if (pos.len != 2) return failUsage(io, "usage: surveyor ctl focus app <comm>", .{});
        return .{ .altitude = .region, .target = .{ .entity = .{ .app = cartograph.flow.Str(64).from(pos[1]) } }, .shared = true };
    }
    if (std.mem.eql(u8, t, "asn")) {
        if (pos.len != 2) return failUsage(io, "usage: surveyor ctl focus asn <number>", .{});
        const n = std.fmt.parseInt(u32, pos[1], 10) catch return failUsage(io, "'{s}' is not an AS number", .{pos[1]});
        return .{ .altitude = .region, .target = .{ .entity = .{ .asn = n } }, .shared = true };
    }
    if (std.mem.eql(u8, t, "host")) {
        if (pos.len != 2) return failUsage(io, "usage: surveyor ctl focus host <addr>", .{});
        const a = cartograph.agentcmd.parseAddr(pos[1]) orelse return failUsage(io, "'{s}' is not an IPv4/IPv6 address", .{pos[1]});
        return .{ .altitude = .region, .target = .{ .entity = .{ .host = a } }, .shared = true };
    }
    if (std.mem.eql(u8, t, "flow")) {
        if (pos.len < 6 or pos.len > 7)
            return failUsage(io, "usage: surveyor ctl focus flow <tcp|udp> <local> <lport> <remote> <rport> [street|ground]", .{});
        const proto: cartograph.Proto = if (std.mem.eql(u8, pos[1], "tcp")) .tcp else if (std.mem.eql(u8, pos[1], "udp")) .udp else return failUsage(io, "proto is tcp or udp, not '{s}'", .{pos[1]});
        const local = cartograph.agentcmd.parseAddr(pos[2]) orelse return failUsage(io, "'{s}' is not an address", .{pos[2]});
        const lp = std.fmt.parseInt(u16, pos[3], 10) catch return failUsage(io, "'{s}' is not a port", .{pos[3]});
        const remote = cartograph.agentcmd.parseAddr(pos[4]) orelse return failUsage(io, "'{s}' is not an address", .{pos[4]});
        const rp = std.fmt.parseInt(u16, pos[5], 10) catch return failUsage(io, "'{s}' is not a port", .{pos[5]});
        var altitude: cartograph.focus.Altitude = .street;
        if (pos.len == 7) {
            if (std.mem.eql(u8, pos[6], "ground")) {
                altitude = .ground;
            } else if (!std.mem.eql(u8, pos[6], "street"))
                return failUsage(io, "flow altitude is street or ground, not '{s}'", .{pos[6]});
        }
        return .{
            .altitude = altitude,
            .target = .{ .flow = .{ .proto = proto, .local = local, .local_port = lp, .remote = remote, .remote_port = rp } },
            .shared = true,
        };
    }
    return failUsage(io, "unknown focus target '{s}' — orbit, flow, app, asn, or host", .{t});
}

/// A usage error: message to stderr, exit 3 (the workspace convention R4 — a typo'd
/// verb/arg is a *usage* failure, distinct from a runtime one).
fn failUsage(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print("surveyor: " ++ fmt ++ "\n", fmt_args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(3);
}

/// A ctl runtime failure, with the fix named (the error contract): exit 2.
fn failCtl(io: std.Io, comptime fmt: []const u8, fmt_args: anytype, fix: []const u8) noreturn {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print("surveyor: " ++ fmt ++ " — {s}\n", fmt_args ++ .{fix}) catch {};
    fw.interface.flush() catch {};
    std.process.exit(2);
}
