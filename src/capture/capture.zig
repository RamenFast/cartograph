//! The capture core — the (eventually privileged) producer side.
//!
//! M1 capture is unprivileged: inet_diag for byte counters + RTT (diag.zig),
//! joined to the owning process via /proc (proc.zig), folded into the shared
//! `FlowTable` view-model. M2 swaps the source for eBPF without touching the
//! table or any frontend — the seam holds.

const std = @import("std");
const cartograph = @import("cartograph");

pub const diag = @import("diag.zig");
pub const proc = @import("proc.zig");
pub const enrich = @import("enrich.zig");

const FlowTable = cartograph.FlowTable;
const Observation = cartograph.Observation;

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

pub const Capturer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    sock: diag.Diag,
    inodes: proc.InodeMap,
    records: std.ArrayList(diag.SockRecord) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Capturer {
        return .{
            .gpa = gpa,
            .io = io,
            .sock = try diag.Diag.open(),
            .inodes = proc.InodeMap.init(gpa),
        };
    }

    pub fn deinit(self: *Capturer) void {
        self.sock.close();
        self.inodes.deinit();
        self.records.deinit(self.gpa);
    }

    /// Run one capture cycle: refresh the socket list + attribution, fold into
    /// `table`. Caller drives `beginCycle`/`collectClosed` around this if it wants
    /// closed-flow detection (snapshot mode doesn't need it).
    ///
    /// NOTE: this re-scans every process's fds and re-dumps inet_diag each tick —
    /// O(procs × fds). That polling cost is *intentional* pre-eBPF. M2 replaces it
    /// with a kernel ring buffer (events, not polls); do NOT add an inode/attr cache
    /// here to "fix" the cost — eBPF obsoletes it and a cache would just rot. See M2.
    pub fn refresh(self: *Capturer, table: *FlowTable, now_ms: i64) !void {
        try proc.buildInodeMap(self.io, &self.inodes);

        self.records.clearRetainingCapacity();
        try self.sock.dumpAll(&self.records, self.gpa);

        for (self.records.items) |rec| {
            const pi: ?proc.PidInfo = if (rec.inode != 0) self.inodes.get(rec.inode) else null;
            const obs: Observation = .{
                .key = .{
                    .proto = rec.proto,
                    .local = rec.local,
                    .local_port = rec.local_port,
                    .remote = rec.remote,
                    .remote_port = rec.remote_port,
                },
                .state = @enumFromInt(rec.state),
                .pid = if (pi) |p| p.pid else 0,
                .uid = rec.uid,
                .inode = rec.inode,
                .comm = if (pi) |*p| p.commSlice() else "",
                .exe = if (pi) |*p| p.exeSlice() else "",
                .rx_bytes = rec.rx_bytes,
                .tx_bytes = rec.tx_bytes,
                .rtt_us = rec.rtt_us,
            };
            try table.observe(obs, now_ms);
        }
    }
};

test {
    // Pull the capture-layer submodule tests (diag golden frames, proc) into
    // `zig build test`, the way cartograph.zig does for the view-model.
    std.testing.refAllDecls(@This());
}
