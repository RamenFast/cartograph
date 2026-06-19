//! Scope — the reach + permanence of a user-authored change, made a design-language
//! symbol (DECISIONS D23). It is the D22 ownership ladder turned into something you can
//! *see*: where a change applies, and how long it lasts.
//!
//! Two orthogonal axes (do not conflate them — that conflation is the bug):
//!   * **scope/permanence** (this file): WHERE a change applies + HOW LONG it survives.
//!   * **danger** (DESIGN-LANGUAGE §8, the consequence tree): how much it can *hurt*.
//! Naming "mom's VPN" is `kept` (permanent) yet harmless; blocking a host is `kept` *and*
//! dangerous. Scope answers "how far does this reach"; the consequence tree answers "how
//! much should I climb down to do it." They compose; they are not the same axis.
//!
//! The glyph's visual weight escalates with blast radius, so the eye reads the reach
//! before it reads the word — hollow = transient/local, solid = committed/everywhere
//! (D14: the signifier's weight matches the action's consequence). One symbol, one
//! meaning, identical in the TUI and GTK because it comes from here, not the renderer.

const std = @import("std");
const ontology = @import("ontology.zig");

pub const Scope = enum(u8) {
    view = 0, // this window only; forgotten on close
    session = 1, // all my open windows; forgotten on surveyor restart
    kept = 2, // persisted (sqlite, D20) + shared everywhere; survives a reboot

    /// Concentric blast-radius: hollow → half → solid (the dot's fullness *is* the reach).
    pub fn glyph(s: Scope) []const u8 {
        return switch (s) {
            .view => "◌", // dotted: transient, local
            .session => "◍", // half-filled: shared across my windows
            .kept => "●", // solid: committed, remembered
        };
    }

    pub fn label(s: Scope) []const u8 {
        return switch (s) {
            .view => "this view",
            .session => "all windows",
            .kept => "remembered",
        };
    }

    /// One plain-language line of consequence — for a tooltip, or a node in the
    /// consequence tree when the action is also dangerous (DESIGN-LANGUAGE §8).
    pub fn consequence(s: Scope) []const u8 {
        return switch (s) {
            .view => "stays in this window; gone when you close it",
            .session => "all your open windows now; gone when surveyor restarts",
            .kept => "remembered across reboots and shown in every window",
        };
    }
};

/// The scope a `user_state` change travels (D22). Profile + lens toggles are view-local
/// (a viewport is not shared truth); a Greeting is `kept` (surveyor-owned, persisted).
/// `session` is the reserved middle rung — nothing promotes to it yet (the future
/// Shift-to-broadcast gesture would). Keeping this mapping here, in the view-model, means
/// the TUI and GTK can never disagree about what a given change actually does.
pub fn scopeOf(us: ontology.UserState) Scope {
    return switch (us) {
        .profile, .lens_toggle => .view,
        .greeting => .kept,
    };
}

test "scope glyphs are distinct and escalate; the mapping matches D22" {
    const t = std.testing;

    // three distinct, non-empty glyphs (no color-only meaning — D14)
    const gs = [_][]const u8{ Scope.view.glyph(), Scope.session.glyph(), Scope.kept.glyph() };
    for (gs) |g| try t.expect(g.len > 0);
    try t.expect(!std.mem.eql(u8, gs[0], gs[1]));
    try t.expect(!std.mem.eql(u8, gs[1], gs[2]));
    try t.expect(!std.mem.eql(u8, gs[0], gs[2]));

    // every rung carries a label + a consequence line
    for (std.enums.values(Scope)) |s| {
        try t.expect(s.label().len > 0);
        try t.expect(s.consequence().len > 0);
    }

    // the user_state → scope mapping is the D22 ladder: profile/lens view-local, greeting kept
    try t.expectEqual(Scope.view, scopeOf(.{ .profile = .calm }));
    try t.expectEqual(Scope.view, scopeOf(.{ .lens_toggle = .{ .lens = .risk, .on = true } }));
    try t.expectEqual(Scope.kept, scopeOf(.{ .greeting = .{ .key = .{ .asn = 13335 } } }));
}
