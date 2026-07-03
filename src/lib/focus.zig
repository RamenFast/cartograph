//! Focus — the shared cursor: *what is being attended to, and at what altitude* (RESEARCH.md
//! R1). The north star is "human talking to their AI looking at **the screen**, every step"; a
//! screen you point at needs a thing-being-pointed-at that is **shared, typed, and rendered at
//! equal fidelity to every observer** — the human's GTK/TUI *and* the agent's JSON. So focus is
//! not a renderer's private selection: it is first-class view-model state, carried on the same
//! `user_state` parity frame as profile/lens (session.zig, D22), so the human's window and the
//! agent watching the NDJSON stream point at the *same* place. UI/UX principles transfer; only
//! the rendering differs (Ben, 2026-06-19).
//!
//! Two things compose here (kept separate on purpose):
//!   * **altitude** — the continuous-zoom level of detail (VISION orbit→region→street→ground).
//!     The altitude *is* the detail; there are no mode switches.
//!   * **target** — the specific thing in view, typed by altitude (machine / entity / flow).
//!
//! `shared` is the seam to **scope.session** (D23): a `view`-scoped focus is *my* cursor (solo
//! navigation); a `shared` focus is the *session* cursor every observer follows — the literal
//! mechanism of co-observation, and the first real consumer of the (until-now reserved) session
//! rung. Broadcast of a shared cursor to many clients is surveyor/`atlas` work (RESEARCH R1);
//! the type + seam land here now so that work extends a coherent shape instead of retrofitting.

const std = @import("std");
const flow = @import("flow.zig");

const FlowKey = flow.FlowKey;
const EntityKey = flow.EntityKey;
const Addr = flow.Addr;

/// The continuous-zoom altitude. The altitude *is* the level of detail (VISION.md).
pub const Altitude = enum(u8) {
    orbit = 0, // the whole machine at the center of its constellation
    region = 1, // one entity expanded (host / app / ASN)
    street = 2, // one flow — the life story of a single conversation
    ground = 3, // one packet (byte-level; packet addressing arrives with deep capture, M5)

    pub fn label(a: Altitude) []const u8 {
        return switch (a) {
            .orbit => "orbit",
            .region => "region",
            .street => "street",
            .ground => "ground",
        };
    }
};

/// What is in view, typed by altitude. orbit has no target (the whole box); region targets an
/// entity; street/ground target one flow. The union keeps "what kind of thing" explicit on the
/// wire and in every renderer — never a bare string both ends must agree to interpret.
pub const Target = union(enum(u8)) {
    machine, // orbit
    entity: EntityKey, // region
    flow: FlowKey, // street / ground
};

/// The shared cursor. Defaults to the calm establishing shot: the whole machine, at orbit,
/// my view only.
pub const Focus = struct {
    altitude: Altitude = .orbit,
    target: Target = .machine,
    /// view = my cursor (solo); shared = the session cursor every observer follows (R1 / D23 session).
    shared: bool = false,

    pub fn orbit() Focus {
        return .{};
    }

    /// Does the target's kind match the altitude? (orbit↔machine · region↔entity · street/ground↔flow)
    /// A renderer should never be handed "street altitude on the machine" — that's a focus bug,
    /// the spatial cousin of conflating user-authored and derived state.
    pub fn consistent(f: Focus) bool {
        return switch (f.altitude) {
            .orbit => f.target == .machine,
            .region => f.target == .entity,
            .street, .ground => f.target == .flow,
        };
    }

    pub fn eql(a: Focus, b: Focus) bool {
        if (a.altitude != b.altitude or a.shared != b.shared) return false;
        if (std.meta.activeTag(a.target) != std.meta.activeTag(b.target)) return false;
        return switch (a.target) {
            .machine => true,
            .entity => |ek| entityKeyEql(ek, b.target.entity),
            .flow => |fk| std.meta.eql(fk, b.target.flow),
        };
    }

    /// One plain-language line — the **same truth** the human's "Why" header and the agent's
    /// narration both read (different rendering, one source — the whole point of the view-model).
    /// Writes into `buf` and returns the slice.
    pub fn describe(f: Focus, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        writeDescribe(f, &w) catch {};
        return w.buffered();
    }

    fn writeDescribe(f: Focus, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (f.target) {
            .machine => try w.writeAll("the whole machine (orbit)"),
            .entity => |ek| {
                try w.print("{s}: ", .{f.altitude.label()});
                switch (ek) {
                    .host => |a| {
                        var ab: [48]u8 = undefined;
                        try w.print("host {s}", .{a.fmt(&ab)});
                    },
                    .app => |s| try w.print("app {s}", .{s.slice()}),
                    .asn => |n| try w.print("AS{d}", .{n}),
                }
            },
            .flow => |fk| {
                var lb: [48]u8 = undefined;
                var rb: [48]u8 = undefined;
                try w.print("{s}: {s} {s}->{s}", .{
                    f.altitude.label(),
                    fk.proto.label(),
                    fk.local.fmt(&lb),
                    fk.remote.fmt(&rb),
                });
            },
        }
    }
};

fn entityKeyEql(a: EntityKey, b: EntityKey) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .host => |x| std.mem.eql(u8, &x.bytes, &b.host.bytes) and x.is_v6 == b.host.is_v6,
        .app => |x| std.mem.eql(u8, x.slice(), b.app.slice()),
        .asn => |x| x == b.asn,
    };
}

test "default focus is the calm establishing shot, and it's consistent" {
    const t = std.testing;
    const f = Focus.orbit();
    try t.expectEqual(Altitude.orbit, f.altitude);
    try t.expect(f.target == .machine);
    try t.expect(!f.shared);
    try t.expect(f.consistent());
}

test "consistency catches altitude/target mismatches" {
    const t = std.testing;
    const key: FlowKey = .{ .proto = .tcp, .local = Addr.v4(.{ 1, 2, 3, 4 }), .local_port = 5, .remote = Addr.v4(.{ 6, 7, 8, 9 }), .remote_port = 443 };
    try t.expect((Focus{ .altitude = .street, .target = .{ .flow = key } }).consistent());
    try t.expect((Focus{ .altitude = .ground, .target = .{ .flow = key } }).consistent());
    try t.expect((Focus{ .altitude = .region, .target = .{ .entity = .{ .asn = 13335 } } }).consistent());
    try t.expect(!(Focus{ .altitude = .street, .target = .machine }).consistent()); // street needs a flow
    try t.expect(!(Focus{ .altitude = .region, .target = .machine }).consistent()); // region needs an entity
    try t.expect(!(Focus{ .altitude = .orbit, .target = .{ .flow = key } }).consistent()); // orbit has no target
}

test "describe renders the same line for human and agent (one source)" {
    const t = std.testing;
    var buf: [128]u8 = undefined;

    try t.expectEqualStrings("the whole machine (orbit)", Focus.orbit().describe(&buf));

    const app: Focus = .{ .altitude = .region, .target = .{ .entity = .{ .app = flow.Str(64).from("chrome") } } };
    try t.expectEqualStrings("region: app chrome", app.describe(&buf));

    const asn: Focus = .{ .altitude = .region, .target = .{ .entity = .{ .asn = 13335 } } };
    try t.expectEqualStrings("region: AS13335", asn.describe(&buf));

    const key: FlowKey = .{ .proto = .tcp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 5, .remote = Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 };
    const fl: Focus = .{ .altitude = .street, .target = .{ .flow = key } };
    try t.expectEqualStrings("street: tcp 192.168.1.9->1.1.1.1", fl.describe(&buf));
}

test "eql distinguishes altitude, target, and shared" {
    const t = std.testing;
    const a = Focus.orbit();
    var b = Focus.orbit();
    try t.expect(a.eql(b));
    b.shared = true;
    try t.expect(!a.eql(b));
    const e1: Focus = .{ .altitude = .region, .target = .{ .entity = .{ .asn = 1 } } };
    const e2: Focus = .{ .altitude = .region, .target = .{ .entity = .{ .asn = 2 } } };
    try t.expect(!e1.eql(e2));
}
