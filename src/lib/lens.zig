//! Lenses — togglable information layers (DATA-STREAMS.md).
//!
//! Calm by default, deep on demand. Lenses are computed here in the view-model,
//! never in a frontend, so the TUI and GTK render exactly the same set. M1 ships
//! the lenses we can actually populate from the /proc capture path; the catalog
//! grows as enrichment lands (GeoIP, nDPI, RTT, GPU…).

const std = @import("std");

pub const Lens = enum {
    identity, // app / comm / pid
    endpoint, // remote address (host/SNI later)
    volume, // bytes + live throughput sparkline
    classification, // category glyph
    risk, // fresh / listener / exposure badges
    system, // cross-resource (GPU/CPU) — placeholder until M8

    pub fn label(l: Lens) []const u8 {
        return switch (l) {
            .identity => "identity",
            .endpoint => "endpoint",
            .volume => "volume",
            .classification => "class",
            .risk => "risk",
            .system => "system",
        };
    }
};

/// A set of active lenses.
pub const Set = std.enums.EnumSet(Lens);

/// Named bundles you switch with one key (DATA-STREAMS.md "Profiles").
pub const Profile = enum {
    calm,
    nerd,
    security,
    resource,

    pub fn label(p: Profile) []const u8 {
        return switch (p) {
            .calm => "calm",
            .nerd => "nerd",
            .security => "security",
            .resource => "resource",
        };
    }

    pub fn lenses(p: Profile) Set {
        return switch (p) {
            .calm => Set.init(.{ .identity = true, .classification = true, .volume = true, .risk = true }),
            .nerd => Set.init(.{ .identity = true, .classification = true, .volume = true, .risk = true, .endpoint = true }),
            .security => Set.init(.{ .identity = true, .classification = true, .risk = true, .endpoint = true }),
            .resource => Set.init(.{ .identity = true, .volume = true, .classification = true, .system = true }),
        };
    }
};

test "profiles select lenses" {
    const t = std.testing;
    try t.expect(Profile.calm.lenses().contains(.identity));
    try t.expect(!Profile.calm.lenses().contains(.endpoint));
    try t.expect(Profile.nerd.lenses().contains(.endpoint));
    try t.expect(Profile.resource.lenses().contains(.system));
}
