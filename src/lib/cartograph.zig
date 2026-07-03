//! libcartograph — the frontend-agnostic view-model.
//!
//! This module is the single place where Cartograph's features live: the flow
//! model, the live flow table, the binary IPC codec, category/identity inference,
//! and the lens system. The capture core (`surveyor`) and every frontend (TUI,
//! GTK, …) link this module, so a capability can never exist in one UI but not
//! another — parity by construction (FRONTENDS.md, DECISIONS.md D9).

const std = @import("std");

pub const flow = @import("flow.zig");
pub const identity = @import("identity.zig");
pub const sparkline = @import("sparkline.zig");
pub const ipc = @import("ipc.zig");
pub const table = @import("table.zig");
pub const lens = @import("lens.zig");
pub const json = @import("json.zig");
pub const ontology = @import("ontology.zig");
pub const session = @import("session.zig");
pub const scope = @import("scope.zig");
pub const focus = @import("focus.zig");
pub const mmdb = @import("mmdb.zig");
pub const why = @import("why.zig");
pub const fmtutil = @import("fmt.zig");
pub const usock = @import("usock.zig");
pub const parity = @import("parity.zig");

// Convenience re-exports of the most-used types.
pub const Proto = flow.Proto;
pub const TcpState = flow.TcpState;
pub const Addr = flow.Addr;
pub const FlowKey = flow.FlowKey;
pub const Flow = flow.Flow;
pub const Category = identity.Category;
pub const FlowTable = table.FlowTable;
pub const Observation = table.Observation;
pub const SessionState = session.SessionState;
pub const Focus = focus.Focus;

// The formatting helpers live in fmt.zig (a leaf, so why.zig can share them);
// re-exported here so call sites keep reading `cartograph.humanBytes(...)`.
pub const writeEndpoint = fmtutil.writeEndpoint;
pub const endpoint = fmtutil.endpoint;
pub const humanBytes = fmtutil.humanBytes;
pub const humanRate = fmtutil.humanRate;

test {
    // Pull every submodule's tests into `zig build test`.
    std.testing.refAllDecls(@This());
}
