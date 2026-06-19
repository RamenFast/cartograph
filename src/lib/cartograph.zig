//! libcartograph — the frontend-agnostic view-model.
//!
//! This module is the single place where Cartograph's features live: the flow
//! model, the live flow table, the binary IPC codec, category/identity inference,
//! and the lens system. The capture core (`surveyor`) and every frontend (TUI,
//! GTK, …) link this module, so a capability can never exist in one UI but not
//! another — parity by construction (FRONTENDS.md, DECISIONS.md D9).

const std = @import("std");

pub const flow = @import("flow.zig");
pub const identity = @import("identity.zig");
pub const sparkline = @import("sparkline.zig");
pub const ipc = @import("ipc.zig");
pub const table = @import("table.zig");
pub const lens = @import("lens.zig");
pub const json = @import("json.zig");
pub const ontology = @import("ontology.zig");
pub const session = @import("session.zig");
pub const scope = @import("scope.zig");
pub const usock = @import("usock.zig");
pub const parity = @import("parity.zig");

// Convenience re-exports of the most-used types.
pub const Proto = flow.Proto;
pub const TcpState = flow.TcpState;
pub const Addr = flow.Addr;
pub const FlowKey = flow.FlowKey;
pub const Flow = flow.Flow;
pub const Category = identity.Category;
pub const FlowTable = table.FlowTable;
pub const Observation = table.Observation;
pub const SessionState = session.SessionState;

/// Write `addr:port`, bracketing IPv6 the conventional way: `[2a04::1]:443`.
pub fn writeEndpoint(w: *std.Io.Writer, addr: Addr, port: u16) std.Io.Writer.Error!void {
    if (addr.is_v6) {
        try w.writeByte('[');
        try addr.write(w);
        try w.print("]:{d}", .{port});
    } else {
        try addr.write(w);
        try w.print(":{d}", .{port});
    }
}

/// Format `addr:port` into `buf` and return the slice.
pub fn endpoint(buf: []u8, addr: Addr, port: u16) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeEndpoint(&w, addr, port) catch {};
    return w.buffered();
}

/// Human-friendly byte formatting (e.g. "1.4 MB"). Writes into `buf`.
pub fn humanBytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    var w = std.Io.Writer.fixed(buf);
    if (i == 0) {
        w.print("{d} {s}", .{ n, units[i] }) catch {};
    } else {
        w.print("{d:.1} {s}", .{ v, units[i] }) catch {};
    }
    return w.buffered();
}

/// Throughput formatting (e.g. "1.4 MB/s"). Writes into `buf`.
pub fn humanRate(buf: []u8, bytes_per_sec: u64) []const u8 {
    if (bytes_per_sec == 0) return "·";
    var tmp: [32]u8 = undefined;
    const b = humanBytes(&tmp, bytes_per_sec);
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}/s", .{b}) catch {};
    return w.buffered();
}

test {
    // Pull every submodule's tests into `zig build test`.
    std.testing.refAllDecls(@This());
}

test "humanBytes" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("512 B", humanBytes(&buf, 512));
    try t.expectEqualStrings("1.0 KB", humanBytes(&buf, 1024));
    try t.expectEqualStrings("1.4 MB", humanBytes(&buf, 1_468_006));
}
