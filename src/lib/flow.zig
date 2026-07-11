//! The flow model — the atom of Cartograph's view-model.
//!
//! A `Flow` is one conversation: a 5-tuple, the process that owns it, byte
//! counters, derived throughput, and identity. Both the capture core and every
//! frontend speak in `Flow`s, so this type is the contract between them.

const std = @import("std");
const Writer = std.Io.Writer;

const identity = @import("identity.zig");
const sparkline = @import("sparkline.zig");

pub const Proto = enum(u8) {
    tcp = 0,
    udp = 1,

    pub fn label(p: Proto) []const u8 {
        return switch (p) {
            .tcp => "tcp",
            .udp => "udp",
        };
    }
};

/// Linux TCP states as exposed in `/proc/net/tcp` (the `st` column).
pub const TcpState = enum(u8) {
    none = 0,
    established = 1,
    syn_sent = 2,
    syn_recv = 3,
    fin_wait1 = 4,
    fin_wait2 = 5,
    time_wait = 6,
    close = 7,
    close_wait = 8,
    last_ack = 9,
    listen = 10,
    closing = 11,
    new_syn_recv = 12,
    _,

    pub fn label(s: TcpState) []const u8 {
        return switch (s) {
            .none => "-",
            .established => "ESTAB",
            .syn_sent => "SYN_SENT",
            .syn_recv => "SYN_RECV",
            .fin_wait1 => "FIN_WAIT1",
            .fin_wait2 => "FIN_WAIT2",
            .time_wait => "TIME_WAIT",
            .close => "CLOSE",
            .close_wait => "CLOSE_WAIT",
            .last_ack => "LAST_ACK",
            .listen => "LISTEN",
            .closing => "CLOSING",
            .new_syn_recv => "SYN_RECV2",
            _ => "?",
        };
    }
};

/// A short, inline, fixed-capacity string (no allocation). `N` must be <= 255.
pub fn Str(comptime N: usize) type {
    return struct {
        const Self = @This();
        comptime {
            if (N > 255) @compileError("Str capacity must fit in u8");
        }
        buf: [N]u8 = undefined,
        len: u8 = 0,

        pub fn set(self: *Self, s: []const u8) void {
            const n: u8 = @intCast(@min(s.len, N));
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn from(s: []const u8) Self {
            var r: Self = .{};
            r.set(s);
            return r;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// An IP address, always stored as 16 bytes (IPv4 lives in the first 4).
pub const Addr = struct {
    bytes: [16]u8 = [_]u8{0} ** 16,
    is_v6: bool = false,

    /// `raw` is the address in network byte order (as in `/proc` after byte-swap fixups).
    pub fn v4(raw: [4]u8) Addr {
        var a: Addr = .{ .is_v6 = false };
        @memcpy(a.bytes[0..4], &raw);
        return a;
    }

    pub fn v6(raw: [16]u8) Addr {
        return .{ .bytes = raw, .is_v6 = true };
    }

    pub fn isLoopback(a: Addr) bool {
        if (a.is_v6) {
            // ::1
            for (a.bytes[0..15]) |b| if (b != 0) return false;
            return a.bytes[15] == 1;
        }
        return a.bytes[0] == 127;
    }

    pub fn isUnspecified(a: Addr) bool {
        for (a.bytes[0..if (a.is_v6) 16 else 4]) |b| if (b != 0) return false;
        return true;
    }

    /// RFC1918 / link-local / ULA — "on my own network", not the public internet.
    pub fn isPrivate(a: Addr) bool {
        if (a.is_v6) {
            const hi = a.bytes[0];
            if (hi & 0xfe == 0xfc) return true; // fc00::/7 ULA
            if (hi == 0xfe and (a.bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
            return false;
        }
        return switch (a.bytes[0]) {
            10 => true,
            127 => true,
            169 => a.bytes[1] == 254, // link-local 169.254/16
            172 => a.bytes[1] >= 16 and a.bytes[1] <= 31,
            192 => a.bytes[1] == 168,
            else => false,
        };
    }

    /// RFC6598 shared address space, 100.64.0.0/10 — carrier-grade NAT *and* the range
    /// overlay networks (Tailscale, ZeroTier-style) hand out. Not publicly routable, so
    /// a listener bound here is reachable from a network you're on, never "the internet".
    /// A false red badge teaches the user to distrust the risk language (truth first).
    pub fn isCgnat(a: Addr) bool {
        if (a.is_v6) return false;
        return a.bytes[0] == 100 and a.bytes[1] >= 64 and a.bytes[1] <= 127;
    }

    pub fn isMulticast(a: Addr) bool {
        if (a.is_v6) return a.bytes[0] == 0xff;
        return a.bytes[0] >= 224 and a.bytes[0] <= 239;
    }

    pub fn write(a: Addr, w: *Writer) Writer.Error!void {
        if (!a.is_v6) {
            try w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] });
            return;
        }
        // IPv6 with a single longest-zero-run "::" compression.
        var groups: [8]u16 = undefined;
        for (0..8) |i| groups[i] = (@as(u16, a.bytes[i * 2]) << 8) | a.bytes[i * 2 + 1];

        var best_start: usize = 0;
        var best_len: usize = 0;
        var i: usize = 0;
        while (i < 8) {
            if (groups[i] != 0) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < 8 and groups[j] == 0) j += 1;
            if (j - i > best_len) {
                best_start = i;
                best_len = j - i;
            }
            i = j;
        }
        if (best_len < 2) best_len = 0; // only compress runs of 2+

        if (best_len == 0) {
            for (groups, 0..) |g, gi| {
                if (gi != 0) try w.writeByte(':');
                try w.print("{x}", .{g});
            }
            return;
        }
        // left segment, "::", right segment
        for (groups[0..best_start], 0..) |g, gi| {
            if (gi != 0) try w.writeByte(':');
            try w.print("{x}", .{g});
        }
        try w.writeAll("::");
        const rest = best_start + best_len;
        for (groups[rest..], 0..) |g, gi| {
            if (gi != 0) try w.writeByte(':');
            try w.print("{x}", .{g});
        }
    }

    /// Format into `buf`, returning the slice. Convenience for non-Writer call sites.
    pub fn fmt(a: Addr, buf: []u8) []const u8 {
        var w = Writer.fixed(buf);
        a.write(&w) catch {};
        return w.buffered();
    }
};

/// The identity of a conversation — what we hash and dedupe on.
pub const FlowKey = struct {
    proto: Proto,
    local: Addr,
    local_port: u16,
    remote: Addr,
    remote_port: u16,
};

/// What a user-authored act (a Greeting, a Rule) or a Focus is *about*. A tagged union so
/// the target's kind stays explicit on the wire and in the UI — never one ambiguous key.
/// Lives here (the leaf data layer) rather than in ontology.zig so both the act ontology
/// and `focus.zig` can name it without an import cycle.
pub const EntityKey = union(enum(u8)) {
    host: Addr,
    app: Str(64), // app/comm name (exe-path identity arrives with M3 enrichment)
    asn: u32,
};

/// One conversation, as the view-model sees it.
pub const Flow = struct {
    key: FlowKey,
    state: TcpState = .none,
    category: identity.Category = .unknown,

    pid: u32 = 0, // 0 = unattributed (root/other-user/kernel)
    uid: u32 = 0,
    inode: u64 = 0,
    comm: Str(16) = .{},
    exe: Str(255) = .{},
    ppid: u32 = 0, // parent pid — "what launched this?"; 0 = unknown
    pcomm: Str(16) = .{}, // parent comm ("steam", "systemd", ...)

    // Remote identity (V1 S1) — filled by the enrichment post-pass; empty = unknown.
    remote_name: Str(128) = .{}, // hostname: rDNS today, SNI/passive-DNS upgrade it (S3)
    asn: u32 = 0, // autonomous system number; 0 = unknown
    as_org: Str(64) = .{}, // AS organization ("CLOUDFLARENET", "GOOGLE", ...)
    country: [2]u8 = .{ 0, 0 }, // ISO 3166-1 alpha-2; zeroes = unknown

    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_rate: u32 = 0, // bytes/sec, derived between ticks
    tx_rate: u32 = 0,
    rtt_us: u32 = 0, // smoothed RTT from inet_diag (TCP only)

    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    fresh: bool = false, // first-seen highlight (amber until greeted)

    rates: sparkline.RateRing = .{}, // recent total throughput, for the sparkline

    pub fn attributed(f: *const Flow) bool {
        return f.pid != 0;
    }

    pub fn isListen(f: *const Flow) bool {
        return f.state == .listen;
    }

    pub fn throughput(f: *const Flow) u64 {
        return @as(u64, f.rx_rate) + f.tx_rate;
    }

    /// A display name: the process comm, else the proto.
    pub fn name(f: *const Flow) []const u8 {
        return if (f.comm.len > 0) f.comm.slice() else f.key.proto.label();
    }

    /// The well-known service this flow speaks — named even when unattributed (the
    /// `?`-flow answer, STATE.md). A pure derivation, so renderers never diverge.
    pub fn service(f: *const Flow) identity.Service {
        return identity.service(f.key, f.state);
    }

    /// Attack-surface exposure for a listener (`.none` for non-listeners).
    pub fn exposure(f: *const Flow) identity.Exposure {
        return identity.exposure(f.key, f.state);
    }

    /// A known service we couldn't attribute to a PID — legible, not a `?` dead-end.
    /// (sshd / cups / systemd-resolved / nginx are the security-relevant cases.)
    pub fn isUnattributedDaemon(f: *const Flow) bool {
        return !f.attributed() and f.service() != .unknown;
    }

    /// The remote's best human name: the enriched hostname when known, else the bare
    /// address formatted into `buf`. One derivation, so renderers never diverge.
    pub fn remoteDisplay(f: *const Flow, buf: []u8) []const u8 {
        if (f.remote_name.len > 0) return f.remote_name.slice();
        return f.key.remote.fmt(buf);
    }

    /// The ISO country code, or null while unknown.
    pub fn countryCode(f: *const Flow) ?[]const u8 {
        if (f.country[0] == 0) return null;
        return &f.country;
    }

    /// "Who is that, in one glance": `AS-org · CC`, whichever parts are known
    /// ("·" while neither is). One derivation shared by every renderer.
    pub fn whoDisplay(f: *const Flow, buf: []u8) []const u8 {
        var w = Writer.fixed(buf);
        const org = f.as_org.slice();
        if (org.len > 0) w.writeAll(org) catch {};
        if (f.countryCode()) |cc| {
            if (org.len > 0) w.writeAll(" · ") catch {};
            w.writeAll(cc) catch {};
        }
        if (w.buffered().len == 0) return "·";
        return w.buffered();
    }
};

test "addr classification" {
    const t = std.testing;
    try t.expect(Addr.v4(.{ 127, 0, 0, 1 }).isLoopback());
    try t.expect(Addr.v4(.{ 192, 168, 1, 9 }).isPrivate());
    try t.expect(Addr.v4(.{ 10, 0, 0, 5 }).isPrivate());
    try t.expect(!Addr.v4(.{ 8, 8, 8, 8 }).isPrivate());
    try t.expect(Addr.v4(.{ 224, 0, 0, 251 }).isMulticast());
    try t.expect(Addr.v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }).isLoopback());
    // RFC6598 shared space (CGNAT / Tailscale-style overlays): not private, but never "internet"
    try t.expect(Addr.v4(.{ 100, 64, 0, 1 }).isCgnat());
    try t.expect(Addr.v4(.{ 100, 114, 165, 77 }).isCgnat()); // a live Tailscale addr shape
    try t.expect(Addr.v4(.{ 100, 127, 255, 255 }).isCgnat()); // top of the /10
    try t.expect(!Addr.v4(.{ 100, 63, 255, 255 }).isCgnat()); // below the /10
    try t.expect(!Addr.v4(.{ 100, 128, 0, 0 }).isCgnat()); // above the /10
    try t.expect(!Addr.v4(.{ 100, 64, 0, 1 }).isPrivate()); // cgnat is its own class
}

test "unattributed daemon flows stay legible (the ? answer)" {
    const t = std.testing;
    // a DNS query we can't pin to a PID (systemd-resolved) — still a known daemon
    var dns: Flow = .{ .key = .{ .proto = .udp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 40000, .remote = Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 53 } };
    dns.state = .established;
    dns.pid = 0;
    try t.expect(dns.isUnattributedDaemon());
    try t.expectEqual(identity.Service.dns, dns.service());

    // a CUPS listener bound to all interfaces — part of the attack surface
    var cups: Flow = .{ .key = .{ .proto = .tcp, .local = Addr.v4(.{ 0, 0, 0, 0 }), .local_port = 631, .remote = Addr.v4(.{ 0, 0, 0, 0 }), .remote_port = 0 } };
    cups.state = .listen;
    try t.expectEqual(identity.Service.ipp, cups.service());
    try t.expectEqual(identity.Exposure.network, cups.exposure());

    // an attributed flow is not an "unattributed daemon"
    var web: Flow = .{ .key = .{ .proto = .tcp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 50000, .remote = Addr.v4(.{ 140, 82, 121, 4 }), .remote_port = 443 } };
    web.state = .established;
    web.pid = 1234;
    try t.expect(!web.isUnattributedDaemon());
}

test "ipv6 formatting with compression" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("::1", Addr.v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }).fmt(&buf));
    try t.expectEqualStrings("fe80::1", Addr.v6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }).fmt(&buf));
    try t.expectEqualStrings("1.2.3.4", Addr.v4(.{ 1, 2, 3, 4 }).fmt(&buf));
}
