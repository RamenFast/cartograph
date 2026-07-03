//! cartograph-gtk — the GTK4 frontend: a live, attributed-flow *application* (V1/S2)
//! rendered entirely from the shared `libcartograph` view-model, the visual sibling
//! of the TUI.
//!
//!   cartograph-gtk --socket <path>   connect to `surveyor serve --socket <path>`
//!   surveyor serve | cartograph-gtk  read IPC frames from stdin (the pipe path)
//!
//! Layout: a paned window — the live flow list on the left (a `GtkListBox` whose rows
//! are created/updated/removed *individually*, never rebuilt wholesale), and the docked
//! **"Why" panel** on the right narrating the selected flow from `cartograph.why`
//! (the same pure narration the TUI footer shows — parity, R5). Selecting a row moves
//! the **shared cursor** (D24): street altitude on that flow, sent upstream as a
//! `user_state{focus}` frame so surveyor (and any watching agent) sees the same cursor.
//!
//! Parity by construction (FRONTENDS.md, D9): this binary decodes the *same* binary
//! IPC frames the TUI does, folds them into the *same* `FlowTable`, and colours rows
//! with the *same* design-language palette (`Category.hex()` = the truecolor twin of
//! `Category.ansi()`, D14).
//!
//! Privilege boundary (D6): this process is unprivileged. It only *reads* surveyor's
//! socket; surveyor is the side that holds the capabilities.
//!
//! GTK is reached by **direct C FFI** (hand-written `extern` decls + linked system
//! gtk4/glib/gobject) rather than the zig-gobject codegen binding — we are frozen on
//! Zig 0.16 ahead of the ecosystem (D16); a generated binding is a drop-in swap later.

const std = @import("std");
const cartograph = @import("cartograph");

const Writer = std.Io.Writer;
const ipc = cartograph.ipc;
const lens = cartograph.lens;
const ontology = cartograph.ontology;
const Flow = cartograph.Flow;
const FlowKey = cartograph.FlowKey;
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
// GtkListBox "row-selected": (box, row-or-null, user_data)
const GtkRowSelected = *const fn (box: ?*anyopaque, row: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void;
const GtkListBoxSortFunc = *const fn (row1: ?*anyopaque, row2: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int;

// GApplicationFlags
const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;
// GIOCondition
const G_IO_IN: c_uint = 1;
const G_IO_ERR: c_uint = 8;
const G_IO_HUP: c_uint = 16;
// GtkAlign
const GTK_ALIGN_START: c_uint = 1;
// GtkOrientation
const GTK_ORIENTATION_HORIZONTAL: c_uint = 0;
const GTK_ORIENTATION_VERTICAL: c_uint = 1;
// g_source return codes
const G_SOURCE_REMOVE: c_int = 0;
const G_SOURCE_CONTINUE: c_int = 1;

extern fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*anyopaque;
extern fn g_application_run(app: ?*anyopaque, argc: c_int, argv: ?[*]const ?[*:0]const u8) c_int;
extern fn g_application_quit(app: ?*anyopaque) void;
extern fn g_object_unref(object: ?*anyopaque) void;
extern fn g_signal_connect_data(instance: ?*anyopaque, detailed_signal: [*:0]const u8, c_handler: GCallback, data: ?*anyopaque, destroy_data: ?*anyopaque, connect_flags: c_uint) c_ulong;
extern fn g_object_set_data(object: ?*anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
extern fn g_object_get_data(object: ?*anyopaque, key: [*:0]const u8) ?*anyopaque;

extern fn gtk_application_window_new(app: ?*anyopaque) ?*anyopaque;
extern fn gtk_window_set_title(window: ?*anyopaque, title: [*:0]const u8) void;
extern fn gtk_window_set_default_size(window: ?*anyopaque, width: c_int, height: c_int) void;
extern fn gtk_window_present(window: ?*anyopaque) void;
extern fn gtk_window_set_child(window: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_scrolled_window_new() ?*anyopaque;
extern fn gtk_scrolled_window_set_child(sw: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_paned_new(orientation: c_uint) ?*anyopaque;
extern fn gtk_paned_set_start_child(paned: ?*anyopaque, child: ?*anyopaque) void;
extern fn gtk_paned_set_end_child(paned: ?*anyopaque, child: ?*anyopaque) void;
extern fn gtk_paned_set_position(paned: ?*anyopaque, position: c_int) void;

extern fn gtk_box_new(orientation: c_uint, spacing: c_int) ?*anyopaque;
extern fn gtk_box_append(box: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_list_box_new() ?*anyopaque;
extern fn gtk_list_box_append(box: ?*anyopaque, child: ?*anyopaque) void;
extern fn gtk_list_box_remove(box: ?*anyopaque, child: ?*anyopaque) void;
extern fn gtk_list_box_unselect_all(box: ?*anyopaque) void;
extern fn gtk_list_box_set_sort_func(box: ?*anyopaque, sort_func: GtkListBoxSortFunc, user_data: ?*anyopaque, destroy: ?*anyopaque) void;
extern fn gtk_list_box_invalidate_sort(box: ?*anyopaque) void;
extern fn gtk_list_box_row_new() ?*anyopaque;
extern fn gtk_list_box_row_set_child(row: ?*anyopaque, child: ?*anyopaque) void;

extern fn gtk_label_new(str: ?[*:0]const u8) ?*anyopaque;
extern fn gtk_label_set_markup(label: ?*anyopaque, markup: [*:0]const u8) void;
extern fn gtk_label_set_xalign(label: ?*anyopaque, xalign: f32) void;
extern fn gtk_label_set_yalign(label: ?*anyopaque, yalign: f32) void;
extern fn gtk_label_set_selectable(label: ?*anyopaque, setting: c_int) void;
extern fn gtk_widget_set_halign(widget: ?*anyopaque, alignment: c_uint) void;
extern fn gtk_widget_set_valign(widget: ?*anyopaque, alignment: c_uint) void;
extern fn gtk_widget_set_hexpand(widget: ?*anyopaque, expand: c_int) void;
extern fn gtk_widget_set_vexpand(widget: ?*anyopaque, expand: c_int) void;
extern fn gtk_widget_set_margin_start(widget: ?*anyopaque, margin: c_int) void;
extern fn gtk_widget_set_margin_end(widget: ?*anyopaque, margin: c_int) void;
extern fn gtk_widget_set_margin_top(widget: ?*anyopaque, margin: c_int) void;
extern fn gtk_widget_set_margin_bottom(widget: ?*anyopaque, margin: c_int) void;

extern fn g_unix_fd_add(fd: c_int, condition: c_uint, function: GUnixFDSourceFunc, user_data: ?*anyopaque) c_uint;

extern fn gtk_event_controller_key_new() ?*anyopaque;
extern fn gtk_widget_add_controller(widget: ?*anyopaque, controller: ?*anyopaque) void;

// design-language constants shared with the TUI's intent (DESIGN-LANGUAGE.md)
const amber = "#ffaf00"; // fresh / first-seen "glow until greeted"
const sky = "#5fafff"; // download-leaning rate / the cursor
const tan = "#d7af87"; // upload-leaning rate
const dim = "#8a8a8a"; // grey: idle / structural

// ---- app state --------------------------------------------------------------

/// One live flow's widgets: the ListBox row and the label inside it. Updated in
/// place every tick — the anti-"rebuild the world as one string" (V1.md S2).
const Row = struct {
    row: ?*anyopaque,
    label: ?*anyopaque,
};

const App = struct {
    gpa: std.mem.Allocator,
    table: FlowTable,
    fd: std.posix.fd_t,
    upstream_fd: ?std.posix.fd_t = null, // writable socket → surveyor (null over a pipe)
    session: SessionState = .{},
    gapp: ?*anyopaque = null,
    header: ?*anyopaque = null, // summary + profile/lens + cursor lines
    listbox: ?*anyopaque = null,
    why_label: ?*anyopaque = null, // the docked narration panel
    rows: std.AutoHashMapUnmanaged(FlowKey, Row) = .empty,
    row_keys: std.AutoHashMapUnmanaged(usize, FlowKey) = .empty, // row widget ptr → key
    selected_key: ?FlowKey = null,
    suppress_select: bool = false, // guard against unselect feedback while clearing
    now_ms: i64 = 0, // surveyor's clock, from tick frames (anchors the why ages)
    frames: ipc.FrameStream,
    scratch: []u8, // markup scratch (NUL-terminated before handing to GTK)

    fn deinit(self: *App) void {
        self.rows.deinit(self.gpa);
        self.row_keys.deinit(self.gpa);
        self.table.deinit();
        self.frames.deinit();
        self.gpa.free(self.scratch);
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

    /// Apply every complete frame the stream holds; returns true if a tick landed (the
    /// same `ipc.FrameStream` the TUI and surveyor use — one read-side codec, no drift).
    fn drainFrames(self: *App) !bool {
        var ticked = false;
        while (try self.frames.next()) |frame| switch (frame) {
            .flow_upsert => |f| try self.table.apply(f),
            .flow_closed => |k| {
                self.table.remove(k);
                self.removeRow(k);
            },
            // surveyor's authoritative session (inherit-on-connect + echo, D22)
            .user_state => |us| if (self.session.apply(us)) {
                ticked = true;
            },
            .tick => |ms| {
                self.now_ms = ms;
                ticked = true;
            },
            else => {},
        };
        return ticked;
    }

    fn removeRow(self: *App, key: FlowKey) void {
        const r = self.rows.get(key) orelse return;
        _ = self.row_keys.remove(@intFromPtr(r.row));
        _ = self.rows.remove(key);
        gtk_list_box_remove(self.listbox, r.row);
    }

    /// Render markup into the scratch buffer via `f`, NUL-terminate, and hand it to a
    /// label. One scratch is safe: GTK copies the string in set_markup.
    fn setLabelMarkup(self: *App, label: ?*anyopaque, comptime f: anytype, args: anytype) void {
        var w = Writer.fixed(self.scratch[0 .. self.scratch.len - 1]);
        @call(.auto, f, .{&w} ++ args) catch {}; // truncate gracefully if it ever overflows
        const n = w.buffered().len;
        self.scratch[n] = 0;
        gtk_label_set_markup(label, @ptrCast(self.scratch.ptr));
    }

    /// The per-tick refresh: header lines, each row (created, updated, re-ranked),
    /// and the why panel — no whole-world rebuild anywhere.
    fn redraw(self: *App) void {
        const flows = self.table.snapshot(self.gpa) catch return;
        defer self.gpa.free(flows);

        self.setLabelMarkup(self.header, writeHeaderMarkup, .{ flows, self.session });

        const set = self.session.activeLenses();
        for (flows, 0..) |f, rank| {
            const gop = self.rows.getOrPut(self.gpa, f.key) catch continue;
            if (!gop.found_existing) {
                const label = gtk_label_new(null);
                gtk_label_set_xalign(label, 0);
                const row = gtk_list_box_row_new();
                gtk_list_box_row_set_child(row, label);
                gtk_list_box_append(self.listbox, row);
                gop.value_ptr.* = .{ .row = row, .label = label };
                self.row_keys.put(self.gpa, @intFromPtr(row), f.key) catch {};
            }
            self.setLabelMarkup(gop.value_ptr.label, writeRowMarkup, .{ f, set });
            // rank drives the ListBox sort (busiest first); +1 keeps 0 ≠ "no data"
            g_object_set_data(gop.value_ptr.row, "cg-rank", @ptrFromInt(rank + 1));
        }
        gtk_list_box_invalidate_sort(self.listbox);
        self.redrawWhy(flows);
    }

    /// The docked narration: the selected flow via `cartograph.why` (the same pure
    /// text the TUI panel shows), or the orbit invitation when nothing is selected.
    fn redrawWhy(self: *App, flows: []*Flow) void {
        var selected: ?*Flow = null;
        if (self.selected_key) |sk| {
            for (flows) |f| {
                if (std.meta.eql(f.key, sk)) {
                    selected = f;
                    break;
                }
            }
        }
        self.setLabelMarkup(self.why_label, writeWhyMarkup, .{ selected, self.session, self.now_ms, self.selected_key != null });
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

/// The header block: summary, profile/lens rail, cursor line, and column names.
fn writeHeaderMarkup(w: *Writer, flows: []*Flow, session: SessionState) Writer.Error!void {
    const set = session.activeLenses();
    var down_total: u64 = 0;
    var up_total: u64 = 0;
    var attributed: usize = 0;
    for (flows) |f| {
        down_total += f.rx_rate;
        up_total += f.tx_rate;
        if (f.attributed()) attributed += 1;
    }

    try w.writeAll("<span font_family=\"monospace\">");
    var dbuf: [32]u8 = undefined;
    var ubuf: [32]u8 = undefined;
    try w.print(
        "<b>▟▖ cartograph</b>  <span foreground=\"{s}\">{d} flows · {d} attributed</span>   " ++
            "<span foreground=\"{s}\">↓ {s}</span>  <span foreground=\"{s}\">↑ {s}</span>\n",
        .{ dim, flows.len, attributed, sky, cartograph.humanRate(&dbuf, down_total), tan, cartograph.humanRate(&ubuf, up_total) },
    );

    // profile + lens rail — surveyor's authoritative session, never a private cache
    // (D22); ◌ view-local scope: these controls change this window only (D23).
    const sc = cartograph.scope.Scope.view;
    try w.print(
        "<span foreground=\"{s}\">profile </span><b>{s}</b>  <span foreground=\"{s}\">{s} {s}</span>   <span foreground=\"{s}\">lens</span> ",
        .{ dim, session.profile.label(), dim, sc.glyph(), sc.label(), dim },
    );
    inline for (std.enums.values(lens.Lens), 1..) |l, n| {
        const on = set.contains(l);
        const color = if (on) sky else dim;
        const weight_open = if (on) "<b>" else "";
        const weight_close = if (on) "</b>" else "";
        try w.print("<span foreground=\"{s}\">{s}{d}:{s}{s}</span> ", .{ color, weight_open, n, l.label(), weight_close });
    }
    try w.writeAll("\n");

    // the shared cursor (D24) — the same describe() line the agent's focus event carries
    var fb: [160]u8 = undefined;
    try w.print("<span foreground=\"{s}\">⌖ ", .{sky});
    try esc(w, session.focus.describe(&fb));
    try w.writeAll("</span>\n\n");

    // column names, mirroring the row layout below
    try w.print("<span foreground=\"{s}\">  ", .{dim});
    try col(w, "APP", 15);
    try col(w, "ENDPOINT", 32);
    if (set.contains(.endpoint)) try col(w, "WHO", 24);
    if (set.contains(.volume)) {
        try col(w, "RATE", 12);
        try col(w, "TOTAL", 10);
    }
    if (set.contains(.endpoint)) try col(w, "RTT", 7);
    try w.writeAll("</span></span>");
}

/// One flow's row markup — created once, updated in place each tick.
fn writeRowMarkup(w: *Writer, f: *Flow, set: lens.Set) Writer.Error!void {
    try w.writeAll("<span font_family=\"monospace\">");
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

    // remote endpoint: the S1 name when known, the bare address otherwise
    var ebuf: [64]u8 = undefined;
    const ep = if (f.remote_name.len > 0) blk: {
        var ew = Writer.fixed(&ebuf);
        const name = f.remote_name.slice();
        ew.writeAll(name[0..@min(name.len, 25)]) catch {};
        ew.print(":{d}", .{f.key.remote_port}) catch {};
        break :blk ew.buffered();
    } else cartograph.endpoint(&ebuf, f.key.remote, f.key.remote_port);
    try span(w, cat.hex(), ep, 32);

    if (set.contains(.endpoint)) {
        var wbuf: [48]u8 = undefined;
        const who = f.whoDisplay(&wbuf);
        try span(w, dim, who[0..@min(who.len, 23)], 24);
    }

    if (set.contains(.volume)) {
        var rbuf: [16]u8 = undefined;
        var sbuf: [16]u8 = undefined;
        try span(w, rateColor(f), cartograph.humanRate(&rbuf, f.throughput()), 12);
        try span(w, dim, cartograph.humanBytes(&sbuf, f.rx_bytes + f.tx_bytes), 10);
    }

    if (set.contains(.endpoint)) {
        var ttbuf: [16]u8 = undefined;
        const rtt = if (f.rtt_us == 0) "·" else std.fmt.bufPrint(&ttbuf, "{d:.0}ms", .{@as(f64, @floatFromInt(f.rtt_us)) / 1000.0}) catch "·";
        try span(w, dim, rtt, 7);
    }
    try w.writeAll("</span>");
}

/// The Why panel: headline + the `cartograph.why` narration, or the orbit hint.
fn writeWhyMarkup(w: *Writer, selected: ?*Flow, session: SessionState, now_ms: i64, has_selection: bool) Writer.Error!void {
    try w.writeAll("<span font_family=\"monospace\">");
    var fb: [160]u8 = undefined;
    try w.print("<span foreground=\"{s}\">⌖ ", .{sky});
    try esc(w, session.focus.describe(&fb));
    try w.writeAll("</span>\n\n");

    if (selected) |f| {
        try w.writeAll("<b>");
        var hb: [256]u8 = undefined;
        var hw = Writer.fixed(&hb);
        cartograph.why.headline(&hw, f) catch {};
        try esc(w, hw.buffered());
        try w.writeAll("</b>\n\n");

        var db: [2048]u8 = undefined;
        var dw = Writer.fixed(&db);
        // the tick clock anchors ages; before the first tick, the flow's own clock does
        cartograph.why.describe(&dw, f, @max(now_ms, f.last_seen_ms)) catch {};
        try esc(w, dw.buffered());
    } else if (has_selection) {
        try w.print("<span foreground=\"{s}\">that conversation has ended</span>", .{dim});
    } else {
        try w.print("<span foreground=\"{s}\">click a flow (or ↑/↓) to ask why it exists</span>", .{dim});
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
        app.frames.push(rbuf[0..rc]) catch return G_SOURCE_CONTINUE;
    }

    if (app.drainFrames() catch false) app.redraw();
    return G_SOURCE_CONTINUE;
}

/// The ListBox sort: by the rank `redraw` stamped on each row (busiest first).
fn onSortRows(row1: ?*anyopaque, row2: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const r1 = @intFromPtr(g_object_get_data(row1, "cg-rank"));
    const r2 = @intFromPtr(g_object_get_data(row2, "cg-rank"));
    return @as(c_int, @intCast(@as(i64, @intCast(r1)) - @as(i64, @intCast(r2))));
}

/// Selection → the shared cursor (D24): a row is a flow, so selecting it descends the
/// focus to street altitude on that flow; clearing returns to orbit. Both travel
/// upstream as `user_state{focus}` so surveyor + any watching agent follow along.
fn onRowSelected(_: ?*anyopaque, row: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    if (app.suppress_select) return;

    if (row) |r| {
        const key = app.row_keys.get(@intFromPtr(r)) orelse return;
        app.selected_key = key;
        const f = cartograph.Focus{ .altitude = .street, .target = .{ .flow = key } };
        app.session.setFocus(f);
        app.sendUpstream(.{ .focus = f });
    } else {
        app.selected_key = null;
        app.session.setFocus(.{});
        app.sendUpstream(.{ .focus = .{} });
    }
    app.redraw();
}

/// Keyboard: "p" cycles the profile, "1–6" toggle lenses, Escape clears the selection
/// (back to orbit). Arrows/clicks are the ListBox's own navigation — its row-selected
/// signal lands in `onRowSelected` above.
fn onKeyPressed(_: ?*anyopaque, keyval: c_uint, _: c_uint, _: c_uint, user_data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const lens_keys = std.enums.values(lens.Lens);
    const GDK_KEY_Escape: c_uint = 0xff1b;

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
        GDK_KEY_Escape => {
            gtk_list_box_unselect_all(app.listbox); // fires onRowSelected(null) → orbit
            return 1;
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
    gtk_window_set_default_size(window, 1280, 720);

    // a key controller on the window catches "p" / "1–6" / Escape anywhere
    const keys = gtk_event_controller_key_new();
    _ = g_signal_connect_data(keys, "key-pressed", @ptrCast(@as(GtkKeyPressed, onKeyPressed)), app, null, 0);
    gtk_widget_add_controller(window, keys);

    // left: header + the live flow list
    const header = gtk_label_new(null);
    gtk_label_set_xalign(header, 0);
    gtk_widget_set_margin_start(header, 10);
    gtk_widget_set_margin_top(header, 8);
    app.header = header;

    const listbox = gtk_list_box_new();
    gtk_list_box_set_sort_func(listbox, onSortRows, app, null);
    _ = g_signal_connect_data(listbox, "row-selected", @ptrCast(@as(GtkRowSelected, onRowSelected)), app, null, 0);
    app.listbox = listbox;

    const scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(scroller, listbox);
    gtk_widget_set_vexpand(scroller, 1);

    const left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(left, header);
    gtk_box_append(left, scroller);

    // right: the docked Why panel
    const why_label = gtk_label_new(null);
    gtk_label_set_xalign(why_label, 0);
    gtk_label_set_yalign(why_label, 0);
    gtk_label_set_selectable(why_label, 1); // it's data — let the user copy it
    gtk_widget_set_margin_start(why_label, 12);
    gtk_widget_set_margin_end(why_label, 12);
    gtk_widget_set_margin_top(why_label, 8);
    gtk_widget_set_valign(why_label, GTK_ALIGN_START);
    app.why_label = why_label;

    const why_scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(why_scroller, why_label);

    const paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_start_child(paned, left);
    gtk_paned_set_end_child(paned, why_scroller);
    gtk_paned_set_position(paned, 780);
    gtk_window_set_child(window, paned);

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
        .frames = ipc.FrameStream.init(gpa),
        .scratch = try gpa.alloc(u8, 512 * 1024),
    };
    defer app.deinit();

    const gapp = gtk_application_new("org.cartograph.Gtk", G_APPLICATION_NON_UNIQUE);
    defer g_object_unref(gapp);
    app.gapp = gapp;

    _ = g_signal_connect_data(gapp, "activate", @ptrCast(@as(GtkApplicationActivate, onActivate)), &app, null, 0);
    const status = g_application_run(gapp, 0, null);
    if (status != 0) return error.GtkRunFailed;
}
