//! cartograph-gtk — the GTK4 frontend: a live, attributed-flow window rendered
//! entirely from the shared `libcartograph` view-model, the visual sibling of the TUI.
//!
//!   cartograph-gtk --socket <path>   connect to `surveyor serve --socket <path>`
//!   surveyor serve | cartograph-gtk  read IPC frames from stdin (the pipe path)
//!
//! Parity by construction (FRONTENDS.md, D9): this binary decodes the *same* binary
//! IPC frames the TUI does, folds them into the *same* `FlowTable`, and colours rows
//! with the *same* design-language palette (`Category.hex()` is the truecolor twin of
//! the TUI's `Category.ansi()`, D14). A capability can never exist in one UI but not
//! the other — both are thin renderers over one brain.
//!
//! Privilege boundary (D6): this process is unprivileged. It only *reads* surveyor's
//! socket; surveyor is the side that holds the capabilities. The Unix socket is the seam.
//!
//! GTK is reached by **direct C FFI** (hand-written `extern` decls + linked system
//! gtk4/glib/gobject) rather than the zig-gobject codegen binding. Same reasoning as
//! libvaxis for the TUI: we are frozen on Zig 0.16 ahead of the ecosystem (D16), so we
//! ship a native renderer behind the view-model boundary now; a generated binding is a
//! drop-in swap later, not a rewrite. See FRONTENDS.md / DECISIONS D10.

const std = @import("std");
const cartograph = @import("cartograph");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const ipc = cartograph.ipc;
const lens = cartograph.lens;
const ontology = cartograph.ontology;
const Flow = cartograph.Flow;
const FlowTable = cartograph.FlowTable;
const SessionState = cartograph.SessionState;

// ---- minimal GTK4 / GLib / GObject C ABI ------------------------------------
// Only the handful of entry points this window needs. All GObject pointers are opaque
// (`?*anyopaque`); the C side knows their real types, the ABI is just pointers.

const GCallback = *const fn () callconv(.c) void;
const GUnixFDSourceFunc = *const fn (fd: c_int, condition: c_uint, user_data: ?*anyopaque) callconv(.c) c_int;
const GtkApplicationActivate = *const fn (app: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void;
// GtkEventControllerKey "key-pressed": (controller, keyval, keycode, modifiers, user_data) -> handled
const GtkKeyPressed = *const fn (ctrl: ?*anyopaque, keyval: c_uint, keycode: c_uint, state: c_uint, user_data: ?*anyopaque) callconv(.c) c_int;

// GApplicationFlags
const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;
// GIOCondition
const G_IO_IN: c_uint = 1;
const G_IO_ERR: c_uint = 8;
const G_IO_HUP: c_uint = 16;
// GtkAlign
const GTK_ALIGN_START: c_uint = 1;
// g_source return codes
const G_SOURCE_REMOVE: c_int = 0;
const G_SOURCE_CONTINUE: c_int = 1;

extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*anyopaque;
extern fn g_application_run(app: ?*anyopaque, argc: c_int, argv: ?[*]const ?[*:0]const u8) c_int;
extern fn g_application_quit(app: ?*anyopaque) void;
extern fn g_object_unref(object: ?*anyopaque) void;
extern fn g_signal_connect_data(instance: ?*anyopaque, detailed_signal: [*:0]const u8, c_handler: GCallback, data: ?*anyopaque, destroy_data: ?*anyopaque, connect_flags: c_uint) c_ulong;

extern fn gtk_application_window_new(app: ?*anyopaque) ?*anyopaque;
extern fn gtk_window_set_title(window: ?*anyopaque, title: [*:0]const u8) void;
extern fn gtk_window_set_default_size(window: ?*anyopaque, width: c_int, height: c_int) void;
extern fn gtk_window_present(window: ?*anyopaque) void;
extern fn gtk_window_set_child(window: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_scrolled_window_new() ?*anyopaque;
extern fn gtk_scrolled_window_set_child(sw: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_label_new(str: ?[*:0]const u8) ?*anyopaque;
extern fn gtk_label_set_markup(label: ?*anyopaque, markup: [*:0]const u8) void;
extern fn gtk_label_set_xalign(label: ?*anyopaque, xalign: f32) void;
extern fn gtk_label_set_yalign(label: ?*anyopaque, yalign: f32) void;
extern fn gtk_label_set_selectable(label: ?*anyopaque, setting: c_int) void;
extern fn gtk_widget_set_halign(widget: ?*anyopaque, alignment: c_uint) void;
extern fn gtk_widget_set_valign(widget: ?*anyopaque, alignment: c_uint) void;

extern fn g_unix_fd_add(fd: c_int, condition: c_uint, function: GUnixFDSourceFunc, user_data: ?*anyopaque) c_uint;

extern fn gtk_event_controller_key_new() ?*anyopaque;
extern fn gtk_widget_add_controller(widget: ?*anyopaque, controller: ?*anyopaque) void;

// design-language constants shared with the TUI's intent (DESIGN-LANGUAGE.md)
const amber = "#ffaf00"; // fresh / first-seen "glow until greeted"
const sky = "#5fafff"; // download-leaning rate
const tan = "#d7af87"; // upload-leaning rate
const dim = "#8a8a8a"; // grey: idle / structural

// ---- app state --------------------------------------------------------------

const App = struct {
    gpa: std.mem.Allocator,
    table: FlowTable,
    fd: std.posix.fd_t,
    upstream_fd: ?std.posix.fd_t = null, // writable socket → surveyor (null over a pipe)
    session: SessionState = .{},
    gapp: ?*anyopaque = null,
    label: ?*anyopaque = null,
    acc: std.ArrayList(u8) = .empty,
    markup: []u8, // big scratch buffer for one rendered frame (NUL-terminated)

    fn deinit(self: *App) void {
        self.table.deinit();
        self.acc.deinit(self.gpa);
        self.gpa.free(self.markup);
    }

    /// Send a user-state change upstream to surveyor (no-op over a one-way pipe). The
    /// one write path (D22): GTK never forks a private state cache — it drives the same
    /// `user_state` frame the TUI does, and renders what surveyor echoes back.
    fn sendUpstream(self: *App, us: ontology.UserState) void {
        const fd = self.upstream_fd orelse return;
        var buf: [ipc.max_frame]u8 = undefined;
        var bw = Writer.fixed(&buf);
        ipc.sendUserState(&bw, us) catch return;
        const bytes = bw.buffered();
        _ = std.os.linux.write(fd, bytes.ptr, bytes.len);
    }

    /// Parse all complete frames buffered in `acc`; returns true if a tick landed
    /// (identical framing to the TUI's drainFrames — one codec, both renderers).
    fn drainFrames(self: *App) !bool {
        const acc = &self.acc;
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
                // surveyor's authoritative session (inherit-on-connect + echo, D22)
                .user_state => |us| if (self.session.apply(us)) {
                    ticked = true;
                },
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

    fn redraw(self: *App) void {
        const flows = self.table.snapshot(self.gpa) catch return;
        defer self.gpa.free(flows);

        var w = Writer.fixed(self.markup[0 .. self.markup.len - 1]);
        renderMarkup(&w, flows, self.session) catch {}; // truncate gracefully if it ever overflows
        const n = w.buffered().len;
        self.markup[n] = 0;
        if (self.label) |l| gtk_label_set_markup(l, @ptrCast(self.markup.ptr));
    }
};

// ---- rendering: the same view-model, drawn as Pango markup ------------------

/// Write `s` with the three Pango-markup-significant bytes escaped. Display width is
/// the *original* length (escaping only changes the bytes, not the rendered columns).
fn esc(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}

/// Escaped `s`, left-aligned in a `width`-column monospace field (truncating if long).
fn col(w: *Writer, s: []const u8, width: usize) Writer.Error!void {
    const n = @min(s.len, width);
    try esc(w, s[0..n]);
    var pad = width - n;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
}

fn span(w: *Writer, color: []const u8, s: []const u8, width: usize) Writer.Error!void {
    try w.print("<span foreground=\"{s}\">", .{color});
    try col(w, s, width);
    try w.writeAll("</span>");
}

fn renderMarkup(w: *Writer, flows: []*Flow, session: SessionState) Writer.Error!void {
    // Lenses decide which columns are drawn — the same view-model gate the TUI uses, so
    // a toggle here shows/hides exactly what it shows/hides there (parity by construction).
    const set = session.activeLenses();
    const show_volume = set.contains(.volume);
    const show_endpoint = set.contains(.endpoint);

    var down_total: u64 = 0;
    var up_total: u64 = 0;
    var attributed: usize = 0;
    for (flows) |f| {
        down_total += f.rx_rate;
        up_total += f.tx_rate;
        if (f.attributed()) attributed += 1;
    }

    // everything monospace so the columns line up like the TUI
    try w.writeAll("<span font_family=\"monospace\">");

    // header / summary line
    var dbuf: [32]u8 = undefined;
    var ubuf: [32]u8 = undefined;
    try w.print(
        "<b>▟▖ cartograph</b>  <span foreground=\"{s}\">{d} flows · {d} attributed</span>   " ++
            "<span foreground=\"{s}\">↓ {s}</span>  <span foreground=\"{s}\">↑ {s}</span>\n",
        .{ dim, flows.len, attributed, sky, cartograph.humanRate(&dbuf, down_total), tan, cartograph.humanRate(&ubuf, up_total) },
    );

    // profile + active lenses — the user-state surface, so a toggle is *visible* (D22).
    // "p" cycles the profile; "1–6" toggle the six lenses; the row reflects surveyor's
    // authoritative session, not a private cache.
    try w.print("<span foreground=\"{s}\">profile </span><b>{s}</b>   <span foreground=\"{s}\">lens</span> ", .{ dim, session.profile.label(), dim });
    inline for (std.enums.values(lens.Lens), 1..) |l, n| {
        const on = set.contains(l);
        const color = if (on) sky else dim;
        const weight_open = if (on) "<b>" else "";
        const weight_close = if (on) "</b>" else "";
        try w.print("<span foreground=\"{s}\">{s}{d}:{s}{s}</span> ", .{ color, weight_open, n, l.label(), weight_close });
    }
    try w.writeAll("\n\n");

    // column header — only the columns the active lenses draw
    try w.print("<span foreground=\"{s}\">  ", .{dim});
    try col(w, "APP", 15);
    try col(w, "ENDPOINT", 32);
    if (show_volume) {
        try col(w, "THROUGHPUT", 12);
        try col(w, "TOTAL", 10);
    }
    if (show_endpoint) try col(w, "RTT", 7);
    try w.writeAll("</span>\n");

    // rows
    var ebuf: [64]u8 = undefined;
    var rbuf: [16]u8 = undefined;
    var sbuf: [16]u8 = undefined;
    var ttbuf: [16]u8 = undefined;
    for (flows) |f| {
        const cat = f.category;
        // fresh = amber dot (first-seen; "glow until greeted")
        if (f.fresh) {
            try w.print("<span foreground=\"{s}\">●</span> ", .{amber});
        } else {
            try w.writeAll("  ");
        }

        // app name + category glyph, in the category colour
        try w.print("<span foreground=\"{s}\">", .{cat.hex()});
        try col(w, f.name(), 13);
        try w.print(" {s}</span> ", .{cat.glyph()});

        // remote endpoint, category colour
        const ep = cartograph.endpoint(&ebuf, f.key.remote, f.key.remote_port);
        try span(w, cat.hex(), ep, 32);

        if (show_volume) {
            // throughput (rate-coloured), total bytes
            try span(w, rateColor(f), cartograph.humanRate(&rbuf, f.throughput()), 12);
            try span(w, dim, cartograph.humanBytes(&sbuf, f.rx_bytes + f.tx_bytes), 10);
        }

        if (show_endpoint) {
            const rtt = if (f.rtt_us == 0) "·" else std.fmt.bufPrint(&ttbuf, "{d:.0}ms", .{@as(f64, @floatFromInt(f.rtt_us)) / 1000.0}) catch "·";
            try span(w, dim, rtt, 7);
        }
        try w.writeAll("\n");
    }

    try w.writeAll("</span>");
}

fn rateColor(f: *Flow) []const u8 {
    if (f.throughput() == 0) return dim;
    return if (f.tx_rate > f.rx_rate) tan else sky;
}

// ---- GTK glue ---------------------------------------------------------------

fn onSocketReady(fd: c_int, condition: c_uint, user_data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    var rbuf: [64 * 1024]u8 = undefined;

    if (condition & (G_IO_HUP | G_IO_ERR) != 0) {
        g_application_quit(app.gapp);
        return G_SOURCE_REMOVE;
    }

    while (true) {
        const rc = std.os.linux.read(fd, &rbuf, rbuf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => break, // nothing more buffered right now
            else => {
                g_application_quit(app.gapp);
                return G_SOURCE_REMOVE;
            },
        }
        if (rc == 0) { // EOF: surveyor hung up
            g_application_quit(app.gapp);
            return G_SOURCE_REMOVE;
        }
        app.acc.appendSlice(app.gpa, rbuf[0..rc]) catch return G_SOURCE_CONTINUE;
    }

    if (app.drainFrames() catch false) app.redraw();
    return G_SOURCE_CONTINUE;
}

/// Keyboard: "p" cycles the profile, "1–6" toggle the six lenses. Each change goes
/// through the shared `SessionState` and travels the `user_state` frame upstream to
/// surveyor (D22) — the same one write path the TUI uses. We apply locally for a snappy
/// redraw; surveyor echoes the authoritative session back and we converge on it.
fn onKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, _: c_uint, user_data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const lens_keys = std.enums.values(lens.Lens);

    switch (keyval) {
        'p', 'P' => {
            app.session.nextProfile();
            app.sendUpstream(.{ .profile = app.session.profile });
        },
        '1'...'6' => {
            const idx = keyval - '1';
            if (idx >= lens_keys.len) return 0;
            const l = lens_keys[idx];
            const on = !app.session.lenses.contains(l);
            app.session.toggleLens(l, on);
            app.sendUpstream(.{ .lens_toggle = .{ .lens = l, .on = on } });
        },
        else => return 0, // not handled — let GTK have it
    }
    app.redraw();
    return 1; // handled
}

fn onActivate(gapp: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));

    const window = gtk_application_window_new(gapp);
    gtk_window_set_title(window, "cartograph — live flows");
    gtk_window_set_default_size(window, 920, 600);

    // a key controller on the window catches "p" / "1–6" anywhere in the window
    const keys = gtk_event_controller_key_new();
    _ = g_signal_connect_data(keys, "key-pressed", @ptrCast(@as(GtkKeyPressed, onKeyPressed)), app, null, 0);
    gtk_widget_add_controller(window, keys);

    const label = gtk_label_new(null);
    gtk_label_set_xalign(label, 0);
    gtk_label_set_yalign(label, 0);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_valign(label, GTK_ALIGN_START);
    gtk_label_set_selectable(label, 1); // it's data — let the user copy it
    app.label = label;

    const scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(scroller, label);
    gtk_window_set_child(window, scroller);

    app.redraw(); // draw the (possibly empty) table immediately
    _ = g_unix_fd_add(@intCast(app.fd), G_IO_IN | G_IO_HUP | G_IO_ERR, onSocketReady, app);

    gtk_window_present(window);
}

// ---- entry point ------------------------------------------------------------

fn connectWithRetry(io: std.Io, path: []const u8) !std.posix.fd_t {
    // surveyor may still be binding its socket when we launch; give it a moment.
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        if (cartograph.usock.connect(path)) |fd| {
            return fd;
        } else |err| {
            if (attempt >= 30) return err; // ~3s
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
    }
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 0o4000;
    const cur = linux.fcntl(fd, F_GETFL, 0);
    if (linux.errno(cur) != .SUCCESS) return;
    _ = linux.fcntl(fd, F_SETFL, cur | O_NONBLOCK);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var sock_path: ?[]const u8 = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--socket")) sock_path = args.next();
    }

    // The IPC source: a connected Unix socket (the daemon boundary) or stdin (the pipe).
    const fd: std.posix.fd_t = if (sock_path) |p|
        try connectWithRetry(io, p)
    else
        std.Io.File.stdin().handle;
    defer if (sock_path != null) cartograph.usock.close(fd);
    setNonBlocking(fd);

    var app: App = .{
        .gpa = gpa,
        .table = FlowTable.init(gpa),
        .fd = fd,
        // A socket is full-duplex, so toggles can travel upstream (D22). A pipe is one-way.
        .upstream_fd = if (sock_path != null) fd else null,
        .markup = try gpa.alloc(u8, 512 * 1024),
    };
    defer app.deinit();

    const gapp = gtk_application_new("org.cartograph.Gtk", G_APPLICATION_NON_UNIQUE);
    defer g_object_unref(gapp);
    app.gapp = gapp;

    _ = g_signal_connect_data(gapp, "activate", @ptrCast(@as(GtkApplicationActivate, onActivate)), &app, null, 0);
    const status = g_application_run(gapp, 0, null);
    if (status != 0) return error.GtkRunFailed;
}
