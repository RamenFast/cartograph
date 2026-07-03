//! The "Why" narration — click any flow and be told, in plain terms, what it is and
//! why it exists (the V1 loop's second half; docs/V1.md S2).
//!
//! A pure function over `Flow`: no capture, no allocation, no renderer knowledge —
//! the GTK panel, the TUI footer, and (later) the agent's postcard all narrate from
//! this one source, so the story can never differ between windows (parity, D9/R5).

const std = @import("std");
const Writer = std.Io.Writer;

const flow = @import("flow.zig");
const identity = @import("identity.zig");
const fmtutil = @import("fmt.zig");
const Flow = flow.Flow;

/// Human duration: "just now", "42s", "7m", "3h", "2d". Writes into `buf`.
pub fn age(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(ms, 1000);
    if (s < 5) return "just now";
    var w = Writer.fixed(buf);
    if (s < 90) {
        w.print("{d}s ago", .{s}) catch {};
    } else if (s < 90 * 60) {
        w.print("{d}m ago", .{@divTrunc(s, 60)}) catch {};
    } else if (s < 36 * 60 * 60) {
        w.print("{d}h ago", .{@divTrunc(s, 60 * 60)}) catch {};
    } else {
        w.print("{d}d ago", .{@divTrunc(s, 24 * 60 * 60)}) catch {};
    }
    return w.buffered();
}

/// The one-line "what am I looking at" — the same line the focus header shows for a
/// street-altitude cursor, grown identity: `chrome → api.anthropic.com (Anthropic, PBC · US) · https`.
pub fn headline(w: *Writer, f: *const Flow) Writer.Error!void {
    var nbuf: [64]u8 = undefined;
    try w.print("{s} → {s}", .{ f.name(), f.remoteDisplay(&nbuf) });
    var wbuf: [96]u8 = undefined;
    const who = f.whoDisplay(&wbuf);
    if (who.len > 1) try w.print(" ({s})", .{who});
    if (f.service() != .unknown) try w.print(" · {s}", .{f.service().label()});
}

/// The full narration, one `label: value` line at a time. `now_ms` anchors the ages.
/// Lines are plain text; renderers add their own colour/markup around each line.
pub fn describe(w: *Writer, f: *const Flow, now_ms: i64) Writer.Error!void {
    var buf: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;

    // who, on this machine
    if (f.attributed()) {
        try w.print("process    {s} (pid {d}, uid {d})\n", .{ f.name(), f.pid, f.uid });
        if (f.exe.len > 0) try w.print("exe        {s}\n", .{f.exe.slice()});
        if (f.ppid != 0) {
            if (f.pcomm.len > 0) {
                try w.print("launched by {s} (pid {d})\n", .{ f.pcomm.slice(), f.ppid });
            } else {
                try w.print("launched by pid {d}\n", .{f.ppid});
            }
        }
    } else if (f.isUnattributedDaemon()) {
        try w.print("process    unattributed — but the port says {s} (a known daemon; root/other-user)\n", .{f.service().label()});
    } else {
        try w.writeAll("process    unattributed (kernel, another user, or gone before we looked)\n");
    }

    // who, out there
    if (f.remote_name.len > 0) try w.print("remote     {s}\n", .{f.remote_name.slice()});
    var lb: [64]u8 = undefined;
    var rb: [64]u8 = undefined;
    var lw = Writer.fixed(&lb);
    var rw = Writer.fixed(&rb);
    writeEndpoint(&lw, f.key.local, f.key.local_port) catch {};
    writeEndpoint(&rw, f.key.remote, f.key.remote_port) catch {};
    try w.print("address    {s} → {s} ({s})\n", .{ lw.buffered(), rw.buffered(), f.key.proto.label() });
    const who = f.whoDisplay(&buf);
    if (who.len > 1) {
        try w.print("owner      {s}", .{who});
        if (f.asn != 0) try w.print(" (AS{d})", .{f.asn});
        try w.writeAll("\n");
    }

    // what kind of conversation
    try w.print("speaking   {s}", .{if (f.service() != .unknown) f.service().label() else "an unrecognised protocol"});
    try w.print(" · {s} · {s}\n", .{ f.category.label(), f.state.label() });
    if (f.isListen()) {
        try w.print("exposure   {s} — {s}\n", .{ f.exposure().label(), exposureNote(f.exposure()) });
    }

    // how much, how fast
    var t1: [16]u8 = undefined;
    var t2: [16]u8 = undefined;
    try w.print("traffic    ↓ {s} · ↑ {s}", .{
        humanBytes(&buf, f.rx_bytes),
        humanBytes(&buf2, f.tx_bytes),
    });
    if (f.throughput() > 0) {
        try w.print(" (now ↓{s} ↑{s})", .{ humanRate(&t1, f.rx_rate), humanRate(&t2, f.tx_rate) });
    }
    try w.writeAll("\n");
    if (f.rtt_us != 0) {
        try w.print("latency    {d:.1} ms round-trip\n", .{@as(f64, @floatFromInt(f.rtt_us)) / 1000.0});
    }

    // when
    try w.print("seen       first {s} · last {s}", .{
        age(&buf, now_ms - f.first_seen_ms),
        age(&buf2, now_ms - f.last_seen_ms),
    });
    if (f.fresh) try w.writeAll(" · NEW");
    try w.writeAll("\n");
}

fn exposureNote(e: identity.Exposure) []const u8 {
    return switch (e) {
        .none => "not a listener",
        .loopback => "listening, but only this machine can reach it",
        .network => "reachable from your local network",
        .internet => "reachable from the internet",
    };
}

const writeEndpoint = fmtutil.writeEndpoint;
const humanBytes = fmtutil.humanBytes;
const humanRate = fmtutil.humanRate;

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

fn narrate(f: *const Flow, buf: []u8) []const u8 {
    var w = Writer.fixed(buf);
    describe(&w, f, 1_700_000_100_000) catch {};
    return w.buffered();
}

test "an attributed, enriched flow narrates process, lineage, owner, and traffic" {
    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 49220,
        .remote = flow.Addr.v4(.{ 160, 79, 104, 10 }),
        .remote_port = 443,
    } };
    f.state = .established;
    f.category = .web;
    f.pid = 1234;
    f.uid = 1000;
    f.comm.set("claude");
    f.exe.set("/usr/bin/claude");
    f.ppid = 900;
    f.pcomm.set("zsh");
    f.remote_name.set("api.anthropic.com");
    f.asn = 399358;
    f.as_org.set("Anthropic, PBC");
    f.country = .{ 'U', 'S' };
    f.rx_bytes = 494_377;
    f.tx_bytes = 193_100_185;
    f.rtt_us = 27_368;
    f.first_seen_ms = 1_700_000_000_000;
    f.last_seen_ms = 1_700_000_099_000;

    var buf: [2048]u8 = undefined;
    const out = narrate(&f, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "claude (pid 1234") != null);
    try testing.expect(std.mem.indexOf(u8, out, "launched by zsh (pid 900)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "api.anthropic.com") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Anthropic, PBC · US (AS399358)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https") != null);
    try testing.expect(std.mem.indexOf(u8, out, "27.4 ms") != null);
    try testing.expect(std.mem.indexOf(u8, out, "184.2 MB") != null); // tx
    try testing.expect(std.mem.indexOf(u8, out, "first 1m ago") != null); // 100s rounds to minutes past the 90s cutoff

    // and the headline reads as one line of plain language
    var hb: [256]u8 = undefined;
    var hw = Writer.fixed(&hb);
    try headline(&hw, &f);
    try testing.expectEqualStrings("claude → api.anthropic.com (Anthropic, PBC · US) · https", hw.buffered());
}

test "an unattributed daemon flow stays legible in the narration (the ? answer)" {
    var f: Flow = .{ .key = .{
        .proto = .udp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 40000,
        .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }),
        .remote_port = 53,
    } };
    f.state = .established;
    var buf: [2048]u8 = undefined;
    const out = narrate(&f, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "unattributed — but the port says dns") != null);
}

test "a listener narrates its exposure in plain words" {
    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 0, 0, 0, 0 }),
        .local_port = 631,
        .remote = flow.Addr.v4(.{ 0, 0, 0, 0 }),
        .remote_port = 0,
    } };
    f.state = .listen;
    f.pid = 77;
    f.comm.set("cupsd");
    var buf: [2048]u8 = undefined;
    const out = narrate(&f, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "reachable from your local network") != null);
}

test "age humanizes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("just now", age(&buf, 3000));
    try testing.expectEqualStrings("42s ago", age(&buf, 42_000));
    try testing.expectEqualStrings("7m ago", age(&buf, 7 * 60_000));
    try testing.expectEqualStrings("3h ago", age(&buf, 3 * 3_600_000));
    try testing.expectEqualStrings("2d ago", age(&buf, 48 * 3_600_000));
}
