//! The live flow table — the in-memory heart of the view-model.
//!
//! Two sides speak to it:
//!   * the capture core calls `observe()` with raw per-tick samples; the table
//!     derives throughput, freshness, and category, and detects closed flows.
//!   * a frontend consuming IPC calls `apply()` with pre-derived `Flow` frames.
//! Either way, rendering reads the same sorted snapshot — parity by construction.

const std = @import("std");

const flow = @import("flow.zig");
const identity = @import("identity.zig");
const Flow = flow.Flow;
const FlowKey = flow.FlowKey;

const max_u32 = std.math.maxInt(u32);

/// A raw observation from the capture core for one socket this tick.
pub const Observation = struct {
    key: FlowKey,
    state: flow.TcpState = .none,
    pid: u32 = 0,
    uid: u32 = 0,
    inode: u64 = 0,
    comm: []const u8 = "",
    exe: []const u8 = "",
    ppid: u32 = 0,
    pcomm: []const u8 = "",
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rtt_us: u32 = 0,
};

pub const FlowTable = struct {
    const Entry = struct {
        flow: Flow,
        last_gen: u32,
    };
    const Map = std.AutoHashMapUnmanaged(FlowKey, Entry);

    gpa: std.mem.Allocator,
    map: Map = .empty,
    gen: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) FlowTable {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FlowTable) void {
        self.map.deinit(self.gpa);
    }

    pub fn count(self: *const FlowTable) usize {
        return self.map.count();
    }

    /// Start a capture cycle; flows not re-observed before `collectClosed` are gone.
    pub fn beginCycle(self: *FlowTable) void {
        self.gen +%= 1;
    }

    /// Capture side: fold one sample in, deriving rates/freshness/category.
    pub fn observe(self: *FlowTable, obs: Observation, now_ms: i64) !void {
        const gop = try self.map.getOrPut(self.gpa, obs.key);
        if (!gop.found_existing) {
            var f = Flow{ .key = obs.key };
            f.state = obs.state;
            f.pid = obs.pid;
            f.uid = obs.uid;
            f.inode = obs.inode;
            f.comm.set(obs.comm);
            f.exe.set(obs.exe);
            f.ppid = obs.ppid;
            f.pcomm.set(obs.pcomm);
            f.rx_bytes = obs.rx_bytes;
            f.tx_bytes = obs.tx_bytes;
            f.rtt_us = obs.rtt_us;
            f.first_seen_ms = now_ms;
            f.last_seen_ms = now_ms;
            f.fresh = true;
            f.category = identity.classify(obs.key, obs.state);
            f.rates.push(0);
            gop.value_ptr.* = .{ .flow = f, .last_gen = self.gen };
            return;
        }

        const e = gop.value_ptr;
        const f = &e.flow;
        const dt_ms = now_ms - f.last_seen_ms;
        // Counters: only a source that HAS byte counters may move them (inet_diag for
        // TCP, the eBPF udp map for UDP). A counter-less observation of the same key —
        // hybrid capture folds several sources per tick (S3) — must not regress bytes
        // to zero. Real counters are monotonic per socket, so nonzero ⇒ authoritative.
        if (obs.rx_bytes != 0 or obs.tx_bytes != 0) {
            if (dt_ms > 0) {
                const d_rx = obs.rx_bytes -| f.rx_bytes;
                const d_tx = obs.tx_bytes -| f.tx_bytes;
                f.rx_rate = @intCast(@min(max_u32, d_rx * 1000 / @as(u64, @intCast(dt_ms))));
                f.tx_rate = @intCast(@min(max_u32, d_tx * 1000 / @as(u64, @intCast(dt_ms))));
            }
            f.rx_bytes = @max(f.rx_bytes, obs.rx_bytes);
            f.tx_bytes = @max(f.tx_bytes, obs.tx_bytes);
        }
        // One sparkline sample per tick, not per source: dt 0 = a same-tick re-observe.
        if (dt_ms > 0) f.rates.push(@intCast(@min(max_u32, f.throughput())));
        f.state = obs.state;
        f.category = identity.classify(obs.key, obs.state);
        if (obs.rtt_us != 0) f.rtt_us = obs.rtt_us;
        f.last_seen_ms = now_ms;
        f.fresh = false;
        // Late attribution: a socket that was a `?` may now resolve to a PID.
        if (f.pid == 0 and obs.pid != 0) {
            f.pid = obs.pid;
            f.uid = obs.uid;
            f.inode = obs.inode;
            f.comm.set(obs.comm);
            f.exe.set(obs.exe);
            f.ppid = obs.ppid;
            f.pcomm.set(obs.pcomm);
        }
        e.last_gen = self.gen;
    }

    /// Capture side: append keys not seen this cycle and drop them. Caller emits closes.
    pub fn collectClosed(self: *FlowTable, out: *std.ArrayList(FlowKey)) !void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_gen != self.gen) try out.append(self.gpa, kv.key_ptr.*);
        }
        for (out.items) |k| _ = self.map.remove(k);
    }

    /// Consumer side: store a flow received over IPC, preserving local sparkline history.
    pub fn apply(self: *FlowTable, f: Flow) !void {
        const gop = try self.map.getOrPut(self.gpa, f.key);
        const sample: u32 = @intCast(@min(max_u32, f.throughput()));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .flow = f, .last_gen = self.gen };
            gop.value_ptr.flow.rates = .{};
            gop.value_ptr.flow.rates.push(sample);
        } else {
            const ring = gop.value_ptr.flow.rates;
            gop.value_ptr.flow = f;
            gop.value_ptr.flow.rates = ring;
            gop.value_ptr.flow.rates.push(sample);
            gop.value_ptr.last_gen = self.gen;
        }
    }

    pub fn remove(self: *FlowTable, key: FlowKey) void {
        _ = self.map.remove(key);
    }

    fn moreTraffic(_: void, a: *Flow, b: *Flow) bool {
        if (a.throughput() != b.throughput()) return a.throughput() > b.throughput();
        const a_bytes = a.rx_bytes + a.tx_bytes;
        const b_bytes = b.rx_bytes + b.tx_bytes;
        if (a_bytes != b_bytes) return a_bytes > b_bytes;
        return a.key.remote_port < b.key.remote_port;
    }

    /// Return live flows sorted by current throughput (busiest first). Caller frees.
    pub fn snapshot(self: *FlowTable, gpa: std.mem.Allocator) ![]*Flow {
        var list: std.ArrayList(*Flow) = .empty;
        errdefer list.deinit(gpa);
        try list.ensureTotalCapacity(gpa, self.map.count());
        var it = self.map.iterator();
        while (it.next()) |kv| list.appendAssumeCapacity(&kv.value_ptr.flow);
        const items = try list.toOwnedSlice(gpa);
        std.sort.block(*Flow, items, {}, moreTraffic);
        return items;
    }
};

test "observe derives rates and freshness" {
    const t = std.testing;
    var tbl = FlowTable.init(t.allocator);
    defer tbl.deinit();

    const key: FlowKey = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 44330,
        .remote = flow.Addr.v4(.{ 140, 82, 121, 4 }),
        .remote_port = 443,
    };

    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 1, .comm = "chrome", .rx_bytes = 0, .tx_bytes = 0 }, 1000);
    {
        const snap = try tbl.snapshot(t.allocator);
        defer t.allocator.free(snap);
        try t.expectEqual(@as(usize, 1), snap.len);
        try t.expect(snap[0].fresh);
        try t.expectEqual(identity.Category.web, snap[0].category);
    }

    // one second later, 10 KB received -> ~10 KB/s
    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 1, .comm = "chrome", .rx_bytes = 10_000, .tx_bytes = 0 }, 2000);
    {
        const snap = try tbl.snapshot(t.allocator);
        defer t.allocator.free(snap);
        try t.expect(!snap[0].fresh);
        try t.expectEqual(@as(u32, 10_000), snap[0].rx_rate);
    }
}

test "late attribution fills a previously unknown pid" {
    const t = std.testing;
    var tbl = FlowTable.init(t.allocator);
    defer tbl.deinit();
    const key: FlowKey = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 22,
        .remote = flow.Addr.v4(.{ 10, 0, 0, 5 }),
        .remote_port = 51000,
    };
    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 0 }, 1000);
    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 99, .comm = "sshd" }, 2000);
    const snap = try tbl.snapshot(t.allocator);
    defer t.allocator.free(snap);
    try t.expectEqual(@as(u32, 99), snap[0].pid);
    try t.expectEqualStrings("sshd", snap[0].comm.slice());
}

test "hybrid fusion: a counter-less same-tick observation neither regresses bytes nor double-samples" {
    const t = std.testing;
    var tbl = FlowTable.init(t.allocator);
    defer tbl.deinit();
    const key: FlowKey = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 44330,
        .remote = flow.Addr.v4(.{ 140, 82, 121, 4 }),
        .remote_port = 443,
    };

    // tick 1: diag sees bytes; then an eBPF event for the same key, same tick, no bytes
    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 7, .rx_bytes = 1000, .tx_bytes = 500, .rtt_us = 20_000 }, 1000);
    try tbl.observe(.{ .key = key, .state = .established, .pid = 7 }, 1000);
    {
        const snap = try tbl.snapshot(t.allocator);
        defer t.allocator.free(snap);
        try t.expectEqual(@as(u64, 1000), snap[0].rx_bytes); // not regressed to 0
        try t.expectEqual(@as(u32, 20_000), snap[0].rtt_us); // rtt kept too
    }

    // tick 2: diag advances the counters — rates derive across the full tick
    tbl.beginCycle();
    try tbl.observe(.{ .key = key, .state = .established, .pid = 7, .rx_bytes = 11_000, .tx_bytes = 500 }, 2000);
    {
        const snap = try tbl.snapshot(t.allocator);
        defer t.allocator.free(snap);
        try t.expectEqual(@as(u32, 10_000), snap[0].rx_rate);
    }
}

test "closed flows are swept" {
    const t = std.testing;
    var tbl = FlowTable.init(t.allocator);
    defer tbl.deinit();
    const key: FlowKey = .{
        .proto = .udp,
        .local = flow.Addr.v4(.{ 0, 0, 0, 0 }),
        .local_port = 68,
        .remote = flow.Addr.v4(.{ 0, 0, 0, 0 }),
        .remote_port = 67,
    };
    tbl.beginCycle();
    try tbl.observe(.{ .key = key }, 1000);
    tbl.beginCycle(); // a cycle with no observation of `key`
    var closed: std.ArrayList(FlowKey) = .empty;
    defer closed.deinit(t.allocator);
    try tbl.collectClosed(&closed);
    try t.expectEqual(@as(usize, 1), closed.items.len);
    try t.expectEqual(@as(usize, 0), tbl.count());
}
