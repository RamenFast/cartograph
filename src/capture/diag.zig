//! inet_diag — the unprivileged source of truth for socket byte counters.
//!
//! `/proc/net/tcp` only exposes *queue depth*, not cumulative bytes, so it can't
//! drive a real throughput sparkline. The `sock_diag`/`inet_diag` netlink API (the
//! one `ss` uses) returns, per socket, `tcpi_bytes_acked` / `tcpi_bytes_received`
//! (genuine cumulative counters) plus smoothed RTT — for your own sockets, no
//! privilege required. We dump TCP and UDP over both address families.

const std = @import("std");
const linux = std.os.linux;

const cartograph = @import("cartograph");
const Addr = cartograph.Addr;
const Proto = cartograph.Proto;

// --- kernel ABI constants ----------------------------------------------------
const AF_NETLINK = 16;
const SOCK_RAW = 3;
const NETLINK_SOCK_DIAG = 4;

const SOCK_DIAG_BY_FAMILY = 20;
const NLMSG_NOOP = 1;
const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;

const NLM_F_REQUEST = 0x01;
const NLM_F_DUMP = 0x300; // NLM_F_ROOT | NLM_F_MATCH

const AF_INET = 2;
const AF_INET6 = 10;
const IPPROTO_TCP = 6;
const IPPROTO_UDP = 17;

const INET_DIAG_INFO = 2; // rtattr type carrying struct tcp_info

// --- kernel ABI structs (extern = C layout) ----------------------------------
const nlmsghdr = extern struct {
    len: u32,
    type: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

const inet_diag_sockid = extern struct {
    sport: [2]u8, // big-endian
    dport: [2]u8, // big-endian
    src: [16]u8, // network order
    dst: [16]u8, // network order
    iface: u32,
    cookie: [2]u32,
};

const inet_diag_req_v2 = extern struct {
    family: u8,
    protocol: u8,
    ext: u8,
    pad: u8,
    states: u32,
    id: inet_diag_sockid,
};

const inet_diag_msg = extern struct {
    family: u8,
    state: u8,
    timer: u8,
    retrans: u8,
    id: inet_diag_sockid,
    expires: u32,
    rqueue: u32,
    wqueue: u32,
    uid: u32,
    inode: u32,
};

const rtattr = extern struct {
    len: u16,
    type: u16,
};

comptime {
    std.debug.assert(@sizeOf(nlmsghdr) == 16);
    std.debug.assert(@sizeOf(inet_diag_sockid) == 48);
    std.debug.assert(@sizeOf(inet_diag_req_v2) == 56);
    std.debug.assert(@sizeOf(inet_diag_msg) == 72);
}

// Byte offsets into `struct tcp_info`. The struct only ever *grows* (fields are
// appended across kernel versions, never reordered), and the kernel reports how
// many bytes it actually wrote via the rtattr length. So we never assume a fixed
// size — each field is read only if `adata.len` actually reaches it (see parseMsg).
// That way an older/shorter tcp_info still yields RTT even if byte counters are
// absent, and a future longer one can't make us read past the reported end.
const TCPI_RTT_OFF = 68; // u32, microseconds
const TCPI_BYTES_ACKED_OFF = 120; // u64
const TCPI_BYTES_RECEIVED_OFF = 128; // u64

/// One socket as reported by inet_diag.
pub const SockRecord = struct {
    proto: Proto,
    is_v6: bool,
    local: Addr,
    local_port: u16,
    remote: Addr,
    remote_port: u16,
    state: u8,
    uid: u32,
    inode: u32,
    rx_bytes: u64, // tcpi_bytes_received (TCP only)
    tx_bytes: u64, // tcpi_bytes_acked (TCP only)
    rtt_us: u32,
};

fn ok(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .ACCES, .PERM => error.PermissionDenied,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Netlink,
    };
}

pub const Diag = struct {
    fd: i32,
    seq: u32 = 1,

    pub fn open() !Diag {
        const rc = try ok(linux.socket(AF_NETLINK, SOCK_RAW, NETLINK_SOCK_DIAG));
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(self: *Diag) void {
        _ = linux.close(self.fd);
    }

    /// Dump every TCP and UDP socket (v4 + v6) into `out`.
    pub fn dumpAll(self: *Diag, out: *std.ArrayList(SockRecord), gpa: std.mem.Allocator) !void {
        try self.dump(IPPROTO_TCP, AF_INET, .tcp, false, out, gpa);
        try self.dump(IPPROTO_TCP, AF_INET6, .tcp, true, out, gpa);
        try self.dump(IPPROTO_UDP, AF_INET, .udp, false, out, gpa);
        try self.dump(IPPROTO_UDP, AF_INET6, .udp, true, out, gpa);
    }

    fn dump(
        self: *Diag,
        protocol: u8,
        family: u8,
        proto: Proto,
        is_v6: bool,
        out: *std.ArrayList(SockRecord),
        gpa: std.mem.Allocator,
    ) !void {
        self.seq += 1;
        var req: extern struct { h: nlmsghdr, r: inet_diag_req_v2 } = .{
            .h = .{
                .len = @sizeOf(nlmsghdr) + @sizeOf(inet_diag_req_v2),
                .type = SOCK_DIAG_BY_FAMILY,
                .flags = NLM_F_REQUEST | NLM_F_DUMP,
                .seq = self.seq,
                .pid = 0,
            },
            .r = .{
                .family = family,
                .protocol = protocol,
                .ext = 1 << (INET_DIAG_INFO - 1),
                .pad = 0,
                .states = 0xffff_ffff, // all states
                .id = std.mem.zeroes(inet_diag_sockid),
            },
        };
        const reqbytes = std.mem.asBytes(&req);
        _ = try ok(linux.sendto(self.fd, reqbytes.ptr, reqbytes.len, 0, null, 0));

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try ok(linux.recvfrom(self.fd, &buf, buf.len, 0, null, null));
            if (n == 0) break;
            if (try parseDump(buf[0..n], proto, is_v6, out, gpa) == .done) break;
        }
    }
};

/// Whether a netlink response buffer ended the dump (`NLMSG_DONE`/`NLMSG_ERROR`)
/// or the caller should `recv` again.
pub const ParseState = enum { more, done };

/// Walk one netlink response buffer, appending a `SockRecord` per
/// `SOCK_DIAG_BY_FAMILY` message. This is the **pure, I/O-free decode seam**: the
/// live `dump` recvs into a buffer and hands it here, and tests feed it recorded
/// bytes — so capture correctness is asserted, not "validated by live runs"
/// (Nexus critique v3 §5.1). Malformed/over-long messages truncate the walk
/// rather than read past the buffer.
pub fn parseDump(
    buf: []const u8,
    proto: Proto,
    is_v6: bool,
    out: *std.ArrayList(SockRecord),
    gpa: std.mem.Allocator,
) !ParseState {
    var off: usize = 0;
    while (off + @sizeOf(nlmsghdr) <= buf.len) {
        const h: *align(1) const nlmsghdr = @ptrCast(&buf[off]);
        const mlen = h.len;
        if (mlen < @sizeOf(nlmsghdr) or off + mlen > buf.len) break;
        switch (h.type) {
            NLMSG_DONE, NLMSG_ERROR => return .done,
            NLMSG_NOOP => {},
            SOCK_DIAG_BY_FAMILY => {
                const payload = buf[off + @sizeOf(nlmsghdr) .. off + mlen];
                try parseMsg(payload, proto, is_v6, out, gpa);
            },
            else => {},
        }
        off += nlmsgAlign(mlen);
    }
    return .more;
}

fn nlmsgAlign(len: u32) usize {
    return (@as(usize, len) + 3) & ~@as(usize, 3);
}

fn rtaAlign(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

fn parseMsg(
    payload: []const u8,
    proto: Proto,
    is_v6: bool,
    out: *std.ArrayList(SockRecord),
    gpa: std.mem.Allocator,
) !void {
    if (payload.len < @sizeOf(inet_diag_msg)) return;
    const m: *align(1) const inet_diag_msg = @ptrCast(payload.ptr);

    var rec: SockRecord = .{
        .proto = proto,
        .is_v6 = is_v6,
        .local = addrFrom(m.id.src, is_v6),
        .local_port = std.mem.readInt(u16, &m.id.sport, .big),
        .remote = addrFrom(m.id.dst, is_v6),
        .remote_port = std.mem.readInt(u16, &m.id.dport, .big),
        .state = m.state,
        .uid = m.uid,
        .inode = m.inode,
        .rx_bytes = 0,
        .tx_bytes = 0,
        .rtt_us = 0,
    };

    // Walk the rtattrs for INET_DIAG_INFO (struct tcp_info).
    var off: usize = @sizeOf(inet_diag_msg);
    while (off + @sizeOf(rtattr) <= payload.len) {
        const a: *align(1) const rtattr = @ptrCast(&payload[off]);
        if (a.len < @sizeOf(rtattr) or off + a.len > payload.len) break;
        const adata = payload[off + @sizeOf(rtattr) .. off + a.len];
        if (a.type == INET_DIAG_INFO) {
            // Per-field bounds: only decode what the kernel actually reported.
            if (adata.len >= TCPI_RTT_OFF + 4)
                rec.rtt_us = std.mem.readInt(u32, adata[TCPI_RTT_OFF..][0..4], .little);
            if (adata.len >= TCPI_BYTES_ACKED_OFF + 8)
                rec.tx_bytes = std.mem.readInt(u64, adata[TCPI_BYTES_ACKED_OFF..][0..8], .little);
            if (adata.len >= TCPI_BYTES_RECEIVED_OFF + 8)
                rec.rx_bytes = std.mem.readInt(u64, adata[TCPI_BYTES_RECEIVED_OFF..][0..8], .little);
        }
        off += rtaAlign(a.len);
    }

    try out.append(gpa, rec);
}

fn addrFrom(raw: [16]u8, is_v6: bool) Addr {
    if (is_v6) return Addr.v6(raw);
    return Addr.v4(raw[0..4].*);
}

// ---- tests: golden netlink frames, no root required -------------------------
// These assemble real inet_diag wire bytes from the kernel ABI structs and feed
// them to `parseDump`, so decode correctness (offsets, length guards, framing,
// alignment) is asserted rather than "validated by live runs" (critique §5.1).

const testing = std.testing;

/// A 16-byte address with an IPv4 in the first 4 (network order, as the kernel sends).
fn a4(b: [4]u8) [16]u8 {
    var x = [_]u8{0} ** 16;
    @memcpy(x[0..4], &b);
    return x;
}

/// Set the three fields cartograph reads into a `tcp_info` blob, each only if the
/// blob is long enough to hold it — mirroring a kernel that wrote a shorter struct.
fn makeTcpInfo(buf: []u8, rtt_us: u32, bytes_acked: u64, bytes_received: u64) void {
    @memset(buf, 0);
    if (buf.len >= TCPI_RTT_OFF + 4)
        std.mem.writeInt(u32, buf[TCPI_RTT_OFF..][0..4], rtt_us, .little);
    if (buf.len >= TCPI_BYTES_ACKED_OFF + 8)
        std.mem.writeInt(u64, buf[TCPI_BYTES_ACKED_OFF..][0..8], bytes_acked, .little);
    if (buf.len >= TCPI_BYTES_RECEIVED_OFF + 8)
        std.mem.writeInt(u64, buf[TCPI_BYTES_RECEIVED_OFF..][0..8], bytes_received, .little);
}

fn mkMsg(family: u8, state: u8, src: [16]u8, sport: u16, dst: [16]u8, dport: u16, uid: u32, inode: u32) inet_diag_msg {
    var id: inet_diag_sockid = std.mem.zeroes(inet_diag_sockid);
    id.src = src;
    id.dst = dst;
    std.mem.writeInt(u16, &id.sport, sport, .big);
    std.mem.writeInt(u16, &id.dport, dport, .big);
    return .{ .family = family, .state = state, .timer = 0, .retrans = 0, .id = id, .expires = 0, .rqueue = 0, .wqueue = 0, .uid = uid, .inode = inode };
}

/// Append one `SOCK_DIAG_BY_FAMILY` message (msg + an `INET_DIAG_INFO` rtattr
/// carrying `tcp_info`) to `out`, padded to the 4-byte netlink alignment.
fn appendSockMsg(out: *std.ArrayList(u8), gpa: std.mem.Allocator, msg: inet_diag_msg, tcp_info: []const u8) !void {
    const attr_len = @sizeOf(rtattr) + tcp_info.len;
    const mlen = @sizeOf(nlmsghdr) + @sizeOf(inet_diag_msg) + attr_len;
    const h = nlmsghdr{ .len = @intCast(mlen), .type = SOCK_DIAG_BY_FAMILY, .flags = 0, .seq = 0, .pid = 0 };
    try out.appendSlice(gpa, std.mem.asBytes(&h));
    try out.appendSlice(gpa, std.mem.asBytes(&msg));
    const a = rtattr{ .len = @intCast(attr_len), .type = INET_DIAG_INFO };
    try out.appendSlice(gpa, std.mem.asBytes(&a));
    try out.appendSlice(gpa, tcp_info);
    while (out.items.len % 4 != 0) try out.append(gpa, 0);
}

fn appendDone(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const h = nlmsghdr{ .len = @sizeOf(nlmsghdr), .type = NLMSG_DONE, .flags = 0, .seq = 0, .pid = 0 };
    try out.appendSlice(gpa, std.mem.asBytes(&h));
}

test "parseDump decodes a full tcp_info golden frame" {
    const gpa = testing.allocator;
    var info: [192]u8 = undefined;
    makeTcpInfo(&info, 22004, 38000, 410000);

    var nl: std.ArrayList(u8) = .empty;
    defer nl.deinit(gpa);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 192, 168, 1, 9 }), 44330, a4(.{ 140, 82, 121, 4 }), 443, 1000, 123456), &info);
    try appendDone(&nl, gpa);

    var out: std.ArrayList(SockRecord) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(ParseState.done, try parseDump(nl.items, .tcp, false, &out, gpa));
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const r = out.items[0];
    try testing.expectEqual(Proto.tcp, r.proto);
    try testing.expect(!r.is_v6);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 1, 9 }, r.local.bytes[0..4]);
    try testing.expectEqual(@as(u16, 44330), r.local_port);
    try testing.expectEqualSlices(u8, &.{ 140, 82, 121, 4 }, r.remote.bytes[0..4]);
    try testing.expectEqual(@as(u16, 443), r.remote_port);
    try testing.expectEqual(@as(u8, 1), r.state);
    try testing.expectEqual(@as(u32, 1000), r.uid);
    try testing.expectEqual(@as(u32, 123456), r.inode);
    try testing.expectEqual(@as(u32, 22004), r.rtt_us);
    try testing.expectEqual(@as(u64, 38000), r.tx_bytes);
    try testing.expectEqual(@as(u64, 410000), r.rx_bytes);
}

test "parseDump honors per-field tcp_info length guards (§5.1)" {
    const gpa = testing.allocator;
    // A short tcp_info: long enough for RTT (off 68), too short for the byte
    // counters (off 120/128). A fixed-size decode would read past the kernel's
    // reported end; the guards must yield RTT only.
    var info: [72]u8 = undefined;
    makeTcpInfo(&info, 15000, 999, 999); // the 999s are never written (too short)

    var nl: std.ArrayList(u8) = .empty;
    defer nl.deinit(gpa);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 10, 0, 0, 5 }), 51000, a4(.{ 10, 0, 0, 1 }), 22, 0, 7), &info);
    try appendDone(&nl, gpa);

    var out: std.ArrayList(SockRecord) = .empty;
    defer out.deinit(gpa);
    _ = try parseDump(nl.items, .tcp, false, &out, gpa);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 15000), out.items[0].rtt_us);
    try testing.expectEqual(@as(u64, 0), out.items[0].tx_bytes);
    try testing.expectEqual(@as(u64, 0), out.items[0].rx_bytes);
}

test "parseDump frames multiple messages and stops at DONE" {
    const gpa = testing.allocator;
    var info: [160]u8 = undefined;
    makeTcpInfo(&info, 1000, 10, 20);

    var nl: std.ArrayList(u8) = .empty;
    defer nl.deinit(gpa);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 192, 168, 1, 9 }), 40000, a4(.{ 1, 1, 1, 1 }), 443, 1000, 100), &info);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 192, 168, 1, 9 }), 40001, a4(.{ 8, 8, 8, 8 }), 443, 1000, 101), &info);
    try appendDone(&nl, gpa);
    // a trailing message after DONE must NOT be decoded
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 192, 168, 1, 9 }), 40002, a4(.{ 9, 9, 9, 9 }), 443, 1000, 102), &info);

    var out: std.ArrayList(SockRecord) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(ParseState.done, try parseDump(nl.items, .tcp, false, &out, gpa));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u16, 40000), out.items[0].local_port);
    try testing.expectEqual(@as(u16, 40001), out.items[1].local_port);
}

test "parseDump decodes an IPv6 record" {
    const gpa = testing.allocator;
    var info: [160]u8 = undefined;
    makeTcpInfo(&info, 5000, 1, 2);
    const v6: [16]u8 = .{ 0x20, 0x01, 0x4, 0x86, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const local6: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 };

    var nl: std.ArrayList(u8) = .empty;
    defer nl.deinit(gpa);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET6, 1, local6, 55555, v6, 443, 1000, 200), &info);
    try appendDone(&nl, gpa);

    var out: std.ArrayList(SockRecord) = .empty;
    defer out.deinit(gpa);
    _ = try parseDump(nl.items, .tcp, true, &out, gpa);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].is_v6);
    try testing.expectEqualSlices(u8, &v6, &out.items[0].remote.bytes);
    try testing.expectEqual(@as(u16, 443), out.items[0].remote_port);
}

test "parseDump tolerates a truncated trailing message" {
    const gpa = testing.allocator;
    var nl: std.ArrayList(u8) = .empty;
    defer nl.deinit(gpa);
    var info: [160]u8 = undefined;
    makeTcpInfo(&info, 1, 1, 1);
    try appendSockMsg(&nl, gpa, mkMsg(AF_INET, 1, a4(.{ 127, 0, 0, 1 }), 9119, a4(.{ 127, 0, 0, 1 }), 40424, 1000, 1), &info);
    // a header claiming more bytes than remain must be ignored, not over-read
    const bogus = nlmsghdr{ .len = 9999, .type = SOCK_DIAG_BY_FAMILY, .flags = 0, .seq = 0, .pid = 0 };
    try nl.appendSlice(gpa, std.mem.asBytes(&bogus));

    var out: std.ArrayList(SockRecord) = .empty;
    defer out.deinit(gpa);
    try testing.expectEqual(ParseState.more, try parseDump(nl.items, .tcp, false, &out, gpa));
    try testing.expectEqual(@as(usize, 1), out.items.len); // only the valid one
}
