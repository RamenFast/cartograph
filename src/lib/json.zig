//! NDJSON projection of the view-model — the agent/script surface.
//!
//! A real Unix program speaks plain text any tool (or any AI, or any kid with `jq`)
//! can parse. This emits one flow as one JSON object on one line — line-oriented,
//! streamable, greppable, stable field names. It is *another renderer over the same
//! `Flow`*, so the agent surface can never drift from what the TUI shows (parity).
//!
//! Schema contract: see docs/AGENT-INTERFACE.md. Field names are stable; numbers are
//! numbers; `pid: 0` means unattributed (kernel/other-user); addresses are bare
//! strings with the port as a separate number.

const std = @import("std");
const Writer = std.Io.Writer;
const flow = @import("flow.zig");
const Flow = flow.Flow;

/// Write one flow as a single NDJSON line (no trailing newline; caller adds it).
pub fn writeFlow(w: *Writer, f: *const Flow) Writer.Error!void {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    try w.writeByte('{');
    try field(w, "proto", false);
    try str(w, f.key.proto.label());
    try field(w, "state", true);
    try str(w, f.state.label());
    try field(w, "category", true);
    try str(w, f.category.label());
    try field(w, "pid", true);
    try w.print("{d}", .{f.pid});
    try field(w, "uid", true);
    try w.print("{d}", .{f.uid});
    try field(w, "comm", true);
    try str(w, f.comm.slice());
    try field(w, "exe", true);
    try str(w, f.exe.slice());
    try field(w, "local", true);
    try str(w, f.key.local.fmt(&ab));
    try field(w, "local_port", true);
    try w.print("{d}", .{f.key.local_port});
    try field(w, "remote", true);
    try str(w, f.key.remote.fmt(&bb));
    try field(w, "remote_port", true);
    try w.print("{d}", .{f.key.remote_port});
    try field(w, "rx_bytes", true);
    try w.print("{d}", .{f.rx_bytes});
    try field(w, "tx_bytes", true);
    try w.print("{d}", .{f.tx_bytes});
    try field(w, "rx_rate", true);
    try w.print("{d}", .{f.rx_rate});
    try field(w, "tx_rate", true);
    try w.print("{d}", .{f.tx_rate});
    try field(w, "rtt_us", true);
    try w.print("{d}", .{f.rtt_us});
    try field(w, "fresh", true);
    try w.writeAll(if (f.fresh) "true" else "false");
    try field(w, "first_seen_ms", true);
    try w.print("{d}", .{f.first_seen_ms});
    try field(w, "last_seen_ms", true);
    try w.print("{d}", .{f.last_seen_ms});
    try w.writeByte('}');
}

fn field(w: *Writer, name: []const u8, comma: bool) Writer.Error!void {
    if (comma) try w.writeByte(',');
    try str(w, name);
    try w.writeByte(':');
}

/// Write a JSON string literal with correct escaping.
fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...7, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "flow emits valid, parseable json" {
    const t = std.testing;
    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 44330,
        .remote = flow.Addr.v4(.{ 160, 79, 104, 10 }),
        .remote_port = 443,
    } };
    f.state = .established;
    f.category = .web;
    f.pid = 81777;
    f.comm.set("clau\"de\n"); // force escaping
    f.exe.set("/usr/lib/x");
    f.rx_bytes = 410_000;
    f.rtt_us = 24_200;

    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeFlow(&w, &f);
    const out = w.buffered();

    // Parses as JSON, and key fields survive.
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try t.expectEqualStrings("tcp", obj.get("proto").?.string);
    try t.expectEqualStrings("clau\"de\n", obj.get("comm").?.string);
    try t.expectEqual(@as(i64, 81777), obj.get("pid").?.integer);
    try t.expectEqual(@as(i64, 410_000), obj.get("rx_bytes").?.integer);
    try t.expectEqualStrings("160.79.104.10", obj.get("remote").?.string);
    try t.expectEqual(@as(i64, 443), obj.get("remote_port").?.integer);
}
