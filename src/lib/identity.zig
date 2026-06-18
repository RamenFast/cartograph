//! Identity & category — the "what is it" layer, M1 edition.
//!
//! Real enrichment (GeoIP, ASN, nDPI, SNI, logos) arrives in M3. For now we infer
//! a coarse *category* from the 5-tuple alone, which is already enough to give the
//! map its universal color+glyph fallback (VISION.md "category color + glyph").

const std = @import("std");
const flow = @import("flow.zig");

/// Fixed color meanings — semantics, never decoration (DECISIONS.md D14).
pub const Category = enum(u8) {
    unknown = 0,
    loopback = 1, // on-box, 127.0.0.0/8 or ::1
    lan = 2, // your own network (RFC1918 / link-local / ULA)
    web = 3, // http/https to the internet
    dns = 4,
    ntp = 5,
    mail = 6,
    ssh = 7,
    listen = 8, // a local listener — part of your attack surface
    multicast = 9, // mDNS/SSDP and friends
    internet = 10, // public, but uncategorised

    /// A single-glyph badge (degrades to ASCII-safe where it matters).
    pub fn glyph(c: Category) []const u8 {
        return switch (c) {
            .unknown => "·",
            .loopback => "⟲",
            .lan => "⌂",
            .web => "☁",
            .dns => "✦",
            .ntp => "⏱",
            .mail => "✉",
            .ssh => "⌘",
            .listen => "⚠",
            .multicast => "⇶",
            .internet => "🌐",
        };
    }

    /// ANSI SGR foreground color code (38;5;N truecolor-lite, 256-palette).
    pub fn ansi(c: Category) []const u8 {
        return switch (c) {
            .unknown => "\x1b[38;5;245m", // grey
            .loopback => "\x1b[38;5;110m", // soft blue
            .lan => "\x1b[38;5;114m", // green
            .web => "\x1b[38;5;75m", // sky
            .dns => "\x1b[38;5;141m", // violet
            .ntp => "\x1b[38;5;180m", // tan
            .mail => "\x1b[38;5;216m", // peach
            .ssh => "\x1b[38;5;208m", // orange
            .listen => "\x1b[38;5;203m", // alert red
            .multicast => "\x1b[38;5;108m", // muted green
            .internet => "\x1b[38;5;81m", // cyan
        };
    }

    pub fn label(c: Category) []const u8 {
        return switch (c) {
            .unknown => "unknown",
            .loopback => "loopback",
            .lan => "lan",
            .web => "web",
            .dns => "dns",
            .ntp => "ntp",
            .mail => "mail",
            .ssh => "ssh",
            .listen => "listen",
            .multicast => "multicast",
            .internet => "internet",
        };
    }
};

/// Infer a category from the 5-tuple + state. Cheap, deterministic, offline.
pub fn classify(key: flow.FlowKey, state: flow.TcpState) Category {
    if (state == .listen) return .listen;

    const r = key.remote;
    if (r.isUnspecified()) {
        // No peer yet (a fresh/closing socket); fall back to the well-known port.
        return byPort(key.local_port, key.remote_port);
    }
    if (r.isLoopback()) return .loopback;
    if (r.isMulticast()) return .multicast;

    const port_cat = byPort(key.local_port, key.remote_port);
    if (r.isPrivate()) {
        // On your own network, but still surface DNS/NTP/etc. when obvious.
        return switch (port_cat) {
            .web, .internet, .unknown => .lan,
            else => port_cat,
        };
    }
    return switch (port_cat) {
        .unknown => .internet,
        else => port_cat,
    };
}

fn byPort(local_port: u16, remote_port: u16) Category {
    // Prefer the remote (server) port; fall back to local for inbound.
    return switch (remote_port) {
        443, 80, 8080, 8443 => .web,
        53 => .dns,
        123 => .ntp,
        22 => .ssh,
        25, 465, 587, 993, 995, 110, 143 => .mail,
        else => switch (local_port) {
            53 => .dns,
            123 => .ntp,
            else => .unknown,
        },
    };
}

test "classify by tuple" {
    const t = std.testing;
    const Addr = flow.Addr;
    const mk = struct {
        fn k(remote: Addr, rp: u16) flow.FlowKey {
            return .{ .proto = .tcp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 40000, .remote = remote, .remote_port = rp };
        }
    }.k;

    try t.expectEqual(Category.web, classify(mk(Addr.v4(.{ 140, 82, 121, 4 }), 443), .established));
    try t.expectEqual(Category.dns, classify(mk(Addr.v4(.{ 1, 1, 1, 1 }), 53), .established));
    try t.expectEqual(Category.lan, classify(mk(Addr.v4(.{ 192, 168, 1, 1 }), 443), .established));
    try t.expectEqual(Category.loopback, classify(mk(Addr.v4(.{ 127, 0, 0, 1 }), 9119), .established));
    try t.expectEqual(Category.listen, classify(mk(Addr.v4(.{ 0, 0, 0, 0 }), 0), .listen));
}
