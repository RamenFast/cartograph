//! The act ontology — the vocabulary for what Cartograph *does* on behalf of the
//! user, ratified in DECISIONS D19 (design rationale: ONTOLOGY.md). M2 lands these
//! **thin**: the types + their categories exist and round-trip over IPC (ipc.zig),
//! so M3 (scoring), M6 (blocking), and M8 (narration) extend a coherent shape rather
//! than retrofitting one three times. Real implementations land at those milestones.
//!
//! Frame (Fi/Ti, per Ben): Cartograph presents an *accurate Fi layer over the
//! network's Ti structure*, so each noun is exactly one of —
//!   data  — `Greeting`: the Fi layer the *user authors* over an entity. Distinct
//!           from `Identity` (the entity's objective Ti structure); merging them is a
//!           Fi bug (you couldn't tell "what the net says" from "what I named it").
//!   state — `Rule`: a decision that *operates on* flows (allow/block/throttle).
//!   act   — `Reading`: a score the system *shows*; `Ruling`: an act it *took*. NOT
//!           one type — the "Verdict" smell the third-reviewer caught (critique §2.3).

const std = @import("std");
const flow = @import("flow.zig");
const lens = @import("lens.zig");
const focusmod = @import("focus.zig");

const Str = flow.Str;
const Addr = flow.Addr;
const FlowKey = flow.FlowKey;

/// What a Greeting/Rule is *about* (D19). Defined in flow.zig (the leaf data layer) so the
/// act ontology and `focus.zig` can both name it without an import cycle; re-exported here
/// because the ontology is its original home in the docs.
pub const EntityKey = flow.EntityKey;

pub const GreetState = enum(u8) { unseen = 0, greeted = 1, ignored = 2 };

/// data — a remembered entity with a user label + verdict-state. The persistence
/// seam made type (STATE.md); survives a reboot (D20 sqlite `greetings`).
pub const Greeting = struct {
    key: EntityKey,
    label: Str(64) = .{},
    state: GreetState = .unseen,
    note: Str(255) = .{},
    first_seen_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    greeted_ms: i64 = 0, // 0 = never greeted

    /// Even an *ignored* entity stays on the map (D14: no invisible state). Ignore
    /// means "I've seen it, stop glowing at me," not "hide it."
    pub fn isVisible(_: Greeting) bool {
        return true;
    }

    /// Amber until greeted — the entity-level freshness the UI glows on. Distinct
    /// from `Flow.fresh` (first-seen *this run*); this one survives reboots, which is
    /// exactly the state `Identity` cannot represent (the type test, ONTOLOGY.md).
    pub fn isAmber(g: Greeting) bool {
        return g.state == .unseen;
    }
};

pub const RuleId = u64;
pub const Verdict = enum(u8) { allow, block, throttle };
pub const RuleSource = enum(u8) { user, postcard, lens_default, onboarding };

/// state — a decision that operates on flows; visible + undoable (D14). Thin for M2;
/// XDP enforcement + the flow/country selectors arrive at M6.
pub const Rule = struct {
    id: RuleId = 0,
    verdict: Verdict = .allow,
    target: EntityKey,
    rate_bps: u32 = 0, // only meaningful when verdict == .throttle
    created_ms: i64 = 0,
    expires_ms: i64 = 0, // 0 = never
    source: RuleSource = .user,
    visible: bool = true,
};

/// act (observation) — a rendered impact/confidence score. Emitted per the cadence
/// in D19 (threshold-cross by default; every-rescore opt-in). M3 fills the
/// decomposed `reasons`.
pub const Reading = struct {
    at_ms: i64 = 0,
    flow_key: FlowKey,
    impact: u8 = 0, // 0-100
    confidence: u8 = 0, // 0-100
    lenses: lens.Set = lens.Set.initEmpty(), // active lenses = the LLM whitelist (STATE.md)
};

pub const Effect = enum(u8) { none, blocked, throttled, allowed };

/// act (action) — the firing of a Rule against a flow. The renderer shows the severed
/// link (D14). Categorically NOT a Reading: a Reading is *shown*, a Ruling is *done*.
pub const Ruling = struct {
    at_ms: i64 = 0,
    flow_key: FlowKey,
    rule_id: RuleId = 0,
    verdict: Verdict = .block,
    effect: Effect = .none,
};

/// The user-state channel (the load-bearing parity frame, critique §4 Seam C):
/// profile switches, lens toggles, and Greeting writes travel this one frame so every
/// renderer shares one source of truth instead of forking a private cache. Must exist
/// before the M4 GTK spike.
pub const LensToggle = struct { lens: lens.Lens, on: bool };
pub const UserState = union(enum(u8)) {
    profile: lens.Profile,
    lens_toggle: LensToggle,
    greeting: Greeting,
    /// The shared cursor (focus.zig, R1). Travels this same parity frame so the human's window
    /// and an agent watching the stream point at one place. Tag appended last → existing wire
    /// values (profile=0/lens_toggle=1/greeting=2) are unchanged; `focus`=3 is additive.
    focus: focusmod.Focus,
};

test "greeting carries state Identity cannot; ignored stays visible (D14)" {
    const t = std.testing;
    const greeted: Greeting = .{ .key = .{ .host = Addr.v4(.{ 192, 168, 1, 50 }) }, .label = Str(64).from("mom's VPN"), .state = .greeted };
    try t.expect(!greeted.isAmber()); // greeted → no longer amber
    try t.expect(greeted.isVisible());

    const ignored: Greeting = .{ .key = .{ .asn = 13335 }, .state = .ignored };
    try t.expect(ignored.isVisible()); // ignore is not hide
    try t.expect(!ignored.isAmber());

    const unseen: Greeting = .{ .key = .{ .app = Str(64).from("chrome") } };
    try t.expect(unseen.isAmber()); // first sight glows amber until greeted
}
