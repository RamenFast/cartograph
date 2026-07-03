//! Passive DNS — true hostnames from the box's own name resolution (V1/S3).
//!
//! rDNS (S1) asks the network "what is 140.82.116.3 called?" and gets the server's
//! name for itself (`lb-140-82-116-3-sea.github.com`). Passive DNS instead watches
//! the answers *this machine already asked for* — so the flow to that address gets
//! the name the user meant: `github.com`. No extra queries ever leave the box; we
//! only read what already crossed the wire.
//!
//! Mechanism: an AF_PACKET tap (needs CAP_NET_RAW) with the `cg_dns_filter` eBPF
//! socket filter attached, so the kernel hands us **only** UDP source-port-53
//! packets. The DNS parse is a pure function over bytes (tested below); each
//! A/AAAA answer is offered to the enricher's name cache as authoritative —
//! it wins over an rDNS guess for the same address.
//!
//! Honest limits: DoH/DoT resolution never crosses :53, so this sees nothing there
//! (rDNS still applies); TLS-SNI parsing is deferred post-V1 (ECH/QUIC erode it).

const std = @import("std");
const linux = std.os.linux;
const cartograph = @import("cartograph");
const Addr = cartograph.Addr;

const AF_PACKET = 17;
const SOCK_DGRAM = 2;
const SOCK_NONBLOCK = 0o4000;
const ETH_P_ALL: u16 = 0x0003;
const SOL_SOCKET = 1;
const SO_ATTACH_BPF = 50;
const IPPROTO_UDP = 17;

pub const Pdns = struct {
    fd: i32,

    /// `filter_prog_fd` is the loaded `cg_dns_filter` program (bpf.zig exposes it).
    pub fn init(filter_prog_fd: i32) !Pdns {
        const proto = std.mem.nativeToBig(u16, ETH_P_ALL);
        const rc = linux.socket(AF_PACKET, SOCK_DGRAM | SOCK_NONBLOCK, proto);
        if (linux.errno(rc) != .SUCCESS) return error.PdnsSocket; // needs CAP_NET_RAW
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const prc = linux.setsockopt(fd, SOL_SOCKET, SO_ATTACH_BPF, @ptrCast(&filter_prog_fd), @sizeOf(c_int));
        if (linux.errno(prc) != .SUCCESS) return error.PdnsFilter;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Pdns) void {
        _ = linux.close(self.fd);
    }

    /// Drain pending DNS answers (bounded per tick). For each A/AAAA record calls
    /// `sink.offerName(addr, qname, now_ms)`.
    pub fn poll(self: *Pdns, sink: anytype, now_ms: i64) void {
        var buf: [4096]u8 = undefined;
        var budget: usize = 64; // don't let a DNS storm own the tick
        while (budget > 0) : (budget -= 1) {
            const rc = linux.read(self.fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return; // EAGAIN = drained
            parsePacket(buf[0..rc], sink, now_ms);
        }
    }
};

/// A cooked (SOCK_DGRAM) AF_PACKET frame starts at the network header. Walk
/// IP → UDP → DNS. The eBPF filter already guaranteed "UDP sport 53", but parse
/// defensively — bytes from the wire earn no trust.
pub fn parsePacket(pkt: []const u8, sink: anytype, now_ms: i64) void {
    if (pkt.len < 1) return;
    switch (pkt[0] >> 4) {
        4 => {
            if (pkt.len < 20 or pkt[9] != IPPROTO_UDP) return;
            const ihl = @as(usize, pkt[0] & 0x0f) * 4;
            if (ihl < 20 or pkt.len < ihl + 8) return;
            parseDns(pkt[ihl + 8 ..], sink, now_ms);
        },
        6 => {
            if (pkt.len < 48 or pkt[6] != IPPROTO_UDP) return; // no extension-header walk (rare on DNS)
            parseDns(pkt[48..], sink, now_ms);
        },
        else => {},
    }
}

fn be16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

/// Parse one DNS message; offer every A/AAAA answer as (addr → first question's
/// qname). The qname — what the user *asked for* — beats the CNAME chain's target
/// as identity (asking for github.com and landing on a CDN name is the point).
pub fn parseDns(msg: []const u8, sink: anytype, now_ms: i64) void {
    if (msg.len < 12) return;
    const flags = be16(msg, 2);
    if (flags & 0x8000 == 0) return; // a query, not a response
    if (flags & 0x000f != 0) return; // rcode: only NOERROR carries usable answers
    const qdcount = be16(msg, 4);
    const ancount = be16(msg, 6);
    if (ancount == 0 or qdcount == 0) return;

    var pos: usize = 12;
    var qbuf: [253]u8 = undefined;
    const qname = readName(msg, &pos, &qbuf) orelse return;
    if (pos + 4 > msg.len) return;
    pos += 4; // qtype + qclass
    var extra_q: usize = 1;
    while (extra_q < qdcount) : (extra_q += 1) { // multi-question is a wire oddity; skip them
        skipName(msg, &pos) orelse return;
        if (pos + 4 > msg.len) return;
        pos += 4;
    }

    var i: usize = 0;
    while (i < ancount) : (i += 1) {
        skipName(msg, &pos) orelse return;
        if (pos + 10 > msg.len) return;
        const rtype = be16(msg, pos);
        const rclass = be16(msg, pos + 2);
        const rdlen = be16(msg, pos + 8);
        pos += 10;
        if (pos + rdlen > msg.len) return;
        if (rclass == 1) { // IN
            if (rtype == 1 and rdlen == 4) {
                sink.offerName(Addr.v4(msg[pos..][0..4].*), qname, now_ms);
            } else if (rtype == 28 and rdlen == 16) {
                sink.offerName(Addr.v6(msg[pos..][0..16].*), qname, now_ms);
            }
        }
        pos += rdlen;
    }
}

/// Decode a (possibly compressed) DNS name into `out` as lowercase dotted labels.
/// Advances `pos` past the name's bytes at its original position. Null = malformed.
fn readName(msg: []const u8, pos: *usize, out: *[253]u8) ?[]const u8 {
    var p = pos.*;
    var n: usize = 0;
    var jumps: usize = 0;
    var jumped = false;
    while (true) {
        if (p >= msg.len) return null;
        const len = msg[p];
        if (len == 0) {
            if (!jumped) pos.* = p + 1;
            break;
        }
        if (len & 0xc0 == 0xc0) { // compression pointer
            if (p + 1 >= msg.len) return null;
            const target = (@as(usize, len & 0x3f) << 8) | msg[p + 1];
            if (!jumped) pos.* = p + 2;
            jumped = true;
            jumps += 1;
            if (jumps > 16 or target >= msg.len) return null; // loop guard
            p = target;
            continue;
        }
        if (len & 0xc0 != 0) return null; // 0x40/0x80 label types: never valid here
        if (p + 1 + len > msg.len) return null;
        if (n + len + @intFromBool(n > 0) > out.len) return null;
        if (n > 0) {
            out[n] = '.';
            n += 1;
        }
        for (msg[p + 1 ..][0..len]) |ch| {
            out[n] = std.ascii.toLower(ch);
            n += 1;
        }
        p += 1 + len;
    }
    if (n == 0) return null;
    return out[0..n];
}

fn skipName(msg: []const u8, pos: *usize) ?void {
    var p = pos.*;
    while (true) {
        if (p >= msg.len) return null;
        const len = msg[p];
        if (len == 0) {
            pos.* = p + 1;
            return;
        }
        if (len & 0xc0 == 0xc0) { // a pointer ends the name
            if (p + 1 >= msg.len) return null;
            pos.* = p + 2;
            return;
        }
        if (len & 0xc0 != 0) return null;
        p += 1 + len;
    }
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

const TestSink = struct {
    names: std.ArrayList(struct { addr: Addr, name: [64]u8, name_len: usize }) = .empty,
    gpa: std.mem.Allocator,

    fn offerName(self: *TestSink, addr: Addr, name: []const u8, _: i64) void {
        var rec: @TypeOf(self.names.items[0]) = .{ .addr = addr, .name = undefined, .name_len = name.len };
        @memcpy(rec.name[0..name.len], name);
        self.names.append(self.gpa, rec) catch {};
    }
};

/// Build a response: question "github.com" A/IN, then `answers` with compressed
/// names (pointer to offset 12) — the shape real resolvers emit.
fn buildResponse(gpa: std.mem.Allocator, answers: []const struct { rtype: u16, rdata: []const u8 }) !std.ArrayList(u8) {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    // header: id, flags QR=1, qd=1, an=N, ns=0, ar=0
    try b.appendSlice(gpa, &.{ 0xab, 0xcd, 0x81, 0x80, 0, 1 });
    try b.appendSlice(gpa, &.{ 0, @intCast(answers.len), 0, 0, 0, 0 });
    // question: github.com IN A
    try b.appendSlice(gpa, &[_]u8{6} ++ "github" ++ &[_]u8{3} ++ "com" ++ &[_]u8{0});
    try b.appendSlice(gpa, &.{ 0, 1, 0, 1 });
    for (answers) |a| {
        try b.appendSlice(gpa, &.{ 0xc0, 0x0c }); // name: pointer to the question
        try b.appendSlice(gpa, &.{ @intCast(a.rtype >> 8), @intCast(a.rtype & 0xff), 0, 1 }); // type, class IN
        try b.appendSlice(gpa, &.{ 0, 0, 0, 60 }); // ttl
        try b.appendSlice(gpa, &.{ 0, @intCast(a.rdata.len) });
        try b.appendSlice(gpa, a.rdata);
    }
    return b;
}

test "a compressed A+AAAA response yields both addr→qname offers" {
    const gpa = testing.allocator;
    var resp = try buildResponse(gpa, &.{
        .{ .rtype = 1, .rdata = &.{ 140, 82, 116, 3 } },
        .{ .rtype = 28, .rdata = &(.{ 0x26, 0x06 } ++ .{0} ** 13 ++ .{7}) },
    });
    defer resp.deinit(gpa);

    var sink = TestSink{ .gpa = gpa };
    defer sink.names.deinit(gpa);
    parseDns(resp.items, &sink, 1000);

    try testing.expectEqual(@as(usize, 2), sink.names.items.len);
    const first = sink.names.items[0];
    try testing.expectEqualStrings("github.com", first.name[0..first.name_len]);
    try testing.expect(!first.addr.is_v6);
    try testing.expectEqualSlices(u8, &.{ 140, 82, 116, 3 }, first.addr.bytes[0..4]);
    const second = sink.names.items[1];
    try testing.expect(second.addr.is_v6);
    try testing.expectEqual(@as(u8, 7), second.addr.bytes[15]);
}

test "queries, errors, and truncated garbage are ignored" {
    const gpa = testing.allocator;
    var sink = TestSink{ .gpa = gpa };
    defer sink.names.deinit(gpa);

    var resp = try buildResponse(gpa, &.{.{ .rtype = 1, .rdata = &.{ 1, 2, 3, 4 } }});
    defer resp.deinit(gpa);

    // a query (QR=0)
    var query = try gpa.dupe(u8, resp.items);
    defer gpa.free(query);
    query[2] = 0x01; // QR bit off
    parseDns(query, &sink, 0);
    try testing.expectEqual(@as(usize, 0), sink.names.items.len);

    // NXDOMAIN (rcode 3)
    var nx = try gpa.dupe(u8, resp.items);
    defer gpa.free(nx);
    nx[3] = 0x83;
    parseDns(nx, &sink, 0);
    try testing.expectEqual(@as(usize, 0), sink.names.items.len);

    // truncations at every length must not panic or emit
    var cut: usize = 0;
    while (cut < resp.items.len) : (cut += 1) {
        parseDns(resp.items[0..cut], &sink, 0);
    }
    try testing.expectEqual(@as(usize, 0), sink.names.items.len);

    // a compression loop (pointer at itself) must bail via the jump guard
    var evil = try gpa.dupe(u8, resp.items);
    defer gpa.free(evil);
    evil[12] = 0xc0; // question name = pointer to itself
    evil[13] = 0x0c;
    parseDns(evil, &sink, 0);
    try testing.expectEqual(@as(usize, 0), sink.names.items.len);
}

test "the ipv4 packet walk reaches the DNS payload (variable IHL)" {
    const gpa = testing.allocator;
    var resp = try buildResponse(gpa, &.{.{ .rtype = 1, .rdata = &.{ 9, 9, 9, 9 } }});
    defer resp.deinit(gpa);

    var pkt: std.ArrayList(u8) = .empty;
    defer pkt.deinit(gpa);
    // IPv4 header with IHL=6 (one option word), proto UDP
    try pkt.appendSlice(gpa, &.{ 0x46, 0, 0, 0, 0, 0, 0, 0, 64, IPPROTO_UDP, 0, 0 });
    try pkt.appendSlice(gpa, &.{ 1, 1, 1, 1, 192, 168, 1, 9 }); // src/dst
    try pkt.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // the option word
    try pkt.appendSlice(gpa, &.{ 0, 53, 0xd4, 0x31, 0, 0, 0, 0 }); // UDP: sport 53
    try pkt.appendSlice(gpa, resp.items);

    var sink = TestSink{ .gpa = gpa };
    defer sink.names.deinit(gpa);
    parsePacket(pkt.items, &sink, 0);
    try testing.expectEqual(@as(usize, 1), sink.names.items.len);
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, sink.names.items[0].addr.bytes[0..4]);
}
