//! Atlas — the multi-observer session core (RESEARCH R1, DECISIONS D23/D24).
//!
//! "One capture core, many observers" needs a place where the *session* — the state
//! every observer holds together — actually lives. This is it. The docs called
//! `atlas/` the home of multi-observer presence; the audit (F28) found an empty
//! directory. The session core lands here in the view-model instead, where surveyor
//! (the one owner) and every frontend can link it: the routing decision for incoming
//! user acts, and the shared cursor those acts move.
//!
//! Direction of truth (D22, unchanged):
//!   * `profile` / `lens_toggle` are **view-local** — your security glance must not
//!     hijack another window. They fold into that client's `SessionState`.
//!   * a `focus` with `shared = true` is **session truth** — surveyor owns it and
//!     broadcasts it to every observer. This is the literal mechanism of
//!     co-observation: the human's click and the agent's `ctl focus` move the same
//!     cursor, and both see it move.
//!   * `greeting` / `rule` are shared *persisted* truth (M3's sqlite store); until
//!     that store exists they are recognised and honestly ignored, never misapplied.

const std = @import("std");
const focusmod = @import("focus.zig");
const ontology = @import("ontology.zig");

/// Where an incoming `user_state` frame belongs. The daemon switches on this —
/// one routing decision, made in the view-model, tested without a socket.
pub const Route = enum {
    view_local, // fold into the sending client's own SessionState, echo back to it
    shared, // fold into the SharedSession, broadcast to every observer
    store, // persisted shared truth (greetings/rules) — the M3 store's seam
};

pub fn route(us: ontology.UserState) Route {
    return switch (us) {
        .profile, .lens_toggle => .view_local,
        .focus => |f| if (f.shared) .shared else .view_local,
        .greeting => .store,
    };
}

/// The session cursor every observer follows. Owned by surveyor (the one truth
/// owner); frontends and agents *propose* moves by sending a shared focus upstream,
/// and render what the broadcast confirms.
pub const SharedSession = struct {
    focus: focusmod.Focus = .{ .shared = true },

    /// Fold a proposed shared focus in. Returns true when it changed the session
    /// (the caller then broadcasts); false makes re-sends idempotent — an echo
    /// arriving back at the daemon can't trigger a broadcast storm.
    pub fn applyFocus(self: *SharedSession, f: focusmod.Focus) bool {
        var g = f;
        g.shared = true; // session truth is shared by definition
        if (self.focus.eql(g)) return false;
        self.focus = g;
        return true;
    }

    /// Should a just-connected observer be told the cursor? (The default orbit is
    /// elided — a newcomer already starts there.)
    pub fn worthAnnouncing(self: *const SharedSession) bool {
        return !self.focus.eql(.{ .shared = true });
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;
const flow = @import("flow.zig");

test "routing: view-local acts, the shared cursor, and store-bound acts" {
    try testing.expectEqual(Route.view_local, route(.{ .profile = .nerd }));
    try testing.expectEqual(Route.view_local, route(.{ .lens_toggle = .{ .lens = .endpoint, .on = true } }));
    // a solo focus is my cursor; a shared focus is the session cursor
    try testing.expectEqual(Route.view_local, route(.{ .focus = .{} }));
    try testing.expectEqual(Route.shared, route(.{ .focus = .{ .shared = true } }));
    // greetings are persisted shared truth — recognised, routed to the store seam
    const g: ontology.Greeting = .{ .key = .{ .asn = 13335 }, .state = .greeted };
    try testing.expectEqual(Route.store, route(.{ .greeting = g }));
}

test "shared session: change detection, idempotence, and the announce rule" {
    var s = SharedSession{};
    try testing.expect(!s.worthAnnouncing()); // fresh session sits at orbit — nothing to say

    const key: flow.FlowKey = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 44330,
        .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }),
        .remote_port = 443,
    };
    const street: focusmod.Focus = .{ .altitude = .street, .target = .{ .flow = key } };

    try testing.expect(s.applyFocus(street)); // a move — broadcast
    try testing.expect(!s.applyFocus(street)); // the echo — no storm
    try testing.expect(s.focus.shared); // session truth is shared even if the sender forgot the flag
    try testing.expect(s.worthAnnouncing()); // a newcomer inherits the cursor

    try testing.expect(s.applyFocus(.{})); // back to orbit — a move again
    try testing.expect(!s.worthAnnouncing()); // and orbit is the elided default
}
