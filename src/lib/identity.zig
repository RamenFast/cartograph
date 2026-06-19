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

    /// The *same* fixed color as `ansi()`, as an `#rrggbb` hex string — the truecolor
    /// twin of each 256-palette index, for renderers that want RGB (GTK/Pango, CSS, the
    /// web view). Kept here so every frontend draws one design-language palette from the
    /// view-model, never its own (DECISIONS D14, DESIGN-LANGUAGE §6). TUI `ansi()` and
    /// GTK `hex()` are the same color by construction.
    pub fn hex(c: Category) []const u8 {
        return switch (c) {
            .unknown => "#8a8a8a", // grey (xterm 245)
            .loopback => "#87afd7", // soft blue (110)
            .lan => "#87d787", // green (114)
            .web => "#5fafff", // sky (75)
            .dns => "#af87ff", // violet (141)
            .ntp => "#d7af87", // tan (180)
            .mail => "#ffaf87", // peach (216)
            .ssh => "#ff8700", // orange (208)
            .listen => "#ff5f5f", // alert red (203)
            .multicast => "#87af87", // muted green (108)
            .internet => "#5fd7ff", // cyan (81)
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

/// The precise well-known **service** a flow speaks, inferred from ports + state and
/// **independent of process attribution**. This is libcartograph's answer to "what does
/// the user do about an unattributed (`pid==0`) flow?" (STATE.md, critique §5.3): even
/// when we can't name the *process*, we can still name the *service*, so an unattributed
/// systemd-resolved DNS query or a CUPS listener is legible — not a `?` dead-end. The
/// answer lives here (the view-model), so TUI and GTK can never diverge on it. Derived
/// purely from fields already on the wire, so it costs the IPC nothing.
///
/// (`Category` is the coarse color/glyph bucket; `Service` is the daemon-precise name.)
pub const Service = enum(u8) {
    unknown = 0,
    ssh, // 22
    dns, // 53
    dhcp, // 67/68
    http, // 80/8080
    https, // 443/8443
    ntp, // 123
    ipp, // 631 — CUPS (the recent-CVE LAN listener the mirror must not miss)
    smtp, // 25/465/587
    imap, // 143/993
    pop3, // 110/995
    mdns, // 5353
    netbios, // 137-139
    rpc, // 111
    mysql, // 3306
    postgres, // 5432
    redis, // 6379

    pub fn label(s: Service) []const u8 {
        return switch (s) {
            .unknown => "unknown",
            .ssh => "ssh",
            .dns => "dns",
            .dhcp => "dhcp",
            .http => "http",
            .https => "https",
            .ntp => "ntp",
            .ipp => "ipp",
            .smtp => "smtp",
            .imap => "imap",
            .pop3 => "pop3",
            .mdns => "mdns",
            .netbios => "netbios",
            .rpc => "rpc",
            .mysql => "mysql",
            .postgres => "postgres",
            .redis => "redis",
        };
    }
};

fn byServicePort(p: u16) Service {
    return switch (p) {
        22 => .ssh,
        53 => .dns,
        67, 68 => .dhcp,
        80, 8080 => .http,
        443, 8443 => .https,
        123 => .ntp,
        631 => .ipp,
        25, 465, 587 => .smtp,
        143, 993 => .imap,
        110, 995 => .pop3,
        5353 => .mdns,
        137, 138, 139 => .netbios,
        111 => .rpc,
        3306 => .mysql,
        5432 => .postgres,
        6379 => .redis,
        else => .unknown,
    };
}

pub fn service(key: flow.FlowKey, state: flow.TcpState) Service {
    if (state == .listen) return byServicePort(key.local_port);
    // outbound: the server port is the remote; fall back to local for inbound.
    const r = byServicePort(key.remote_port);
    return if (r != .unknown) r else byServicePort(key.local_port);
}

/// How reachable a **listener** is — the attack-surface axis of the "what can the world
/// see of me" mirror. Non-listeners have no surface of their own (`.none`).
pub const Exposure = enum(u8) {
    none = 0, // not a listener
    loopback, // 127.0.0.0/8 or ::1 — reachable only from this box (safe)
    network, // a private/LAN addr, or 0.0.0.0/:: (all interfaces) — reachable from your network
    internet, // a specific public address — reachable from the internet

    pub fn label(e: Exposure) []const u8 {
        return switch (e) {
            .none => "none",
            .loopback => "loopback",
            .network => "network",
            .internet => "internet",
        };
    }
};

pub fn exposure(key: flow.FlowKey, state: flow.TcpState) Exposure {
    if (state != .listen) return .none;
    const a = key.local;
    if (a.isLoopback()) return .loopback;
    // 0.0.0.0/:: binds every interface; we can't prove internet-routability without the
    // routing table (M3+), so the honest floor is "reachable from your network".
    if (a.isUnspecified() or a.isPrivate()) return .network;
    return .internet;
}

test "service is named even without attribution (the ? answer)" {
    const t = std.testing;
    const Addr = flow.Addr;
    const k = struct {
        fn f(local_port: u16, remote: Addr, rp: u16) flow.FlowKey {
            return .{ .proto = .tcp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = local_port, .remote = remote, .remote_port = rp };
        }
    }.f;

    // systemd-resolved forwarding DNS, unattributed — still legibly "dns"
    try t.expectEqual(Service.dns, service(k(40000, Addr.v4(.{ 1, 1, 1, 1 }), 53), .established));
    // a CUPS listener on :631 — the mirror must name it
    try t.expectEqual(Service.ipp, service(k(631, Addr.v4(.{ 0, 0, 0, 0 }), 0), .listen));
    try t.expectEqual(Service.ssh, service(k(22, Addr.v4(.{ 0, 0, 0, 0 }), 0), .listen));
    try t.expectEqual(Service.unknown, service(k(44321, Addr.v4(.{ 9, 9, 9, 9 }), 51999), .established));
}

test "exposure flags the attack surface for listeners" {
    const t = std.testing;
    const Addr = flow.Addr;
    const k = struct {
        fn f(local: Addr, lp: u16) flow.FlowKey {
            return .{ .proto = .tcp, .local = local, .local_port = lp, .remote = Addr.v4(.{ 0, 0, 0, 0 }), .remote_port = 0 };
        }
    }.f;

    try t.expectEqual(Exposure.loopback, exposure(k(Addr.v4(.{ 127, 0, 0, 1 }), 631), .listen));
    try t.expectEqual(Exposure.network, exposure(k(Addr.v4(.{ 0, 0, 0, 0 }), 631), .listen)); // all interfaces
    try t.expectEqual(Exposure.network, exposure(k(Addr.v4(.{ 192, 168, 1, 9 }), 22), .listen));
    try t.expectEqual(Exposure.internet, exposure(k(Addr.v4(.{ 203, 0, 113, 7 }), 443), .listen));
    try t.expectEqual(Exposure.none, exposure(k(Addr.v4(.{ 192, 168, 1, 9 }), 50000), .established)); // not a listener
}

test "every category has a well-formed hex twin (one palette, all renderers)" {
    const t = std.testing;
    for (std.enums.values(Category)) |c| {
        const h = c.hex();
        try t.expectEqual(@as(usize, 7), h.len); // #rrggbb
        try t.expectEqual(@as(u8, '#'), h[0]);
        for (h[1..]) |ch| try t.expect(std.ascii.isHex(ch));
        // a non-empty ansi() twin must exist for the same category (parity of the palette)
        try t.expect(c.ansi().len > 0);
    }
    // spot-check the load-bearing ones against the TUI's 256-palette indices
    try t.expectEqualStrings("#5fafff", Category.web.hex()); // 75
    try t.expectEqualStrings("#ff5f5f", Category.listen.hex()); // 203
    try t.expectEqualStrings("#af87ff", Category.dns.hex()); // 141
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
