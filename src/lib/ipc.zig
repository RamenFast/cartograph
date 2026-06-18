//! The lean binary IPC between surveyor (capture) and any frontend.
//!
//! Wire format (ARCHITECTURE.md): length-prefixed frames, little-endian, no JSON,
//! no HTTP. One frame is:
//!
//!     [u32 len][u8 type][payload(len-1 bytes)]
//!
//! `len` counts the type byte plus payload, so a reader can frame and skip
//! unknown types without understanding them — forward-compatible by construction.
//! The same codec runs over a pipe today and a Unix socket tomorrow; transport is
//! just a byte stream.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const flow = @import("flow.zig");
const Flow = flow.Flow;
const FlowKey = flow.FlowKey;

pub const protocol_version: u16 = 1;

/// Upper bound on a single encoded frame, so readers can size their buffer.
pub const max_frame = 1024;

pub const FrameType = enum(u8) {
    hello = 1,
    flow_upsert = 2,
    flow_closed = 3,
    tick = 4,
    bye = 5,
    _,
};

pub const Frame = union(enum) {
    hello: u16, // protocol version
    flow_upsert: Flow,
    flow_closed: FlowKey,
    tick: i64, // ms timestamp at end of a batch
    bye,
    unknown: u8, // an unrecognised frame type we skipped over
};

// ---- low-level field helpers ------------------------------------------------

fn writeKey(w: *Writer, key: FlowKey) Writer.Error!void {
    try w.writeByte(@intFromEnum(key.proto));
    try w.writeByte(@intFromBool(key.local.is_v6));
    try w.writeAll(&key.local.bytes);
    try w.writeInt(u16, key.local_port, .little);
    try w.writeAll(&key.remote.bytes);
    try w.writeInt(u16, key.remote_port, .little);
}

fn readKey(r: *Reader) !FlowKey {
    const proto: flow.Proto = @enumFromInt(try r.takeByte());
    const is_v6 = (try r.takeByte()) != 0;
    var local: flow.Addr = .{ .is_v6 = is_v6 };
    local.bytes = (try r.takeArray(16)).*;
    const local_port = try r.takeInt(u16, .little);
    var remote: flow.Addr = .{ .is_v6 = is_v6 };
    remote.bytes = (try r.takeArray(16)).*;
    const remote_port = try r.takeInt(u16, .little);
    return .{ .proto = proto, .local = local, .local_port = local_port, .remote = remote, .remote_port = remote_port };
}

fn writeFlow(w: *Writer, f: Flow) Writer.Error!void {
    try writeKey(w, f.key);
    try w.writeByte(@intFromEnum(f.state));
    try w.writeByte(@intFromEnum(f.category));
    try w.writeInt(u32, f.pid, .little);
    try w.writeInt(u32, f.uid, .little);
    try w.writeInt(u64, f.inode, .little);
    try w.writeInt(u64, f.rx_bytes, .little);
    try w.writeInt(u64, f.tx_bytes, .little);
    try w.writeInt(u32, f.rx_rate, .little);
    try w.writeInt(u32, f.tx_rate, .little);
    try w.writeInt(u32, f.rtt_us, .little);
    try w.writeInt(i64, f.first_seen_ms, .little);
    try w.writeInt(i64, f.last_seen_ms, .little);
    try w.writeByte(@intFromBool(f.fresh));
    try w.writeByte(f.comm.len);
    try w.writeAll(f.comm.slice());
    try w.writeInt(u16, f.exe.len, .little);
    try w.writeAll(f.exe.slice());
}

fn readFlow(r: *Reader) !Flow {
    var f: Flow = .{ .key = try readKey(r) };
    f.state = @enumFromInt(try r.takeByte());
    f.category = @enumFromInt(try r.takeByte());
    f.pid = try r.takeInt(u32, .little);
    f.uid = try r.takeInt(u32, .little);
    f.inode = try r.takeInt(u64, .little);
    f.rx_bytes = try r.takeInt(u64, .little);
    f.tx_bytes = try r.takeInt(u64, .little);
    f.rx_rate = try r.takeInt(u32, .little);
    f.tx_rate = try r.takeInt(u32, .little);
    f.rtt_us = try r.takeInt(u32, .little);
    f.first_seen_ms = try r.takeInt(i64, .little);
    f.last_seen_ms = try r.takeInt(i64, .little);
    f.fresh = (try r.takeByte()) != 0;
    const comm_len = try r.takeByte();
    f.comm.set(try r.take(comm_len));
    const exe_len = try r.takeInt(u16, .little);
    f.exe.set(try r.take(exe_len));
    return f;
}

// ---- frame send -------------------------------------------------------------

fn sendFrame(w: *Writer, ftype: FrameType, payload: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(payload.len + 1), .little);
    try w.writeByte(@intFromEnum(ftype));
    try w.writeAll(payload);
}

pub fn sendHello(w: *Writer) Writer.Error!void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, protocol_version, .little);
    try sendFrame(w, .hello, &buf);
}

pub fn sendFlowUpsert(w: *Writer, f: Flow) Writer.Error!void {
    var buf: [max_frame]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeFlow(&pw, f);
    try sendFrame(w, .flow_upsert, pw.buffered());
}

pub fn sendFlowClosed(w: *Writer, key: FlowKey) Writer.Error!void {
    var buf: [64]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeKey(&pw, key);
    try sendFrame(w, .flow_closed, pw.buffered());
}

pub fn sendTick(w: *Writer, ms: i64) Writer.Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, ms, .little);
    try sendFrame(w, .tick, &buf);
}

pub fn sendBye(w: *Writer) Writer.Error!void {
    try sendFrame(w, .bye, &.{});
}

// ---- frame read -------------------------------------------------------------

/// Read one frame. Returns `null` on a clean end-of-stream (no partial frame).
/// The reader's buffer must be at least `max_frame` bytes.
pub fn readFrame(r: *Reader) !?Frame {
    const len = r.takeInt(u32, .little) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    if (len == 0) return error.InvalidFrame;
    const body = try r.take(len); // bounded by max_frame via the reader buffer
    const ftype: FrameType = @enumFromInt(body[0]);
    var pr = Reader.fixed(body[1..]);
    return switch (ftype) {
        .hello => .{ .hello = try pr.takeInt(u16, .little) },
        .flow_upsert => .{ .flow_upsert = try readFlow(&pr) },
        .flow_closed => .{ .flow_closed = try readKey(&pr) },
        .tick => .{ .tick = try pr.takeInt(i64, .little) },
        .bye => .bye,
        _ => .{ .unknown = body[0] },
    };
}

// ---- tests ------------------------------------------------------------------

test "flow round-trips through a frame" {
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
    f.uid = 1000;
    f.inode = 123456;
    f.rx_bytes = 410_000;
    f.tx_bytes = 38_000;
    f.rx_rate = 9000;
    f.tx_rate = 1200;
    f.first_seen_ms = 1_700_000_000_000;
    f.last_seen_ms = 1_700_000_372_000;
    f.fresh = true;
    f.comm.set("claude");
    f.exe.set("/usr/lib/claude/claude");

    var buf: [max_frame]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendFlowUpsert(&w, f);

    var r = Reader.fixed(w.buffered());
    const frame = (try readFrame(&r)).?;
    try t.expect(frame == .flow_upsert);
    const g = frame.flow_upsert;
    try t.expectEqual(f.pid, g.pid);
    try t.expectEqual(f.rx_bytes, g.rx_bytes);
    try t.expectEqual(f.category, g.category);
    try t.expectEqual(f.key.remote_port, g.key.remote_port);
    try t.expectEqualStrings("claude", g.comm.slice());
    try t.expectEqualStrings("/usr/lib/claude/claude", g.exe.slice());
    try t.expectEqual(f.key.remote.bytes, g.key.remote.bytes);
    try t.expect(g.fresh);
}

test "hello, tick, closed, and clean EOF" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendHello(&w);
    try sendTick(&w, 42);
    try sendFlowClosed(&w, .{
        .proto = .udp,
        .local = flow.Addr.v4(.{ 0, 0, 0, 0 }),
        .local_port = 53,
        .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }),
        .remote_port = 53,
    });

    var r = Reader.fixed(w.buffered());
    try t.expectEqual(@as(u16, protocol_version), (try readFrame(&r)).?.hello);
    try t.expectEqual(@as(i64, 42), (try readFrame(&r)).?.tick);
    try t.expect((try readFrame(&r)).? == .flow_closed);
    try t.expectEqual(@as(?Frame, null), try readFrame(&r)); // clean EOF
}
