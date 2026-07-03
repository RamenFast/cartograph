//! A minimal, pure-Zig MaxMind DB (.mmdb) reader.
//!
//! Just enough of the spec (maxmind.github.io/MaxMind-DB) to answer, offline and in
//! microseconds, "which country / which AS owns this IP?" — the V1/S1 identity pass.
//! The format is small: a binary trie over IP prefixes, a typed data section, and a
//! metadata map at the end. A pure decoder over caller-owned bytes: no I/O, no
//! allocation, no libmaxminddb — the base build stays dependency-free.
//!
//! Works with any GeoLite2/DB-IP-shaped database (ASN + Country are what Cartograph
//! loads; see capture/enrich.zig for the two field paths).

const std = @import("std");
const flow = @import("flow.zig");

pub const Error = error{ NotMmdb, Corrupt, Unsupported };

const metadata_marker = "\xab\xcd\xefMaxMind.com";

/// A decoded data-section value. Slices borrow from the database bytes.
pub const Value = union(enum) {
    string: []const u8,
    bytes: []const u8,
    uint: u64,
    int: i64,
    double: f64,
    boolean: bool,
    map: usize, // field count; key/value pairs follow via `next`
    array: usize, // element count; elements follow via `next`
};

pub const Mmdb = struct {
    /// The whole file. Caller owns the memory (and must outlive the Mmdb).
    bytes: []const u8,
    node_count: u32,
    record_size: u16, // bits per record: 24, 28, or 32
    ip_version: u8, // 4 or 6
    tree_size: usize,
    /// The data section: after the tree and its 16-byte zero separator.
    data: []const u8,

    pub fn init(bytes: []const u8) Error!Mmdb {
        const marker_pos = std.mem.lastIndexOf(u8, bytes, metadata_marker) orelse return error.NotMmdb;
        var meta = Decoder{ .data = bytes[marker_pos + metadata_marker.len ..] };

        var node_count: ?u64 = null;
        var record_size: ?u64 = null;
        var ip_version: ?u64 = null;
        const head = try meta.next();
        if (head != .map) return error.Corrupt;
        for (0..head.map) |_| {
            const key = try meta.next();
            if (key != .string) return error.Corrupt;
            const want: ?*?u64 = if (std.mem.eql(u8, key.string, "node_count"))
                &node_count
            else if (std.mem.eql(u8, key.string, "record_size"))
                &record_size
            else if (std.mem.eql(u8, key.string, "ip_version"))
                &ip_version
            else
                null;
            if (want) |slot| {
                const v = try meta.next();
                if (v != .uint) return error.Corrupt;
                slot.* = v.uint;
            } else {
                try meta.skip();
            }
        }

        const nc = node_count orelse return error.Corrupt;
        const rs = record_size orelse return error.Corrupt;
        const ipv = ip_version orelse return error.Corrupt;
        if (rs != 24 and rs != 28 and rs != 32) return error.Unsupported;
        if (ipv != 4 and ipv != 6) return error.Unsupported;
        if (nc == 0 or nc > std.math.maxInt(u32)) return error.Corrupt;

        const tree_size = @as(usize, @intCast(nc)) * @as(usize, @intCast(rs)) / 4; // 2 records/node, rs bits each
        if (tree_size + 16 > marker_pos) return error.Corrupt;

        return .{
            .bytes = bytes,
            .node_count = @intCast(nc),
            .record_size = @intCast(rs),
            .ip_version = @intCast(ipv),
            .tree_size = tree_size,
            .data = bytes[tree_size + 16 .. marker_pos],
        };
    }

    /// One trie record: where node `node` sends bit-value `right`.
    fn record(m: *const Mmdb, node: u32, right: bool) Error!u32 {
        const node_bytes: usize = @as(usize, m.record_size) / 4; // 2 records of record_size bits
        const base = @as(usize, node) * node_bytes;
        if (base + node_bytes > m.tree_size) return error.Corrupt;
        const b = m.bytes[base .. base + node_bytes];
        return switch (m.record_size) {
            24 => if (right)
                (@as(u32, b[3]) << 16) | (@as(u32, b[4]) << 8) | b[5]
            else
                (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2],
            28 => if (right)
                (@as(u32, b[3] & 0x0f) << 24) | (@as(u32, b[4]) << 16) | (@as(u32, b[5]) << 8) | b[6]
            else
                (@as(u32, b[3] & 0xf0) << 20) | (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2],
            32 => if (right)
                std.mem.readInt(u32, b[4..8], .big)
            else
                std.mem.readInt(u32, b[0..4], .big),
            else => unreachable, // init validated
        };
    }

    /// Walk the trie for `addr`. Returns an offset into `data` (feed it to `getPath`
    /// or `decoder`), or null when the database has no record for that address.
    /// IPv4 addresses in an IPv6 tree live under ::/96 (the spec's alignment).
    pub fn lookup(m: *const Mmdb, addr: flow.Addr) Error!?usize {
        if (m.ip_version == 4 and addr.is_v6) return null;
        const lead_zeros: usize = if (m.ip_version == 6 and !addr.is_v6) 96 else 0;
        const addr_bits: usize = if (addr.is_v6) 128 else 32;

        var node: u32 = 0;
        var i: usize = 0;
        while (i < lead_zeros + addr_bits) : (i += 1) {
            const bit = if (i < lead_zeros) false else blk: {
                const j = i - lead_zeros;
                break :blk (addr.bytes[j / 8] >> @intCast(7 - (j % 8))) & 1 == 1;
            };
            const rec = try m.record(node, bit);
            if (rec < m.node_count) {
                node = rec;
                continue;
            }
            if (rec == m.node_count) return null; // explicit "no data"
            const off = @as(usize, rec) - m.node_count - 16; // relative to the data section
            if (off >= m.data.len) return error.Corrupt;
            return off;
        }
        return null;
    }

    /// Decode the value at `data_off` (from `lookup`), descending maps along `path`.
    /// Null when a key along the path is absent — a schema mismatch, not an error.
    pub fn getPath(m: *const Mmdb, data_off: usize, path: []const []const u8) Error!?Value {
        var d = Decoder{ .data = m.data, .pos = data_off };
        for (path) |seg| if (!try d.find(seg)) return null;
        return try d.next();
    }
};

/// A cursor over one data (or metadata) section. Values decode in place; pointers
/// are followed transparently (they're how mmdb dedupes repeated strings/maps).
pub const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    fn takeByte(d: *Decoder) Error!u8 {
        if (d.pos >= d.data.len) return error.Corrupt;
        defer d.pos += 1;
        return d.data[d.pos];
    }

    fn take(d: *Decoder, n: usize) Error![]const u8 {
        if (d.data.len - d.pos < n) return error.Corrupt;
        defer d.pos += n;
        return d.data[d.pos..][0..n];
    }

    /// Big-endian unsigned int of `n` bytes (the format's number encoding).
    fn uintBytes(d: *Decoder, n: usize) Error!u64 {
        if (n > 8) return error.Unsupported;
        var v: u64 = 0;
        for (try d.take(n)) |b| v = (v << 8) | b;
        return v;
    }

    const Head = struct {
        kind: u8, // 1=pointer 2=string 3=double 4=bytes 5=u16 6=u32 7=map, then +7 extended
        size: usize, // payload length / element count; for a pointer: the target offset
    };

    fn head(d: *Decoder) Error!Head {
        const ctrl = try d.takeByte();
        var kind: u8 = ctrl >> 5;
        var size: usize = ctrl & 0x1f;

        if (kind == 1) { // pointer: size bits select width, low 3 bits join the offset
            const ss: u2 = @intCast((ctrl >> 3) & 0x3);
            const vvv: u64 = ctrl & 0x7;
            const off: u64 = switch (ss) {
                0 => (vvv << 8) | try d.uintBytes(1),
                1 => ((vvv << 16) | try d.uintBytes(2)) + 2048,
                2 => ((vvv << 24) | try d.uintBytes(3)) + 526336,
                3 => try d.uintBytes(4),
            };
            if (off >= d.data.len) return error.Corrupt;
            return .{ .kind = 1, .size = @intCast(off) };
        }

        if (kind == 0) kind = @as(u8, try d.takeByte()) +| 7; // extended type
        if (size == 29) {
            size = 29 + @as(usize, try d.takeByte());
        } else if (size == 30) {
            size = 285 + @as(usize, @intCast(try d.uintBytes(2)));
        } else if (size == 31) {
            size = 65821 + @as(usize, @intCast(try d.uintBytes(3)));
        }
        return .{ .kind = kind, .size = size };
    }

    /// Decode the next value, following pointers.
    pub fn next(d: *Decoder) Error!Value {
        return d.nextDepth(0);
    }

    fn nextDepth(d: *Decoder, depth: usize) Error!Value {
        if (depth > 4) return error.Corrupt; // pointers may not chain (spec); tolerate a little
        const h = try d.head();
        return switch (h.kind) {
            1 => { // pointer: decode at the target, leave this cursor past the pointer
                var sub = Decoder{ .data = d.data, .pos = h.size };
                return sub.nextDepth(depth + 1);
            },
            2 => .{ .string = try d.take(h.size) },
            3 => blk: {
                if (h.size != 8) return error.Corrupt;
                break :blk .{ .double = @bitCast(std.mem.readInt(u64, (try d.take(8))[0..8], .big)) };
            },
            4 => .{ .bytes = try d.take(h.size) },
            5, 6, 9 => .{ .uint = try d.uintBytes(h.size) }, // uint16 / uint32 / uint64
            7 => .{ .map = h.size },
            8 => blk: { // int32: big-endian, `size` bytes used
                if (h.size > 4) return error.Corrupt;
                const raw: u32 = @intCast(try d.uintBytes(h.size));
                break :blk .{ .int = @as(i32, @bitCast(raw)) };
            },
            10 => blk: { // uint128: keep the low 64 bits (never needed for geo data)
                const s = try d.take(h.size);
                var v: u64 = 0;
                for (s[if (s.len > 8) s.len - 8 else 0 ..]) |b| v = (v << 8) | b;
                break :blk .{ .uint = v };
            },
            11 => .{ .array = h.size },
            14 => .{ .boolean = h.size != 0 },
            15 => blk: { // float
                if (h.size != 4) return error.Corrupt;
                const raw: u32 = std.mem.readInt(u32, (try d.take(4))[0..4], .big);
                break :blk .{ .double = @as(f32, @bitCast(raw)) };
            },
            else => error.Unsupported, // container/end-marker never appear in data
        };
    }

    /// Skip one whole value (recursing through maps/arrays, not following pointers).
    pub fn skip(d: *Decoder) Error!void {
        try d.skipDepth(0);
    }

    fn skipDepth(d: *Decoder, depth: usize) Error!void {
        if (depth > 32) return error.Corrupt;
        const h = try d.head();
        switch (h.kind) {
            1, 14 => {}, // pointer bytes / boolean already consumed by head()
            2, 3, 4, 5, 6, 8, 9, 10, 15 => _ = try d.take(h.size),
            7 => for (0..h.size) |_| { // map: size × (key, value)
                try d.skipDepth(depth + 1);
                try d.skipDepth(depth + 1);
            },
            11 => for (0..h.size) |_| try d.skipDepth(depth + 1),
            else => return error.Unsupported,
        }
    }

    /// With the cursor at a map: position it at the value for `key` (true), or just
    /// past the whole map (false). Chain calls to descend nested maps.
    pub fn find(d: *Decoder, key: []const u8) Error!bool {
        const v = try d.next();
        if (v != .map) return error.Corrupt;
        for (0..v.map) |_| {
            const k = try d.next();
            if (k != .string) return error.Corrupt;
            if (std.mem.eql(u8, k.string, key)) return true;
            try d.skip();
        }
        return false;
    }
};

// ---- tests --------------------------------------------------------------------
// The fixtures below are hand-assembled per the spec — a tiny trie, a data section
// exercising strings/uints/maps/pointers/extended sizes, and a metadata map.

const testing = std.testing;

fn u24be(v: u32) [3]u8 {
    return .{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

/// The shared data section: at 0 a string (pointer target), at 14 the record map.
///   {"country":{"iso_code":"AU"},
///    "autonomous_system_number": 13335,
///    "autonomous_system_organization": <pointer to 0>}
const fixture_record_off = 14;
fn appendFixtureData(list: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    // offset 0: "CLOUDFLARENET" (string, len 13) — the pointer's target
    try list.append(gpa, (2 << 5) | 13);
    try list.appendSlice(gpa, "CLOUDFLARENET");
    // offset 14: map of 3
    try list.append(gpa, (7 << 5) | 3);
    try list.append(gpa, (2 << 5) | 7); // key "country"
    try list.appendSlice(gpa, "country");
    try list.append(gpa, (7 << 5) | 1); // value: map of 1
    try list.append(gpa, (2 << 5) | 8); // key "iso_code"
    try list.appendSlice(gpa, "iso_code");
    try list.append(gpa, (2 << 5) | 2); // value "AU"
    try list.appendSlice(gpa, "AU");
    try list.append(gpa, (2 << 5) | 24); // key "autonomous_system_number"
    try list.appendSlice(gpa, "autonomous_system_number");
    try list.append(gpa, (6 << 5) | 2); // value: uint32, 2 bytes
    try list.appendSlice(gpa, &.{ 0x34, 0x17 }); // 13335
    try list.append(gpa, (2 << 5) | 29); // key len 30 via extended size (29 + next byte)
    try list.append(gpa, 1);
    try list.appendSlice(gpa, "autonomous_system_organization");
    try list.appendSlice(gpa, &.{ (1 << 5) | 0, 0 }); // value: pointer (ss=0) to offset 0
}

fn appendFixtureMetadata(list: *std.ArrayList(u8), gpa: std.mem.Allocator, node_count: u32, ip_version: u8) !void {
    try list.appendSlice(gpa, metadata_marker);
    try list.append(gpa, (7 << 5) | 3); // map of 3
    try list.append(gpa, (2 << 5) | 10);
    try list.appendSlice(gpa, "node_count");
    try list.append(gpa, (6 << 5) | 4); // uint32, 4 bytes
    var nc: [4]u8 = undefined;
    std.mem.writeInt(u32, &nc, node_count, .big);
    try list.appendSlice(gpa, &nc);
    try list.append(gpa, (2 << 5) | 11);
    try list.appendSlice(gpa, "record_size");
    try list.append(gpa, (5 << 5) | 1); // uint16, 1 byte
    try list.append(gpa, 24);
    try list.append(gpa, (2 << 5) | 10);
    try list.appendSlice(gpa, "ip_version");
    try list.append(gpa, (5 << 5) | 1);
    try list.append(gpa, ip_version);
}

/// A v4 database mapping exactly 1.0.0.0/8 → the fixture record. 8 chain nodes,
/// one per bit of the first octet (0b00000001).
fn buildV4Fixture(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    const node_count: u32 = 8;
    const miss = node_count; // "no data"
    const data_ptr = node_count + 16 + fixture_record_off;
    for (0..8) |i| {
        const expected_bit: bool = i == 7; // 0b00000001: only the last bit is 1
        const on_match: u32 = if (i == 7) data_ptr else @intCast(i + 1);
        const left = if (expected_bit) miss else on_match;
        const right = if (expected_bit) on_match else miss;
        try list.appendSlice(gpa, &u24be(left));
        try list.appendSlice(gpa, &u24be(right));
    }
    try list.appendSlice(gpa, &(.{0} ** 16)); // separator
    try appendFixtureData(&list, gpa);
    try appendFixtureMetadata(&list, gpa, node_count, 4);
    return list;
}

/// A v6 database mapping 1.0.0.0/8 *under ::/96* (the v4-in-v6 alignment): a chain
/// of 96 zero-bit nodes, then the 8 bits of the first octet.
fn buildV6Fixture(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    const node_count: u32 = 104;
    const miss = node_count;
    const data_ptr = node_count + 16 + fixture_record_off;
    for (0..104) |i| {
        const expected_bit: bool = i == 103; // 96 zeros, then 0b00000001
        const on_match: u32 = if (i == 103) data_ptr else @intCast(i + 1);
        const left = if (expected_bit) miss else on_match;
        const right = if (expected_bit) on_match else miss;
        try list.appendSlice(gpa, &u24be(left));
        try list.appendSlice(gpa, &u24be(right));
    }
    try list.appendSlice(gpa, &(.{0} ** 16));
    try appendFixtureData(&list, gpa);
    try appendFixtureMetadata(&list, gpa, node_count, 6);
    return list;
}

test "v4 fixture: hit decodes country, asn, and a pointer-deduped org" {
    const gpa = testing.allocator;
    var fx = try buildV4Fixture(gpa);
    defer fx.deinit(gpa);
    const db = try Mmdb.init(fx.items);
    try testing.expectEqual(@as(u32, 8), db.node_count);
    try testing.expectEqual(@as(u8, 4), db.ip_version);

    const off = (try db.lookup(flow.Addr.v4(.{ 1, 2, 3, 4 }))) orelse return error.ExpectedHit;
    const cc = (try db.getPath(off, &.{ "country", "iso_code" })) orelse return error.MissingField;
    try testing.expectEqualStrings("AU", cc.string);
    const asn = (try db.getPath(off, &.{"autonomous_system_number"})) orelse return error.MissingField;
    try testing.expectEqual(@as(u64, 13335), asn.uint);
    const org = (try db.getPath(off, &.{"autonomous_system_organization"})) orelse return error.MissingField;
    try testing.expectEqualStrings("CLOUDFLARENET", org.string); // via the pointer

    // a key that isn't there is null, not an error
    try testing.expectEqual(@as(?Value, null), try db.getPath(off, &.{"city"}));
}

test "v4 fixture: miss returns null; v6 addr in a v4 tree returns null" {
    const gpa = testing.allocator;
    var fx = try buildV4Fixture(gpa);
    defer fx.deinit(gpa);
    const db = try Mmdb.init(fx.items);
    try testing.expectEqual(@as(?usize, null), try db.lookup(flow.Addr.v4(.{ 2, 2, 2, 2 })));
    try testing.expectEqual(@as(?usize, null), try db.lookup(flow.Addr.v4(.{ 128, 0, 0, 1 })));
    try testing.expectEqual(@as(?usize, null), try db.lookup(flow.Addr.v6(.{1} ++ .{0} ** 15)));
}

test "v6 fixture: a v4 address resolves under ::/96 (the real GeoLite2/DB-IP shape)" {
    const gpa = testing.allocator;
    var fx = try buildV6Fixture(gpa);
    defer fx.deinit(gpa);
    const db = try Mmdb.init(fx.items);
    try testing.expectEqual(@as(u8, 6), db.ip_version);

    const off = (try db.lookup(flow.Addr.v4(.{ 1, 9, 9, 9 }))) orelse return error.ExpectedHit;
    const cc = (try db.getPath(off, &.{ "country", "iso_code" })) orelse return error.MissingField;
    try testing.expectEqualStrings("AU", cc.string);

    // native v6 lookups walk the same tree (and miss here: ::1 is not under 1.0.0.0/8)
    try testing.expectEqual(@as(?usize, null), try db.lookup(flow.Addr.v6(.{0} ** 15 ++ .{1})));
    try testing.expectEqual(@as(?usize, null), try db.lookup(flow.Addr.v4(.{ 8, 8, 8, 8 })));
}

test "not an mmdb / truncated mmdb is rejected" {
    try testing.expectError(error.NotMmdb, Mmdb.init("definitely not a database"));
    const gpa = testing.allocator;
    var fx = try buildV4Fixture(gpa);
    defer fx.deinit(gpa);
    // chop the tree in half but keep the metadata: init must catch the size lie
    var broken: std.ArrayList(u8) = .empty;
    defer broken.deinit(gpa);
    try broken.appendSlice(gpa, fx.items[0..20]);
    const meta_at = std.mem.lastIndexOf(u8, fx.items, metadata_marker).?;
    try broken.appendSlice(gpa, fx.items[meta_at..]);
    try testing.expectError(error.Corrupt, Mmdb.init(broken.items));
}
