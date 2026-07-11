//! SessionState — the single source of truth for *user-authored view state*.
//!
//! The architecture's headline claim is parity by construction: every renderer draws
//! the same view-model. M1/M2 proved that for *captured* state (the `FlowTable`). But
//! the moment a user *toggles* something — switches profile, turns a lens on — that
//! choice is also state, and if each frontend kept its own private copy the two UIs
//! would silently diverge at the user-state layer (Nexus critique v3 §4 "Seam C": the
//! GTK frontend forks its own cache and parity fractures *silently*). This type is the
//! fix: one place the active profile + lens set live, one `apply()` both renderers call,
//! so a TUI and a GTK window fed the same `user_state` frames hold byte-identical view
//! state. The anti-fork, made a type.
//!
//! Direction of truth (DECISIONS D22): not every `user_state` change is *shared*.
//!   * `profile` / `lens_toggle` are **view-local** — your "security" glance in the TUI
//!     must not hijack the GTK window. They live here, per renderer (per surveyor
//!     connection on the daemon side). They still travel the `user_state` frame so there
//!     is one write path and surveyor can key Reading-cadence off the active profile
//!     (D19) at M3 — but they are scoped to the connection, never broadcast.
//!   * `greeting` / `rule` are **shared truth** — surveyor-owned, persisted (D20 sqlite),
//!     broadcast to every client. Those do NOT live in SessionState; `apply` reports them
//!     as "not mine" so the caller routes them to the shared store. That store lands with
//!     the Greeting implementation at M3; the seam is here now.

const std = @import("std");
const lens = @import("lens.zig");
const ontology = @import("ontology.zig");
const focusmod = @import("focus.zig");

/// The user-authored, view-local state a single renderer (or surveyor connection) holds.
/// Initialised from a profile; individual lenses may then deviate from that bundle.
pub const SessionState = struct {
    profile: lens.Profile = .calm,
    /// The active lens set. Starts as `profile.lenses()`; a `lens_toggle` deviates it.
    lenses: lens.Set = lens.Profile.calm.lenses(),
    /// The cursor this view is holding (focus.zig, R1). A *solo* (`view`-scoped) focus lives
    /// here, per renderer; a *shared* focus is session truth surveyor will broadcast (the
    /// next-session half — see `apply`). Defaults to the calm orbit establishing shot.
    focus: focusmod.Focus = .{},

    pub fn init(profile: lens.Profile) SessionState {
        return .{ .profile = profile, .lenses = profile.lenses() };
    }

    /// The lenses a renderer should draw right now (profile defaults ∪ user toggles).
    pub fn activeLenses(self: SessionState) lens.Set {
        return self.lenses;
    }

    /// Switch to a named profile. A profile is a *fresh bundle*, so this resets lens
    /// deviations — "show me the security view" means its lenses, not last view's tweaks.
    pub fn setProfile(self: *SessionState, p: lens.Profile) void {
        self.profile = p;
        self.lenses = p.lenses();
    }

    /// Force one lens on/off, deviating from the profile default. The toggle carries the
    /// *absolute* desired state (not a flip), so applying the same frame twice is
    /// idempotent — optimistic-local-apply + surveyor-echo can't double-toggle.
    pub fn toggleLens(self: *SessionState, l: lens.Lens, on: bool) void {
        if (on) self.lenses.insert(l) else self.lenses.remove(l);
    }

    /// Set the cursor (focus.zig, R1). The toggle carries the *absolute* desired focus, so
    /// applying the same frame twice is idempotent (optimistic-local-apply + surveyor-echo
    /// can't double-move).
    pub fn setFocus(self: *SessionState, f: focusmod.Focus) void {
        self.focus = f;
    }

    /// Fold a `user_state` change in. Returns true if it altered this renderer's
    /// session (so the caller redraws); false for changes that are **persisted shared
    /// truth**, not view state:
    ///   * `.greeting` — surveyor-owned, persisted (D22).
    /// Focus — solo or shared — always folds: a renderer holds whatever cursor it was
    /// told about. *Routing* (does this focus move only my view, or the session cursor
    /// every observer follows?) is not a renderer decision — it is `atlas.route`, made
    /// once in surveyor. By the time a shared focus reaches a renderer it is already
    /// session truth, and the renderer's job is simply to show it (F4: the broadcast
    /// only co-observes if the windows actually follow it).
    pub fn apply(self: *SessionState, us: ontology.UserState) bool {
        switch (us) {
            .profile => |p| self.setProfile(p),
            .lens_toggle => |lt| self.toggleLens(lt.lens, lt.on),
            .focus => |f| self.setFocus(f),
            .greeting => return false, // shared truth — not a view-local session change
        }
        return true;
    }

    /// Cycle to the next profile (the one-key "p" interaction in both frontends).
    pub fn nextProfile(self: *SessionState) void {
        self.setProfile(switch (self.profile) {
            .calm => .nerd,
            .nerd => .security,
            .security => .resource,
            .resource => .calm,
        });
    }

    /// Does lens `l`'s active state deviate from this session's bare profile default?
    /// Surveyor uses this to reconstruct a session on the wire: send the `.profile`
    /// frame, then a `.lens_toggle` only for the lenses that differ — the minimal set of
    /// `user_state` frames that rebuild this exact session for a connecting client.
    pub fn lensOverridden(self: SessionState, l: lens.Lens) bool {
        return self.lenses.contains(l) != self.profile.lenses().contains(l);
    }

    pub fn eql(self: SessionState, other: SessionState) bool {
        return self.profile == other.profile and self.lenses.eql(other.lenses) and self.focus.eql(other.focus);
    }
};

// ---- tests ------------------------------------------------------------------

test "a fresh session is its profile's lens bundle" {
    const t = std.testing;
    const s = SessionState.init(.calm);
    try t.expectEqual(lens.Profile.calm, s.profile);
    try t.expect(s.activeLenses().eql(lens.Profile.calm.lenses()));
    try t.expect(s.activeLenses().contains(.identity));
    try t.expect(!s.activeLenses().contains(.endpoint)); // calm hides it
}

test "apply: profile switch, lens toggle, and the cursor are renderer state" {
    const t = std.testing;
    var s = SessionState.init(.calm);

    // a profile switch is a view-local change
    try t.expect(s.apply(.{ .profile = .nerd }));
    try t.expectEqual(lens.Profile.nerd, s.profile);
    try t.expect(s.activeLenses().contains(.endpoint)); // nerd shows it

    // a lens toggle deviates from the bundle
    try t.expect(s.apply(.{ .lens_toggle = .{ .lens = .endpoint, .on = false } }));
    try t.expect(!s.activeLenses().contains(.endpoint));
    try t.expect(s.lensOverridden(.endpoint)); // now differs from nerd's default

    // a greeting is NOT a view-local session change (D22: shared truth)
    const g: ontology.Greeting = .{ .key = .{ .asn = 13335 }, .state = .greeted };
    try t.expect(!s.apply(.{ .greeting = g }));

    // a broadcast shared focus folds in — the window *follows* the session cursor (F4)
    try t.expect(s.apply(.{ .focus = .{ .shared = true } }));
    try t.expect(s.focus.shared);
}

test "toggling is idempotent (absolute on/off, not a flip)" {
    const t = std.testing;
    var s = SessionState.init(.security);
    const before = s.activeLenses();
    s.toggleLens(.system, true);
    s.toggleLens(.system, true); // same frame twice — optimistic apply + echo
    try t.expect(s.activeLenses().contains(.system));
    s.toggleLens(.system, false);
    try t.expect(s.activeLenses().eql(before) or !s.activeLenses().contains(.system));
}

test "switching profile clears prior lens deviations" {
    const t = std.testing;
    var s = SessionState.init(.calm);
    s.toggleLens(.system, true);
    try t.expect(s.lensOverridden(.system));
    s.setProfile(.nerd); // a fresh bundle
    try t.expect(!s.lensOverridden(.system)); // deviation gone
    try t.expect(s.activeLenses().eql(lens.Profile.nerd.lenses()));
}

test "a session reconstructs from its profile + overridden-lens sync frames (inherit-on-connect)" {
    const t = std.testing;
    // an authoritative session with deviations from its profile bundle
    var src = SessionState.init(.security);
    src.toggleLens(.system, true); // security doesn't include system
    src.toggleLens(.endpoint, false); // security does include endpoint

    // replay exactly what surveyor sends a connecting client (D22 inherit-on-connect):
    // the `.profile` base, then a `.lens_toggle` for each overridden lens — nothing more.
    var dst = SessionState{};
    _ = dst.apply(.{ .profile = src.profile });
    inline for (std.enums.values(lens.Lens)) |l| {
        if (src.lensOverridden(l))
            _ = dst.apply(.{ .lens_toggle = .{ .lens = l, .on = src.lenses.contains(l) } });
    }

    try t.expect(src.eql(dst)); // the client holds byte-identical view state — no fork
}

test "lensOverridden marks exactly the wire delta a client must replay" {
    const t = std.testing;
    var s = SessionState.init(.nerd);
    // no deviations yet → nothing overridden
    inline for (std.enums.values(lens.Lens)) |l| try t.expect(!s.lensOverridden(l));
    // deviate two lenses
    s.toggleLens(.system, true); // nerd doesn't include system → override on
    s.toggleLens(.endpoint, false); // nerd includes endpoint → override off
    try t.expect(s.lensOverridden(.system));
    try t.expect(s.lensOverridden(.endpoint));
    try t.expect(!s.lensOverridden(.identity)); // still at the profile default
}
