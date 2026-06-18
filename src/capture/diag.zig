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
        dump_loop: while (true) {
            const n = try ok(linux.recvfrom(self.fd, &buf, buf.len, 0, null, null));
            if (n == 0) break;
            var off: usize = 0;
            while (off + @sizeOf(nlmsghdr) <= n) {
                const h: *align(1) const nlmsghdr = @ptrCast(&buf[off]);
                const mlen = h.len;
                if (mlen < @sizeOf(nlmsghdr) or off + mlen > n) break;
                switch (h.type) {
                    NLMSG_DONE => break :dump_loop,
                    NLMSG_ERROR => break :dump_loop,
                    NLMSG_NOOP => {},
                    SOCK_DIAG_BY_FAMILY => {
                        const payload = buf[off + @sizeOf(nlmsghdr) .. off + mlen];
                        try parseMsg(payload, proto, is_v6, out, gpa);
                    },
                    else => {},
                }
                off += nlmsgAlign(mlen);
            }
        }
    }
};

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
