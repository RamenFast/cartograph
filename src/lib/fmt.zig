//! Shared human-formatting helpers — bytes, rates, endpoints. A leaf module so both
//! the root (`cartograph.humanBytes` re-exports) and other leaves (why.zig) can use
//! them without an import cycle.

const std = @import("std");
const Writer = std.Io.Writer;
const flow = @import("flow.zig");

/// Write `addr:port`, bracketing IPv6 the conventional way: `[2a04::1]:443`.
pub fn writeEndpoint(w: *Writer, addr: flow.Addr, port: u16) Writer.Error!void {
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
pub fn endpoint(buf: []u8, addr: flow.Addr, port: u16) []const u8 {
    var w = Writer.fixed(buf);
    writeEndpoint(&w, addr, port) catch {};
    return w.buffered();
}

/// Human-friendly byte formatting (e.g. "1.4 MB"). Writes into `buf`.
pub fn humanBytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    var w = Writer.fixed(buf);
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
    var w = Writer.fixed(buf);
    w.print("{s}/s", .{b}) catch {};
    return w.buffered();
}

test "humanBytes" {
    const t = std.testing;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("512 B", humanBytes(&buf, 512));
    try t.expectEqualStrings("1.0 KB", humanBytes(&buf, 1024));
    try t.expectEqualStrings("1.4 MB", humanBytes(&buf, 1_468_006));
}
