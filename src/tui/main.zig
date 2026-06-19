//! cartograph — the first frontend: a live, attributed-flow TUI rendered entirely
//! from the shared `libcartograph` view-model.
//!
//!   cartograph          live map, capturing in-process (M1: unprivileged /proc + diag)
//!   cartograph --ipc    same map, fed by `surveyor serve` over the binary IPC:
//!                           surveyor serve | cartograph --ipc
//!
//! Either way the screen is drawn from a `FlowTable` by the same `render()` — the
//! transport and capture source are swappable behind the view-model.

const std = @import("std");
const cartograph = @import("cartograph");
const capture = @import("capture");
const term = @import("term.zig");

const Writer = std.Io.Writer;
const ipc = cartograph.ipc;
const lens = cartograph.lens;
const ontology = cartograph.ontology;
const Flow = cartograph.Flow;
const FlowTable = cartograph.FlowTable;
const SessionState = cartograph.SessionState;

const tick_ms = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var use_ipc = false;
    var sock_path: ?[]const u8 = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--ipc")) {
            use_ipc = true;
        } else if (std.mem.eql(u8, a, "--socket")) {
            use_ipc = true;
            sock_path = args.next();
        }
    }

    var app = try App.init(gpa, io);
    defer app.deinit();

    if (use_ipc) {
        // Frames arrive on stdin (the pipe) or a Unix socket (the daemon boundary) —
        // same codec, same render() either way.
        const ipc_fd = if (sock_path) |p| try cartograph.usock.connect(p) else std.Io.File.stdin().handle;
        defer if (sock_path != null) cartograph.usock.close(ipc_fd);
        // A socket is full-duplex, so profile/lens toggles can travel *upstream* to
        // surveyor (D22). A pipe is one-way: view-only, no upstream.
        if (sock_path != null) app.upstream_fd = ipc_fd;
        try app.runIpc(ipc_fd);
    } else try app.runLocal();
}

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    table: FlowTable,
    tm: term.Term,
    out_state: std.Io.File.Writer,
    out_buf: []u8,
    session: SessionState = .{},
    upstream_fd: ?std.posix.fd_t = null, // writable socket → surveyor, when over IPC
    quit: bool = false,

    fn init(gpa: std.mem.Allocator, io: std.Io) !App {
        const buf = try gpa.alloc(u8, 256 * 1024);
        errdefer gpa.free(buf);
        return .{
            .gpa = gpa,
            .io = io,
            .table = FlowTable.init(gpa),
            .tm = try term.Term.init(io),
            .out_state = std.Io.File.stdout().writer(io, buf),
            .out_buf = buf,
        };
    }

    fn deinit(self: *App) void {
        self.table.deinit();
        self.tm.deinit();
        self.gpa.free(self.out_buf);
    }

    fn enterScreen(self: *App) !void {
        try self.tm.enterRaw();
        try self.w().writeAll(term.alt_screen_enter ++ term.cursor_hide ++ term.clear_screen);
        try self.w().flush();
    }

    fn leaveScreen(self: *App) void {
        self.tm.leaveRaw();
        self.w().writeAll(term.alt_screen_leave ++ term.cursor_show) catch {};
        self.w().flush() catch {};
    }

    // The interface pointer must be taken from the stored writer state each use.
    fn w(self: *App) *Writer {
        return &self.out_state.interface;
    }

    /// The six toggleable lenses, in enum order, bound to number keys 1–6.
    const lens_keys = std.enums.values(lens.Lens);

    /// Handle a buffer of key bytes; returns true if anything changed the view. Every
    /// profile/lens change goes through `SessionState` and (over a socket) travels the
    /// `user_state` frame upstream to surveyor — the one write path (D22), so TUI and GTK
    /// can never fork a private state cache.
    fn handleKeys(self: *App, keys: []const u8) bool {
        var changed = false;
        for (keys) |k| switch (k) {
            'q', 'Q', 3 => self.quit = true, // 3 = Ctrl-C (raw mode)
            'p', 'P', '\t' => {
                self.session.nextProfile();
                self.sendUpstream(.{ .profile = self.session.profile });
                changed = true;
            },
            '1'...'6' => {
                const idx = k - '1';
                if (idx < lens_keys.len) {
                    const l = lens_keys[idx];
                    const on = !self.session.lenses.contains(l);
                    self.session.toggleLens(l, on);
                    self.sendUpstream(.{ .lens_toggle = .{ .lens = l, .on = on } });
                    changed = true;
                }
            },
            else => {},
        };
        return changed;
    }

    /// Send a user-state change upstream to surveyor (no-op without a writable socket:
    /// in-process and pipe modes own their session locally).
    fn sendUpstream(self: *App, us: ontology.UserState) void {
        const fd = self.upstream_fd orelse return;
        var buf: [ipc.max_frame]u8 = undefined;
        var bw = Writer.fixed(&buf);
        ipc.sendUserState(&bw, us) catch return;
        const bytes = bw.buffered();
        _ = std.os.linux.write(fd, bytes.ptr, bytes.len);
    }

    // ---- in-process capture loop --------------------------------------------
    fn runLocal(self: *App) !void {
        var cap = try capture.Capturer.init(self.gpa, self.io);
        defer cap.deinit();

        try self.enterScreen();
        defer self.leaveScreen();

        var last_tick: i64 = -tick_ms; // force an immediate first capture
        while (!self.quit) {
            const now = capture.nowMs(self.io);
            if (now - last_tick >= tick_ms) {
                self.table.beginCycle();
                try cap.refresh(&self.table, now);
                var closed: std.ArrayList(cartograph.FlowKey) = .empty;
                defer closed.deinit(self.gpa);
                try self.table.collectClosed(&closed);
                last_tick = now;
                try self.draw("live · in-process");
            }
            const wait: i32 = @intCast(@max(10, tick_ms - (capture.nowMs(self.io) - last_tick)));
            if (term.pollIn(self.tm.ttyFd(), null, wait) & 0b01 != 0) {
                var kb: [32]u8 = undefined;
                if (self.handleKeys(self.tm.readKeys(&kb))) try self.draw("live · in-process");
            }
        }
    }

    // ---- IPC consumer loop (frames from surveyor on `ipc_fd`) ---------------
    // `ipc_fd` is stdin (pipe) or a connected Unix socket (daemon boundary).
    fn runIpc(self: *App, ipc_fd: std.posix.fd_t) !void {
        try self.enterScreen();
        defer self.leaveScreen();

        const stdin_fd = ipc_fd;
        var frames = ipc.FrameStream.init(self.gpa);
        defer frames.deinit();
        var rbuf: [64 * 1024]u8 = undefined;

        try self.draw("live · ipc");
        while (!self.quit) {
            const mask = term.pollIn(stdin_fd, self.tm.ttyFd(), tick_ms);
            if (mask & 0b10 != 0) {
                var kb: [32]u8 = undefined;
                if (self.handleKeys(self.tm.readKeys(&kb))) try self.draw("live · ipc");
            }
            if (mask & 0b01 != 0) {
                const rc = std.os.linux.read(stdin_fd, &rbuf, rbuf.len);
                if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) break; // EOF: surveyor gone
                try frames.push(rbuf[0..rc]);
                if (try self.drainFrames(&frames)) try self.draw("live · ipc");
            }
        }
    }

    /// Apply every complete frame the stream holds; returns true if a tick landed.
    fn drainFrames(self: *App, frames: *ipc.FrameStream) !bool {
        var ticked = false;
        while (try frames.next()) |frame| switch (frame) {
            .flow_upsert => |f| try self.table.apply(f),
            .flow_closed => |k| self.table.remove(k),
            // surveyor's authoritative session (inherit-on-connect + echo, D22): the
            // frontend renders from what the one owner confirms, never a private cache.
            .user_state => |us| if (self.session.apply(us)) {
                ticked = true;
            },
            .tick => ticked = true,
            else => {},
        };
        return ticked;
    }

    fn draw(self: *App, mode_label: []const u8) !void {
        const sz = self.tm.size();
        const flows = try self.table.snapshot(self.gpa);
        defer self.gpa.free(flows);
        try render(self.w(), flows, sz, self.session, mode_label);
        try self.w().flush();
    }
};

// ---- rendering --------------------------------------------------------------

fn render(w: *Writer, flows: []*Flow, sz: term.Size, session: SessionState, mode_label: []const u8) !void {
    const set = session.activeLenses();

    var down_total: u64 = 0;
    var up_total: u64 = 0;
    var attributed: usize = 0;
    for (flows) |f| {
        down_total += f.rx_rate;
        up_total += f.tx_rate;
        if (f.attributed()) attributed += 1;
    }

    try w.writeAll(term.cursor_home);

    // --- header --------------------------------------------------------------
    const sky = "\x1b[38;5;75m";
    const tan = "\x1b[38;5;180m";
    var dbuf: [32]u8 = undefined;
    var ubuf: [32]u8 = undefined;
    const drate = cartograph.humanRate(&dbuf, down_total);
    const urate = cartograph.humanRate(&ubuf, up_total);
    try w.print("{s}{s}▟▖ cartograph{s}  {s}·{s}  {d} flows · {d} attributed    {s}↓{s} {s}  {s}↑{s} {s}    {s}{s} [{s}]{s}", .{
        term.bold,         sky,        term.reset,
        term.dim,          term.reset, flows.len,
        attributed,        sky,        term.reset,
        drate,             tan,        term.reset,
        urate,                     term.dim, mode_label,
        session.profile.label(),   term.reset,
    });
    try w.writeAll(term.clear_to_eol ++ "\r\n");

    // --- column header -------------------------------------------------------
    try w.writeAll(term.dim);
    try col(w, "APP", 15);
    try w.writeAll("  ");
    try col(w, "ENDPOINT", 32);
    if (set.contains(.volume)) {
        try col(w, "THROUGHPUT", cartograph.sparkline.spark_len + 12);
        try col(w, "TOTAL", 10);
    }
    if (set.contains(.endpoint)) try col(w, "RTT", 7);
    try w.writeAll(term.reset ++ term.clear_to_eol ++ "\r\n");

    // --- rows ----------------------------------------------------------------
    const header_rows = 3;
    const footer_rows = 2;
    const max_rows: usize = if (sz.rows > header_rows + footer_rows + 1) sz.rows - header_rows - footer_rows else 1;
    const shown = @min(max_rows, flows.len);

    var i: usize = 0;
    while (i < shown) : (i += 1) {
        try renderRow(w, flows[i], set);
        try w.writeAll(term.clear_to_eol ++ "\r\n");
    }

    // clear any rows left over from a previous, longer frame
    try w.writeAll("\x1b[0J");

    // --- footer --------------------------------------------------------------
    try w.print("\x1b[{d};1H{s}", .{ sz.rows, term.dim });
    try w.writeAll("q quit · p profile · 1-6 lens · ");
    try legend(w);
    try w.writeAll(term.reset ++ term.clear_to_eol);
}

fn renderRow(w: *Writer, f: *Flow, set: lens.Set) !void {
    const cat = f.category;

    // fresh = amber dot (first-seen, "glow until greeted")
    if (f.fresh) {
        try w.writeAll("\x1b[38;5;214m●\x1b[0m ");
    } else {
        try w.writeAll("  ");
    }

    // app (category-colored), then glyph
    try w.writeAll(cat.ansi());
    try col(w, f.name(), 13);
    try w.print(" {s}{s} ", .{ cat.glyph(), term.reset });

    // endpoint (remote), category-colored
    var ebuf: [64]u8 = undefined;
    const ep = cartograph.endpoint(&ebuf, f.key.remote, f.key.remote_port);
    try w.writeAll(cat.ansi());
    try col(w, ep, 32);
    try w.writeAll(term.reset);

    if (set.contains(.volume)) {
        // sparkline + live rate
        try w.writeAll(rateColor(f));
        try f.rates.write(w);
        try w.writeAll(term.reset);
        var rbuf: [16]u8 = undefined;
        try w.writeByte(' ');
        try col(w, cartograph.humanRate(&rbuf, f.throughput()), 11);

        var sum: [16]u8 = undefined;
        try col(w, cartograph.humanBytes(&sum, f.rx_bytes + f.tx_bytes), 10);
    }

    if (set.contains(.endpoint)) {
        var rtt: [12]u8 = undefined;
        const s = if (f.rtt_us == 0) "·" else std.fmt.bufPrint(&rtt, "{d:.0}ms", .{@as(f64, @floatFromInt(f.rtt_us)) / 1000.0}) catch "·";
        try w.writeAll(term.dim);
        try col(w, s, 7);
        try w.writeAll(term.reset);
    }
}

fn rateColor(f: *Flow) []const u8 {
    if (f.throughput() == 0) return term.dim;
    if (f.tx_rate > f.rx_rate) return "\x1b[38;5;180m"; // upload-leaning = tan
    return "\x1b[38;5;75m"; // download-leaning = sky
}

fn legend(w: *Writer) !void {
    const cats = [_]cartograph.Category{ .web, .lan, .dns, .loopback, .listen };
    for (cats) |c| {
        try w.print("{s}{s}{s} {s}  ", .{ c.ansi(), c.glyph(), term.reset ++ term.dim, c.label() });
    }
}

/// Write `s` left-aligned in a field of `width` columns (byte-truncating if long).
fn col(w: *Writer, s: []const u8, width: usize) !void {
    const n = @min(s.len, width);
    try w.writeAll(s[0..n]);
    var pad = width - n;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
}
