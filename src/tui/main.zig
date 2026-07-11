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
    var geoip_dir: ?[]const u8 = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--ipc")) {
            use_ipc = true;
        } else if (std.mem.eql(u8, a, "--socket")) {
            use_ipc = true;
            sock_path = args.next() orelse return fail(io, "--socket needs a path", .{});
        } else if (std.mem.eql(u8, a, "--geoip")) {
            geoip_dir = args.next() orelse return fail(io, "--geoip needs a directory", .{});
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            var buf: [64]u8 = undefined;
            var fw = std.Io.File.stdout().writer(io, &buf);
            try fw.interface.print("cartograph {s}\n", .{cartograph.version});
            try fw.interface.flush();
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [1024]u8 = undefined;
            var fw = std.Io.File.stdout().writer(io, &buf);
            try fw.interface.writeAll(
                \\cartograph — live attributed-flow TUI (the terminal expression)
                \\
                \\usage:
                \\  cartograph                    live map, capturing in-process (unprivileged)
                \\  cartograph --ipc              read binary IPC frames from stdin:
                \\                                    surveyor serve | cartograph --ipc
                \\  cartograph --socket <path>    connect to `surveyor serve --socket <path>`
                \\                                (full-duplex: profile/lens toggles go upstream)
                \\  cartograph --version | --help
                \\
                \\flags: --geoip <dir>  ASN+country mmdb dir for in-process capture
                \\                      (default ~/.local/share/cartograph/geoip)
                \\
                \\keys:  q quit · j/k or ↑/↓ select · Esc clear · p or Tab profile · 1-6 lenses
                \\
            );
            try fw.interface.flush();
            return;
        } else {
            return failUsage(io, "unknown flag '{s}' — see `cartograph --help`", .{a});
        }
    }
    // Same default as surveyor: in-process capture enriches locally (parity); over
    // IPC the names arrive on the frames and this dir is never touched.
    var geoip_buf: [1024]u8 = undefined;
    if (geoip_dir == null) {
        if (init.minimal.environ.getPosix("HOME")) |home| {
            geoip_dir = std.fmt.bufPrint(&geoip_buf, "{s}/.local/share/cartograph/geoip", .{home}) catch null;
        }
    }

    // Pre-flight the two first-run stumbles *before* entering the alt screen, so each
    // fails as one plain line naming the fix — never a stack trace mid-raw-mode.
    if (sock_path) |p| checkSocket(io, p);

    var app = App.init(gpa, io) catch |err| switch (err) {
        error.FileNotFound, error.NoDevice, error.AccessDenied => fail(io, "no controlling terminal — cartograph is a TUI; run it in a terminal " ++
            "(for scripts, use `surveyor snapshot --json`)", .{}),
        else => return err,
    };
    defer app.deinit();
    app.geoip_dir = geoip_dir;

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

/// A clean one-line failure: message to stderr, exit 2 — never a stack trace.
fn fail(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print("cartograph: " ++ fmt ++ "\n", fmt_args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(2);
}

/// A usage error (bad flag/verb): exit 3, per the workspace convention (R4).
fn failUsage(io: std.Io, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    fw.interface.print("cartograph: " ++ fmt ++ "\n", fmt_args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(3);
}

/// Pre-flight the surveyor socket so a bad path fails with the fix named, before the
/// terminal enters the alt screen (an error inside raw mode scrambles the shell).
fn checkSocket(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        fail(io, "no surveyor socket at '{s}' — start one with: surveyor serve --socket {s}", .{ path, path });
    };
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
    geoip_dir: ?[]const u8 = null,
    enricher: ?capture.enrich.Enricher = null, // in-process mode only (IPC flows arrive enriched)
    /// The selected flow (the street-altitude cursor's target). Key-based so it
    /// survives the table resorting under it every tick.
    selected_key: ?cartograph.FlowKey = null,
    /// Row order as of the last draw — what j/k navigate over.
    last_order: std.ArrayList(cartograph.FlowKey) = .empty,
    /// Capture-mode truth from the producer (F14) — shown in the header over IPC.
    posture: ?ipc.Posture = null,
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
        if (self.enricher) |*e| e.deinit();
        self.last_order.deinit(self.gpa);
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
    /// can never fork a private state cache. Selection (j/k/arrows) moves the shared
    /// cursor (D24): row → street-altitude flow focus → the same `user_state` frame.
    fn handleKeys(self: *App, keys: []const u8) bool {
        var changed = false;
        var i: usize = 0;
        while (i < keys.len) : (i += 1) switch (keys[i]) {
            'q', 'Q', 3 => self.quit = true, // 3 = Ctrl-C (raw mode)
            'p', 'P', '\t' => {
                self.session.nextProfile();
                self.sendUpstream(.{ .profile = self.session.profile });
                changed = true;
            },
            '1'...'6' => {
                const idx = keys[i] - '1';
                if (idx < lens_keys.len) {
                    const l = lens_keys[idx];
                    const on = !self.session.lenses.contains(l);
                    self.session.toggleLens(l, on);
                    self.sendUpstream(.{ .lens_toggle = .{ .lens = l, .on = on } });
                    changed = true;
                }
            },
            'j' => changed = self.moveSelection(1) or changed,
            'k' => changed = self.moveSelection(-1) or changed,
            0x1b => {
                // ESC [ A/B = arrow up/down; a bare ESC clears the selection (back to orbit)
                if (i + 2 < keys.len and keys[i + 1] == '[' and (keys[i + 2] == 'A' or keys[i + 2] == 'B')) {
                    changed = self.moveSelection(if (keys[i + 2] == 'B') 1 else -1) or changed;
                    i += 2;
                } else {
                    changed = self.clearSelection() or changed;
                }
            },
            else => {},
        };
        return changed;
    }

    /// Move the selection cursor over the last drawn row order; wires the row to the
    /// shared focus seam (street altitude on that flow) and sends it upstream as the
    /// **session** cursor (D24/F4) — surveyor broadcasts it to every observer.
    fn moveSelection(self: *App, delta: i32) bool {
        const order = self.last_order.items;
        if (order.len == 0) return false;
        var idx: i64 = -1;
        if (self.selected_key) |sk| {
            for (order, 0..) |k, j| {
                if (std.meta.eql(k, sk)) {
                    idx = @intCast(j);
                    break;
                }
            }
        }
        idx = if (idx < 0 and delta < 0) @as(i64, @intCast(order.len - 1)) else idx + delta;
        idx = std.math.clamp(idx, 0, @as(i64, @intCast(order.len - 1)));
        const key = order[@intCast(idx)];
        self.selected_key = key;
        const f = cartograph.Focus{ .altitude = .street, .target = .{ .flow = key }, .shared = true };
        self.session.setFocus(f);
        self.sendUpstream(.{ .focus = f });
        return true;
    }

    fn clearSelection(self: *App) bool {
        if (self.selected_key == null) return false;
        self.selected_key = null;
        self.session.setFocus(.{ .shared = true }); // back to the orbit establishing shot
        self.sendUpstream(.{ .focus = .{ .shared = true } });
        return true;
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
        self.enricher = capture.enrich.Enricher.init(self.gpa, self.io, self.geoip_dir);

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
            // surveyor's authoritative session (inherit-on-connect + echo + shared-cursor
            // broadcast, D22/D24): the frontend renders from what the one owner confirms.
            .user_state => |us| if (self.session.apply(us)) {
                // co-observation is *visible* (F4): the broadcast cursor moves this
                // window's row highlight, exactly as a local j/k would
                if (us == .focus) self.selected_key = switch (us.focus.target) {
                    .flow => |key| key,
                    else => null,
                };
                ticked = true;
            },
            .posture => |p| {
                self.posture = p; // capture-mode truth in the header (F14)
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
        if (self.enricher) |*e| e.decorate(flows, capture.nowMs(self.io)); // parity with surveyor's post-pass
        self.last_order.clearRetainingCapacity(); // what j/k navigate next
        for (flows) |f| try self.last_order.append(self.gpa, f.key);
        try render(self.w(), flows, sz, self.session, mode_label, self.selected_key, capture.nowMs(self.io), self.posture);
        try self.w().flush();
    }
};

// ---- rendering --------------------------------------------------------------

fn render(w: *Writer, flows: []*Flow, sz: term.Size, session: SessionState, mode_label: []const u8, selected_key: ?cartograph.FlowKey, now_ms: i64, posture: ?ipc.Posture) !void {
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
    // ◌ this view: the profile/lens controls reach only this window (D22/D23).
    const sc = cartograph.scope.Scope.view;
    var pbuf: [64]u8 = undefined;
    const posture_label: []const u8 = if (posture) |p| p.describe(&pbuf) else mode_label;
    try w.print("{s}{s}▟▖ cartograph{s}  {s}·{s}  {d} flows · {d} attributed    {s}↓{s} {s}  {s}↑{s} {s}    {s}{s} [{s}] {s} {s}{s}", .{
        term.bold,         sky,        term.reset,
        term.dim,          term.reset, flows.len,
        attributed,        sky,        term.reset,
        drate,             tan,        term.reset,
        urate,                     term.dim, posture_label,
        session.profile.label(),   sc.glyph(), sc.label(), term.reset,
    });
    try w.writeAll(term.clear_to_eol ++ "\r\n");

    // --- column header -------------------------------------------------------
    try w.writeAll(term.dim);
    try col(w, "APP", 15);
    try w.writeAll("  ");
    try col(w, "ENDPOINT", 32);
    if (set.contains(.endpoint)) try col(w, "WHO", 24);
    if (set.contains(.volume)) {
        try col(w, "THROUGHPUT", cartograph.sparkline.spark_len + 12);
        try col(w, "TOTAL", 10);
    }
    if (set.contains(.endpoint)) try col(w, "RTT", 7);
    try w.writeAll(term.reset ++ term.clear_to_eol ++ "\r\n");

    // --- the Why panel (the selected flow, narrated) ---------------------------
    // Rendered into a scratch first so the row budget knows how many lines it needs.
    var why_buf: [2048]u8 = undefined;
    var why_text: []const u8 = "";
    var selected_flow: ?*Flow = null;
    if (selected_key) |sk| {
        for (flows) |f| {
            if (std.meta.eql(f.key, sk)) {
                selected_flow = f;
                break;
            }
        }
        var ww = Writer.fixed(&why_buf);
        if (selected_flow) |f| {
            cartograph.why.describe(&ww, f, now_ms) catch {};
        } else {
            ww.writeAll("that conversation has ended\n") catch {};
        }
        why_text = ww.buffered();
    }
    const why_lines: usize = if (why_text.len == 0) 0 else std.mem.count(u8, why_text, "\n") + 1; // +1 = headline

    // --- rows ----------------------------------------------------------------
    const header_rows = 3;
    const footer_rows = 2;
    const reserved = header_rows + footer_rows + why_lines;
    const max_rows: usize = if (sz.rows > reserved + 1) sz.rows - reserved else 1;
    const shown = @min(max_rows, flows.len);

    var i: usize = 0;
    while (i < shown) : (i += 1) {
        const is_sel = if (selected_key) |sk| std.meta.eql(flows[i].key, sk) else false;
        if (is_sel) try w.writeAll("\x1b[48;5;236m"); // quiet slate highlight behind the cursor row
        try renderRow(w, flows[i], set);
        if (is_sel) try w.writeAll(term.reset);
        try w.writeAll(term.clear_to_eol ++ "\r\n");
    }

    // clear any rows left over from a previous, longer frame
    try w.writeAll("\x1b[0J");

    // --- the Why panel body ----------------------------------------------------
    if (why_lines > 0 and sz.rows > footer_rows + why_lines + 1) {
        try w.print("\x1b[{d};1H", .{sz.rows - footer_rows - why_lines + 1});
        // headline: the focus line — the same cursor the agent's `focus` event carries (D24)
        var fb: [160]u8 = undefined;
        try w.print("{s}⌖ {s}{s}", .{ sky, session.focus.describe(&fb), term.reset });
        if (selected_flow) |f| {
            try w.writeAll(term.dim ++ "  — " ++ term.reset);
            try cartograph.why.headline(w, f);
        }
        try w.writeAll(term.clear_to_eol ++ "\r\n");
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, why_text, "\n"), '\n');
        while (lines.next()) |line| {
            try w.print("{s}{s}{s}", .{ term.dim, line, term.reset });
            try w.writeAll(term.clear_to_eol ++ "\r\n");
        }
    }

    // --- footer --------------------------------------------------------------
    try w.print("\x1b[{d};1H{s}", .{ sz.rows, term.dim });
    try w.writeAll("q quit · p profile · 1-6 lens · j/k select · esc orbit · ");
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

    // endpoint (remote): the S1 name when known, the bare address otherwise —
    // category-colored either way, port kept visible
    var ebuf: [64]u8 = undefined;
    const ep = if (f.remote_name.len > 0) blk: {
        var ew = Writer.fixed(&ebuf);
        const name = f.remote_name.slice();
        ew.writeAll(name[0..@min(name.len, 25)]) catch {};
        ew.print(":{d}", .{f.key.remote_port}) catch {};
        break :blk ew.buffered();
    } else cartograph.endpoint(&ebuf, f.key.remote, f.key.remote_port);
    try w.writeAll(cat.ansi());
    try col(w, ep, 32);
    try w.writeAll(term.reset);

    if (set.contains(.endpoint)) {
        var wbuf: [48]u8 = undefined;
        const who = f.whoDisplay(&wbuf);
        try w.writeAll(term.dim);
        try col(w, who[0..@min(who.len, 23)], 24);
        try w.writeAll(term.reset);
    }

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
