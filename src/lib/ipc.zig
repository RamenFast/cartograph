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
const lens = @import("lens.zig");
const ontology = @import("ontology.zig");
const focusmod = @import("focus.zig");
const Flow = flow.Flow;
const FlowKey = flow.FlowKey;

/// Bumped to 2 in M2: the act-ontology frames (user_state/rule/reading/ruling) are
/// defined. They were added **additively** — a v1 reader skips them as unknown frames
/// (FrameType is non-exhaustive), so the bump is informative, not a break.
/// Bumped to 3 in V1/S1: `flow_upsert` grew the remote-identity fields (remote_name/
/// asn/as_org/country), appended as **trailing fields** — a v3 reader decodes their
/// absence from a v2 frame as the zero values, so this bump is informative too.
pub const protocol_version: u16 = 3;

/// Upper bound on a single encoded frame, so readers can size their buffer.
pub const max_frame = 1024;

pub const FrameType = enum(u8) {
    hello = 1,
    flow_upsert = 2,
    flow_closed = 3,
    tick = 4,
    bye = 5,
    // --- act ontology (D19/ONTOLOGY.md) — reserved + defined in M2, thin payloads ---
    user_state = 6, // profile switch / lens toggle / greeting write (the parity frame)
    rule = 7, // a Rule create/update (bidirectional)
    reading = 8, // a new Reading (observation only)
    ruling = 9, // a new Ruling (the renderer shows the severed link, D14)
    _,
};

pub const Frame = union(enum) {
    hello: u16, // protocol version
    flow_upsert: Flow,
    flow_closed: FlowKey,
    tick: i64, // ms timestamp at end of a batch
    bye,
    user_state: ontology.UserState,
    rule: ontology.Rule,
    reading: ontology.Reading,
    ruling: ontology.Ruling,
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
    // v3 trailing identity (S1) — appended, never reordered (the additivity contract)
    try w.writeByte(f.remote_name.len);
    try w.writeAll(f.remote_name.slice());
    try w.writeInt(u32, f.asn, .little);
    try w.writeByte(f.as_org.len);
    try w.writeAll(f.as_org.slice());
    try w.writeAll(&f.country);
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
    // v3 trailing identity — absent from a v2 frame, in which case the payload ends
    // exactly here and the fields keep their zero defaults (additive, not a break).
    const name_len = r.takeByte() catch |err| switch (err) {
        error.EndOfStream => return f,
        else => |e| return e,
    };
    f.remote_name.set(try r.take(name_len));
    f.asn = try r.takeInt(u32, .little);
    const org_len = try r.takeByte();
    f.as_org.set(try r.take(org_len));
    f.country = (try r.takeArray(2)).*;
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

// ---- act-ontology frames (D19/D20, ONTOLOGY.md) -----------------------------
// All wire code for the ontology lives here, not in ontology.zig, so the import
// stays one-way (ipc → ontology) with no cycle. Payloads are thin in M2 and grow
// additively as M3/M6/M8 flesh the types out.

fn writeStr(w: *Writer, s: anytype) Writer.Error!void {
    try w.writeByte(s.len); // Str(N) caps N at 255, so the length always fits a byte
    try w.writeAll(s.slice());
}

fn readStr(r: *Reader, comptime N: usize) !flow.Str(N) {
    const n = try r.takeByte();
    var s: flow.Str(N) = .{};
    s.set(try r.take(n));
    return s;
}

fn writeEntityKey(w: *Writer, ek: ontology.EntityKey) Writer.Error!void {
    try w.writeByte(@intFromEnum(std.meta.activeTag(ek)));
    switch (ek) {
        .host => |a| {
            try w.writeByte(@intFromBool(a.is_v6));
            try w.writeAll(&a.bytes);
        },
        .app => |s| try writeStr(w, s),
        .asn => |n| try w.writeInt(u32, n, .little),
    }
}

fn readEntityKey(r: *Reader) !ontology.EntityKey {
    return switch (try r.takeByte()) {
        0 => blk: {
            const is_v6 = (try r.takeByte()) != 0;
            var a: flow.Addr = .{ .is_v6 = is_v6 };
            a.bytes = (try r.takeArray(16)).*;
            break :blk .{ .host = a };
        },
        1 => .{ .app = try readStr(r, 64) },
        2 => .{ .asn = try r.takeInt(u32, .little) },
        else => error.InvalidFrame,
    };
}

/// Lens sets travel as a bitmask (≤8 lenses today). Stable across renderers because
/// it's derived from the enum's own tag values, both ends.
fn lensSetByte(s: lens.Set) u8 {
    var b: u8 = 0;
    inline for (std.enums.values(lens.Lens)) |l| {
        if (s.contains(l)) b |= @as(u8, 1) << @as(u3, @intCast(@intFromEnum(l)));
    }
    return b;
}

fn lensSetFromByte(b: u8) lens.Set {
    var s = lens.Set.initEmpty();
    inline for (std.enums.values(lens.Lens)) |l| {
        if (b & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(l)))) != 0) s.insert(l);
    }
    return s;
}

fn writeGreeting(w: *Writer, g: ontology.Greeting) Writer.Error!void {
    try writeEntityKey(w, g.key);
    try writeStr(w, g.label);
    try w.writeByte(@intFromEnum(g.state));
    try writeStr(w, g.note);
    try w.writeInt(i64, g.first_seen_ms, .little);
    try w.writeInt(i64, g.last_seen_ms, .little);
    try w.writeInt(i64, g.greeted_ms, .little);
}

fn readGreeting(r: *Reader) !ontology.Greeting {
    const key = try readEntityKey(r);
    const label = try readStr(r, 64);
    const state: ontology.GreetState = @enumFromInt(try r.takeByte());
    const note = try readStr(r, 255);
    const first = try r.takeInt(i64, .little);
    const last = try r.takeInt(i64, .little);
    const greeted = try r.takeInt(i64, .little);
    return .{ .key = key, .label = label, .state = state, .note = note, .first_seen_ms = first, .last_seen_ms = last, .greeted_ms = greeted };
}

fn writeRule(w: *Writer, ru: ontology.Rule) Writer.Error!void {
    try w.writeInt(u64, ru.id, .little);
    try w.writeByte(@intFromEnum(ru.verdict));
    try writeEntityKey(w, ru.target);
    try w.writeInt(u32, ru.rate_bps, .little);
    try w.writeInt(i64, ru.created_ms, .little);
    try w.writeInt(i64, ru.expires_ms, .little);
    try w.writeByte(@intFromEnum(ru.source));
    try w.writeByte(@intFromBool(ru.visible));
}

fn readRule(r: *Reader) !ontology.Rule {
    const id = try r.takeInt(u64, .little);
    const verdict: ontology.Verdict = @enumFromInt(try r.takeByte());
    const target = try readEntityKey(r);
    const rate = try r.takeInt(u32, .little);
    const created = try r.takeInt(i64, .little);
    const expires = try r.takeInt(i64, .little);
    const source: ontology.RuleSource = @enumFromInt(try r.takeByte());
    const visible = (try r.takeByte()) != 0;
    return .{ .id = id, .verdict = verdict, .target = target, .rate_bps = rate, .created_ms = created, .expires_ms = expires, .source = source, .visible = visible };
}

fn writeReading(w: *Writer, rd: ontology.Reading) Writer.Error!void {
    try w.writeInt(i64, rd.at_ms, .little);
    try writeKey(w, rd.flow_key);
    try w.writeByte(rd.impact);
    try w.writeByte(rd.confidence);
    try w.writeByte(lensSetByte(rd.lenses));
}

fn readReading(r: *Reader) !ontology.Reading {
    const at = try r.takeInt(i64, .little);
    const key = try readKey(r);
    const impact = try r.takeByte();
    const conf = try r.takeByte();
    const lenses = lensSetFromByte(try r.takeByte());
    return .{ .at_ms = at, .flow_key = key, .impact = impact, .confidence = conf, .lenses = lenses };
}

fn writeRuling(w: *Writer, ru: ontology.Ruling) Writer.Error!void {
    try w.writeInt(i64, ru.at_ms, .little);
    try writeKey(w, ru.flow_key);
    try w.writeInt(u64, ru.rule_id, .little);
    try w.writeByte(@intFromEnum(ru.verdict));
    try w.writeByte(@intFromEnum(ru.effect));
}

fn readRuling(r: *Reader) !ontology.Ruling {
    const at = try r.takeInt(i64, .little);
    const key = try readKey(r);
    const rule_id = try r.takeInt(u64, .little);
    const verdict: ontology.Verdict = @enumFromInt(try r.takeByte());
    const effect: ontology.Effect = @enumFromInt(try r.takeByte());
    return .{ .at_ms = at, .flow_key = key, .rule_id = rule_id, .verdict = verdict, .effect = effect };
}

fn writeFocus(w: *Writer, f: focusmod.Focus) Writer.Error!void {
    try w.writeByte(@intFromEnum(f.altitude));
    try w.writeByte(@intFromBool(f.shared));
    try w.writeByte(@intFromEnum(std.meta.activeTag(f.target)));
    switch (f.target) {
        .machine => {},
        .entity => |ek| try writeEntityKey(w, ek),
        .flow => |fk| try writeKey(w, fk),
    }
}

fn readFocus(r: *Reader) !focusmod.Focus {
    const altitude: focusmod.Altitude = @enumFromInt(try r.takeByte());
    const shared = (try r.takeByte()) != 0;
    const target: focusmod.Target = switch (try r.takeByte()) {
        0 => .machine,
        1 => .{ .entity = try readEntityKey(r) },
        2 => .{ .flow = try readKey(r) },
        else => return error.InvalidFrame,
    };
    return .{ .altitude = altitude, .shared = shared, .target = target };
}

fn writeUserState(w: *Writer, us: ontology.UserState) Writer.Error!void {
    try w.writeByte(@intFromEnum(std.meta.activeTag(us)));
    switch (us) {
        .profile => |p| try w.writeByte(@intFromEnum(p)),
        .lens_toggle => |lt| {
            try w.writeByte(@intFromEnum(lt.lens));
            try w.writeByte(@intFromBool(lt.on));
        },
        .greeting => |g| try writeGreeting(w, g),
        .focus => |f| try writeFocus(w, f),
    }
}

fn readUserState(r: *Reader) !ontology.UserState {
    return switch (try r.takeByte()) {
        0 => .{ .profile = @enumFromInt(try r.takeByte()) },
        1 => blk: {
            const l: lens.Lens = @enumFromInt(try r.takeByte());
            const on = (try r.takeByte()) != 0;
            break :blk .{ .lens_toggle = .{ .lens = l, .on = on } };
        },
        2 => .{ .greeting = try readGreeting(r) },
        3 => .{ .focus = try readFocus(r) },
        else => error.InvalidFrame,
    };
}

pub fn sendUserState(w: *Writer, us: ontology.UserState) Writer.Error!void {
    var buf: [max_frame]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeUserState(&pw, us);
    try sendFrame(w, .user_state, pw.buffered());
}

pub fn sendRule(w: *Writer, ru: ontology.Rule) Writer.Error!void {
    var buf: [max_frame]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeRule(&pw, ru);
    try sendFrame(w, .rule, pw.buffered());
}

pub fn sendReading(w: *Writer, rd: ontology.Reading) Writer.Error!void {
    var buf: [max_frame]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeReading(&pw, rd);
    try sendFrame(w, .reading, pw.buffered());
}

pub fn sendRuling(w: *Writer, ru: ontology.Ruling) Writer.Error!void {
    var buf: [max_frame]u8 = undefined;
    var pw = Writer.fixed(&buf);
    try writeRuling(&pw, ru);
    try sendFrame(w, .ruling, pw.buffered());
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
        .user_state => .{ .user_state = try readUserState(&pr) },
        .rule => .{ .rule = try readRule(&pr) },
        .reading => .{ .reading = try readReading(&pr) },
        .ruling => .{ .ruling = try readRuling(&pr) },
        _ => .{ .unknown = body[0] },
    };
}

// ---- streaming reassembly (the read-side twin of sendFrame) -----------------

/// Reassembles length-prefixed frames from a byte stream that arrives in arbitrary
/// chunks — a socket or pipe `read` can split one frame across reads or coalesce many
/// into one. Every consumer (the TUI, the GTK window, surveyor's upstream link) needs
/// exactly this buffer dance; keeping it here, next to `sendFrame`, gives the wire's
/// read side **one owner** so the copies can't drift.
///
///   stream.push(bytes_just_read);
///   while (try stream.next()) |frame| switch (frame) { ... }
pub const FrameStream = struct {
    gpa: std.mem.Allocator,
    acc: std.ArrayList(u8) = .empty,
    pos: usize = 0, // bytes already consumed at the front of `acc`

    pub fn init(gpa: std.mem.Allocator) FrameStream {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FrameStream) void {
        self.acc.deinit(self.gpa);
    }

    /// Feed in whatever you just read from the transport.
    pub fn push(self: *FrameStream, bytes: []const u8) !void {
        try self.acc.appendSlice(self.gpa, bytes);
    }

    /// Pull the next complete frame, or null if the buffer doesn't hold one yet (then
    /// `push` more and call again). Compacts consumed bytes to the front when it drains,
    /// so memory stays bounded by at most one partial frame.
    pub fn next(self: *FrameStream) !?Frame {
        const avail = self.acc.items.len - self.pos;
        if (avail >= 4) {
            const len = std.mem.readInt(u32, self.acc.items[self.pos..][0..4], .little);
            if (len > max_frame) return error.FrameTooLarge; // a bad/oversized frame can't balloon `acc`
            if (avail >= 4 + @as(usize, len)) {
                var r = Reader.fixed(self.acc.items[self.pos .. self.pos + 4 + len]);
                const frame = (try readFrame(&r)) orelse return error.InvalidFrame;
                self.pos += 4 + len;
                return frame;
            }
        }
        if (self.pos > 0) { // no full frame: slide the partial remainder to the front
            std.mem.copyForwards(u8, self.acc.items, self.acc.items[self.pos..]);
            self.acc.items.len -= self.pos;
            self.pos = 0;
        }
        return null;
    }
};

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
    f.remote_name.set("api.anthropic.com");
    f.asn = 13335;
    f.as_org.set("CLOUDFLARENET");
    f.country = .{ 'U', 'S' };

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
    try t.expectEqualStrings("api.anthropic.com", g.remote_name.slice());
    try t.expectEqual(@as(u32, 13335), g.asn);
    try t.expectEqualStrings("CLOUDFLARENET", g.as_org.slice());
    try t.expectEqualStrings("US", &g.country);
}

test "a v2 flow frame (no identity tail) decodes with identity at its zero values" {
    const t = std.testing;
    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 40000,
        .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }),
        .remote_port = 443,
    } };
    f.comm.set("curl");

    // Encode a v3 frame, then rewrite it as its v2 truncation: chop the identity tail
    // off the payload and fix the length prefix — byte-identical to what a v2 producer
    // sent, because the tail is strictly appended.
    var buf: [max_frame]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendFlowUpsert(&w, f);
    const wire = w.buffered();
    const tail_len = 1 + f.remote_name.len + 4 + 1 + f.as_org.len + 2; // name+asn+org+country
    const v2_len = wire.len - tail_len;
    var v2: [max_frame]u8 = undefined;
    @memcpy(v2[0..v2_len], wire[0..v2_len]);
    const old_frame_len = std.mem.readInt(u32, v2[0..4], .little);
    std.mem.writeInt(u32, v2[0..4], old_frame_len - @as(u32, @intCast(tail_len)), .little);

    var r = Reader.fixed(v2[0..v2_len]);
    const g = (try readFrame(&r)).?.flow_upsert;
    try t.expectEqualStrings("curl", g.comm.slice());
    try t.expectEqual(@as(u8, 0), g.remote_name.len);
    try t.expectEqual(@as(u32, 0), g.asn);
    try t.expectEqual(@as(u8, 0), g.as_org.len);
    try t.expectEqual([2]u8{ 0, 0 }, g.country);
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

test "user_state round-trips a greeting write" {
    const t = std.testing;
    const g: ontology.Greeting = .{
        .key = .{ .host = flow.Addr.v4(.{ 192, 168, 1, 50 }) },
        .label = flow.Str(64).from("mom's VPN"),
        .state = .greeted,
        .note = flow.Str(255).from("the good vpn"),
        .first_seen_ms = 1000,
        .last_seen_ms = 2000,
        .greeted_ms = 1500,
    };
    var buf: [max_frame]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendUserState(&w, .{ .greeting = g });
    var r = Reader.fixed(w.buffered());
    const f = (try readFrame(&r)).?;
    try t.expect(f == .user_state);
    try t.expect(f.user_state == .greeting);
    const g2 = f.user_state.greeting;
    try t.expectEqualStrings("mom's VPN", g2.label.slice());
    try t.expectEqual(ontology.GreetState.greeted, g2.state);
    try t.expectEqualStrings("the good vpn", g2.note.slice());
    try t.expect(g2.key == .host);
    try t.expectEqualSlices(u8, g.key.host.bytes[0..4], g2.key.host.bytes[0..4]);
    try t.expectEqual(@as(i64, 1500), g2.greeted_ms);
}

test "user_state round-trips a profile switch and a lens toggle" {
    const t = std.testing;
    var buf: [max_frame]u8 = undefined;
    {
        var w = Writer.fixed(&buf);
        try sendUserState(&w, .{ .profile = .security });
        var r = Reader.fixed(w.buffered());
        try t.expectEqual(lens.Profile.security, (try readFrame(&r)).?.user_state.profile);
    }
    {
        var w = Writer.fixed(&buf);
        try sendUserState(&w, .{ .lens_toggle = .{ .lens = .endpoint, .on = true } });
        var r = Reader.fixed(w.buffered());
        const us = (try readFrame(&r)).?.user_state;
        try t.expect(us.lens_toggle.on);
        try t.expectEqual(lens.Lens.endpoint, us.lens_toggle.lens);
    }
}

test "user_state round-trips a focus (the shared cursor survives the wire, R1)" {
    const t = std.testing;
    var buf: [max_frame]u8 = undefined;

    // a street-altitude focus on a specific flow, marked shared (the session cursor)
    const key: FlowKey = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 5, .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 };
    {
        const f: focusmod.Focus = .{ .altitude = .street, .target = .{ .flow = key }, .shared = true };
        var w = Writer.fixed(&buf);
        try sendUserState(&w, .{ .focus = f });
        var r = Reader.fixed(w.buffered());
        const us = (try readFrame(&r)).?.user_state;
        try t.expect(us == .focus);
        try t.expect(us.focus.eql(f)); // altitude, target flow, and shared all survive
        try t.expectEqual(focusmod.Altitude.street, us.focus.altitude);
        try t.expect(us.focus.shared);
    }
    // and an entity focus (region on an ASN), solo
    {
        const f: focusmod.Focus = .{ .altitude = .region, .target = .{ .entity = .{ .asn = 13335 } } };
        var w = Writer.fixed(&buf);
        try sendUserState(&w, .{ .focus = f });
        var r = Reader.fixed(w.buffered());
        const us = (try readFrame(&r)).?.user_state;
        try t.expect(us.focus.target == .entity);
        try t.expectEqual(@as(u32, 13335), us.focus.target.entity.asn);
        try t.expect(!us.focus.shared);
    }
}

test "rule frame round-trips" {
    const t = std.testing;
    const ru: ontology.Rule = .{ .id = 42, .verdict = .block, .target = .{ .asn = 13335 }, .created_ms = 9, .source = .postcard };
    var buf: [max_frame]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendRule(&w, ru);
    var r = Reader.fixed(w.buffered());
    const f = (try readFrame(&r)).?;
    try t.expect(f == .rule);
    try t.expectEqual(@as(u64, 42), f.rule.id);
    try t.expectEqual(ontology.Verdict.block, f.rule.verdict);
    try t.expect(f.rule.target == .asn);
    try t.expectEqual(@as(u32, 13335), f.rule.target.asn);
    try t.expectEqual(ontology.RuleSource.postcard, f.rule.source);
}

test "reading and ruling frames round-trip (a score shown vs an act done)" {
    const t = std.testing;
    const key: FlowKey = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 127, 0, 0, 1 }), .local_port = 1, .remote = flow.Addr.v4(.{ 8, 8, 8, 8 }), .remote_port = 443 };
    var lenses = lens.Set.initEmpty();
    lenses.insert(.risk);
    lenses.insert(.endpoint);
    var buf: [max_frame]u8 = undefined;
    {
        const rd: ontology.Reading = .{ .at_ms = 5, .flow_key = key, .impact = 78, .confidence = 60, .lenses = lenses };
        var w = Writer.fixed(&buf);
        try sendReading(&w, rd);
        var r = Reader.fixed(w.buffered());
        const f = (try readFrame(&r)).?;
        try t.expectEqual(@as(u8, 78), f.reading.impact);
        try t.expectEqual(@as(u8, 60), f.reading.confidence);
        try t.expect(f.reading.lenses.contains(.risk));
        try t.expect(f.reading.lenses.contains(.endpoint));
        try t.expect(!f.reading.lenses.contains(.system));
        try t.expectEqual(@as(u16, 443), f.reading.flow_key.remote_port);
    }
    {
        const rl: ontology.Ruling = .{ .at_ms = 6, .flow_key = key, .rule_id = 42, .verdict = .block, .effect = .blocked };
        var w = Writer.fixed(&buf);
        try sendRuling(&w, rl);
        var r = Reader.fixed(w.buffered());
        const f = (try readFrame(&r)).?;
        try t.expectEqual(ontology.Effect.blocked, f.ruling.effect);
        try t.expectEqual(@as(u64, 42), f.ruling.rule_id);
    }
}

test "FrameStream reassembles frames split and coalesced across reads" {
    const t = std.testing;
    // produce three frames back-to-back
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try sendHello(&w);
    try sendTick(&w, 7);
    try sendUserState(&w, .{ .profile = .security });
    const wire = w.buffered();

    var s = FrameStream.init(t.allocator);
    defer s.deinit();

    // feed it ONE byte at a time — the worst-case fragmentation a socket can hand us
    var got_hello = false;
    var got_tick: ?i64 = null;
    var got_profile: ?lens.Profile = null;
    for (wire) |b| {
        try s.push(&.{b});
        while (try s.next()) |frame| switch (frame) {
            .hello => got_hello = true,
            .tick => |ms| got_tick = ms,
            .user_state => |us| got_profile = us.profile,
            else => {},
        };
    }
    try t.expect(got_hello);
    try t.expectEqual(@as(?i64, 7), got_tick);
    try t.expectEqual(@as(?lens.Profile, .security), got_profile);

    // and the coalesced case: all three bytes-at-once in a single push
    var s2 = FrameStream.init(t.allocator);
    defer s2.deinit();
    try s2.push(wire);
    var n: usize = 0;
    while (try s2.next()) |_| n += 1;
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(?Frame, null), try s2.next()); // drained → null, not an error

    // an oversized length is rejected, not honoured into an unbounded buffer
    var s3 = FrameStream.init(t.allocator);
    defer s3.deinit();
    var big: [4]u8 = undefined;
    std.mem.writeInt(u32, &big, max_frame + 1, .little);
    try s3.push(&big);
    try t.expectError(error.FrameTooLarge, s3.next());
}

test "unknown frames are skipped so the protocol grows additively" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    // a frame of a type this build doesn't know (e.g. a future M3 frame)
    try w.writeInt(u32, 4, .little); // len: 1 type byte + 3 payload bytes
    try w.writeByte(99);
    try w.writeAll(&.{ 1, 2, 3 });
    try sendHello(&w); // a known frame right after it

    var r = Reader.fixed(w.buffered());
    const unk = (try readFrame(&r)).?;
    try t.expect(unk == .unknown);
    try t.expectEqual(@as(u8, 99), unk.unknown);
    // the reader resynced past the unknown payload and reads the next known frame
    try t.expectEqual(@as(u16, protocol_version), (try readFrame(&r)).?.hello);
}
