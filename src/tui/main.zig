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

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const ipc = cartograph.ipc;
const lens = cartograph.lens;
const Flow = cartograph.Flow;
const FlowTable = cartograph.FlowTable;

const tick_ms = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var use_ipc = false;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--ipc")) use_ipc = true;
    }

    var app = try App.init(gpa, io);
    defer app.deinit();

    if (use_ipc) try app.runIpc() else try app.runLocal();
}

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    table: FlowTable,
    tm: term.Term,
    out_state: std.Io.File.Writer,
    out_buf: []u8,
    profile: lens.Profile = .calm,
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

    /// Handle a buffer of key bytes; returns true if anything changed the view.
    fn handleKeys(self: *App, keys: []const u8) bool {
        var changed = false;
        for (keys) |k| switch (k) {
            'q', 'Q', 3 => self.quit = true, // 3 = Ctrl-C (raw mode)
            'p', 'P', '\t' => {
                self.profile = switch (self.profile) {
                    .calm => .nerd,
                    .nerd => .security,
                    .security => .resource,
                    .resource => .calm,
                };
                changed = true;
            },
            else => {},
        };
        return changed;
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

    // ---- IPC consumer loop (frames from surveyor on stdin) ------------------
    fn runIpc(self: *App) !void {
        try self.enterScreen();
        defer self.leaveScreen();

        const stdin_fd = std.Io.File.stdin().handle;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(self.gpa);
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
                try acc.appendSlice(self.gpa, rbuf[0..rc]);
                if (try self.drainFrames(&acc)) try self.draw("live · ipc");
            }
        }
    }

    /// Parse all complete frames buffered in `acc`; returns true if a tick landed.
    fn drainFrames(self: *App, acc: *std.ArrayList(u8)) !bool {
        var start: usize = 0;
        var ticked = false;
        while (acc.items.len - start >= 4) {
            const len = std.mem.readInt(u32, acc.items[start..][0..4], .little);
            if (acc.items.len - start < 4 + @as(usize, len)) break;
            const frame_bytes = acc.items[start .. start + 4 + len];
            var r = Reader.fixed(frame_bytes);
            if (try ipc.readFrame(&r)) |frame| switch (frame) {
                .flow_upsert => |f| try self.table.apply(f),
                .flow_closed => |k| self.table.remove(k),
                .tick => ticked = true,
                else => {},
            };
            start += 4 + len;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, acc.items, acc.items[start..]);
            acc.items.len -= start;
        }
        return ticked;
    }

    fn draw(self: *App, mode_label: []const u8) !void {
        const sz = self.tm.size();
        const flows = try self.table.snapshot(self.gpa);
        defer self.gpa.free(flows);
        try render(self.w(), flows, sz, self.profile, mode_label);
        try self.w().flush();
    }
};

// ---- rendering --------------------------------------------------------------

fn render(w: *Writer, flows: []*Flow, sz: term.Size, profile: lens.Profile, mode_label: []const u8) !void {
    const set = profile.lenses();

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
        urate,             term.dim,   mode_label,
        profile.label(),   term.reset,
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
    try w.writeAll("q quit · p profile · ");
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
