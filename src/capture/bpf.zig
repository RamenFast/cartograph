//! The eBPF capture source — the privileged half of S3's **hybrid fusion**. inet_diag
//! stays the baseline (the existing table, TCP byte counters, RTT); this adds what
//! polling can't see: births/deaths *between* ticks, short-lived flows attributed at
//! the moment they act, UDP/QUIC byte counters, and the passive-DNS packet filter.
//! Everything folds into the same `FlowTable` through the same `Observation` seam, so
//! no frontend knows which source fed it (ARCHITECTURE.md).
//!
//! Fusion contract: this source only ever **observes** — the tick's generation sweep
//! (`table.collectClosed`) is the single eviction authority. A close event is a state
//! update; the row it marks dies at the next sweep because nothing re-observes it.
//! That is what lets a 40 ms connection be *seen*: it lands with its final state,
//! lives one visible tick, then closes properly to every consumer.
//!
//! Privilege: loading/attaching needs CAP_BPF + CAP_PERFMON (+ CAP_NET_RAW for the
//! passive-DNS tap). `init` returns an error when caps are absent, so surveyor falls
//! back to the unprivileged inet_diag source — eBPF is an upgrade, never a hard
//! requirement. The decodes are pure and unit-tested without root.

const std = @import("std");
const cartograph = @import("cartograph");

const Observation = cartograph.Observation;
const FlowKey = cartograph.FlowKey;
const FlowTable = cartograph.FlowTable;
const TcpState = cartograph.TcpState;

pub const built = true;

const AF_INET = 2;
const AF_INET6 = 10;

/// A UDP flow entry goes stale (deleted from the kernel map, row left to the sweep)
/// after this long without its counters moving.
const udp_idle_ms: i64 = 30_000;

/// The event ABI — must match `struct cg_event` in bpf/event.h byte-for-byte.
pub const CgEvent = extern struct {
    ts_ns: u64,
    pid: u32,
    uid: u32,
    kind: u8, // 0 = connect (attributed), 1 = state
    family: u8, // 2 / 10
    proto: u8, // 6 = TCP
    newstate: u8, // TCP_* — matches flow.TcpState
    sport: u16, // host order
    dport: u16, // host order
    saddr: [16]u8,
    daddr: [16]u8,
    comm: [16]u8,
};

/// The UDP counter ABI — must match `struct cg_udp_flow` in bpf/event.h.
pub const CgUdpFlow = extern struct {
    tx_bytes: u64,
    rx_bytes: u64,
    pid: u32,
    uid: u32,
    sport: u16, // host order
    dport: u16, // host order
    family: u8, // 2 / 10
    _pad: [3]u8 = @splat(0),
    saddr: [16]u8,
    daddr: [16]u8,
    comm: [16]u8,
};

comptime {
    // Guards the ABI against silent drift between the C structs and these mirrors.
    std.debug.assert(@sizeOf(CgEvent) == 72);
    std.debug.assert(@sizeOf(CgUdpFlow) == 80);
}

fn commSlice(comm: *const [16]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, comm, 0) orelse comm.len;
    return comm[0..n];
}

fn addrOf(family: u8, bytes: *const [16]u8) cartograph.Addr {
    return if (family == AF_INET6) cartograph.Addr.v6(bytes.*) else cartograph.Addr.v4(bytes[0..4].*);
}

/// Decode one ring-buffer event into the shared `Observation` the FlowTable folds in.
/// Pure: no kernel, no allocation — the unit-testable core of the eBPF path.
pub fn toObservation(ev: *const CgEvent) Observation {
    return .{
        .key = .{
            .proto = .tcp,
            .local = addrOf(ev.family, &ev.saddr),
            .local_port = ev.sport,
            .remote = addrOf(ev.family, &ev.daddr),
            .remote_port = ev.dport,
        },
        .state = @enumFromInt(ev.newstate),
        .pid = ev.pid,
        .uid = ev.uid,
        .comm = commSlice(&ev.comm),
        // TCP byte counters/RTT aren't in this hook (the state machine, not the data
        // path); inet_diag remains the TCP byte source. 0 is honest, not a guess —
        // and the fusion-safe table.observe never lets a 0 regress real counters.
    };
}

/// Decode one UDP counter-map value. Pure and unit-tested like `toObservation`.
pub fn toUdpObservation(v: *const CgUdpFlow) Observation {
    return .{
        .key = .{
            .proto = .udp,
            .local = addrOf(v.family, &v.saddr),
            .local_port = v.sport,
            .remote = addrOf(v.family, &v.daddr),
            .remote_port = v.dport,
        },
        .state = .established,
        .pid = v.pid,
        .uid = v.uid,
        .comm = commSlice(&v.comm),
        .rx_bytes = v.rx_bytes,
        .tx_bytes = v.tx_bytes,
    };
}

// ---- libbpf FFI -------------------------------------------------------------
// Opaque handles as ?*anyopaque; only the calls we use are declared. Linked via
// -lbpf (build.zig adds libbpf/elf/z + libc to the bpf module's consumers).

const RingSampleFn = *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int;

extern fn bpf_object__open_mem(buf: ?*const anyopaque, sz: usize, opts: ?*const anyopaque) ?*anyopaque;
extern fn bpf_object__load(obj: ?*anyopaque) c_int;
extern fn bpf_object__close(obj: ?*anyopaque) void;
extern fn bpf_object__find_program_by_name(obj: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn bpf_program__attach(prog: ?*anyopaque) ?*anyopaque;
extern fn bpf_program__fd(prog: ?*anyopaque) c_int;
extern fn bpf_link__destroy(link: ?*anyopaque) c_int;
extern fn bpf_object__find_map_by_name(obj: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn bpf_map__fd(map: ?*anyopaque) c_int;
extern fn ring_buffer__new(map_fd: c_int, cb: RingSampleFn, ctx: ?*anyopaque, opts: ?*const anyopaque) ?*anyopaque;
extern fn ring_buffer__poll(rb: ?*anyopaque, timeout_ms: c_int) c_int;
extern fn ring_buffer__free(rb: ?*anyopaque) void;
extern fn bpf_map_get_next_key(fd: c_int, key: ?*const anyopaque, next_key: ?*anyopaque) c_int;
extern fn bpf_map_lookup_elem(fd: c_int, key: ?*const anyopaque, value: ?*anyopaque) c_int;
extern fn bpf_map_delete_elem(fd: c_int, key: ?*const anyopaque) c_int;

/// The compiled CO-RE object, embedded so surveyor stays a single binary.
const obj_bytes: []const u8 = @embedFile("cartograph_bpf_obj");

/// The tracing programs `init` attaches (the socket filter attaches to the pdns
/// tap via setsockopt instead — it has no kernel attach point of its own).
const attach_progs = [_][:0]const u8{
    "cg_inet_sock_set_state",
    "cg_udp_sendmsg",
    "cg_udpv6_sendmsg",
    "cg_udp_recvmsg",
    "cg_udpv6_recvmsg",
};

/// eBPF capture source. `drain` observes into the table (never evicts — see the
/// fusion contract above); surveyor runs it after the inet_diag baseline each tick.
pub const BpfCapturer = struct {
    obj: *anyopaque,
    links: [attach_progs.len]?*anyopaque,
    rb: *anyopaque,
    ctx: *Ctx,
    udp_map_fd: c_int,
    /// The passive-DNS socket-filter program, for pdns.zig's AF_PACKET tap.
    dns_filter_fd: c_int,
    udp_seen: std.AutoHashMapUnmanaged(u64, UdpSeen) = .empty,
    gpa: std.mem.Allocator,

    const UdpSeen = struct {
        tx: u64,
        rx: u64,
        last_change_ms: i64,
        visited_ms: i64,
    };

    const Ctx = struct {
        gpa: std.mem.Allocator,
        table: ?*FlowTable = null,
        now_ms: i64 = 0,
        err: ?anyerror = null,
    };

    pub fn init(gpa: std.mem.Allocator) !BpfCapturer {
        const obj = bpf_object__open_mem(obj_bytes.ptr, obj_bytes.len, null) orelse return error.BpfOpen;
        errdefer bpf_object__close(obj);
        if (bpf_object__load(obj) != 0) return error.BpfLoad; // needs CAP_BPF

        var links: [attach_progs.len]?*anyopaque = @splat(null);
        errdefer for (links) |l| {
            if (l != null) _ = bpf_link__destroy(l);
        };
        for (attach_progs, 0..) |name, i| {
            const prog = bpf_object__find_program_by_name(obj, name) orelse return error.BpfProgramMissing;
            links[i] = bpf_program__attach(prog) orelse return error.BpfAttach; // needs CAP_PERFMON
        }

        const map = bpf_object__find_map_by_name(obj, "events") orelse return error.BpfMapMissing;
        const udp_map = bpf_object__find_map_by_name(obj, "udp_flows") orelse return error.BpfMapMissing;
        const dns_prog = bpf_object__find_program_by_name(obj, "cg_dns_filter") orelse return error.BpfProgramMissing;

        const ctx = try gpa.create(Ctx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{ .gpa = gpa };

        const rb = ring_buffer__new(bpf_map__fd(map), onSample, ctx, null) orelse return error.BpfRingNew;
        return .{
            .obj = obj,
            .links = links,
            .rb = rb,
            .ctx = ctx,
            .udp_map_fd = bpf_map__fd(udp_map),
            .dns_filter_fd = bpf_program__fd(dns_prog),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *BpfCapturer) void {
        ring_buffer__free(self.rb);
        for (self.links) |l| {
            if (l != null) _ = bpf_link__destroy(l);
        }
        bpf_object__close(self.obj);
        self.udp_seen.deinit(self.gpa);
        self.gpa.destroy(self.ctx);
    }

    /// Fold everything the kernel saw since last tick into `table`: the TCP state
    /// events (ring buffer) and the UDP byte counters (map walk). Observe-only —
    /// the caller's generation sweep evicts (the fusion contract).
    pub fn drain(self: *BpfCapturer, table: *FlowTable, now_ms: i64) !void {
        self.ctx.table = table;
        self.ctx.now_ms = now_ms;
        self.ctx.err = null;
        if (ring_buffer__poll(self.rb, 0) < 0) return error.BpfRingPoll; // 0 ms = non-blocking
        if (self.ctx.err) |e| return e;
        try self.drainUdp(table, now_ms);
    }

    /// Walk the kernel's UDP counter map: observe live entries, delete idle ones
    /// (their table rows then die at the sweep unless inet_diag still sees the socket).
    fn drainUdp(self: *BpfCapturer, table: *FlowTable, now_ms: i64) !void {
        var key: u64 = undefined;
        var have_key = bpf_map_get_next_key(self.udp_map_fd, null, &key) == 0;
        while (have_key) {
            var next: u64 = undefined;
            const have_next = bpf_map_get_next_key(self.udp_map_fd, &key, &next) == 0;

            var val: CgUdpFlow = undefined;
            if (bpf_map_lookup_elem(self.udp_map_fd, &key, &val) == 0) {
                const gop = try self.udp_seen.getOrPut(self.gpa, key);
                if (!gop.found_existing or gop.value_ptr.tx != val.tx_bytes or gop.value_ptr.rx != val.rx_bytes) {
                    gop.value_ptr.* = .{ .tx = val.tx_bytes, .rx = val.rx_bytes, .last_change_ms = now_ms, .visited_ms = now_ms };
                } else {
                    gop.value_ptr.visited_ms = now_ms;
                }
                if (now_ms - gop.value_ptr.last_change_ms > udp_idle_ms) {
                    _ = bpf_map_delete_elem(self.udp_map_fd, &key);
                    _ = self.udp_seen.remove(key);
                } else {
                    try table.observe(toUdpObservation(&val), now_ms);
                }
            }
            key = next;
            have_key = have_next;
        }
        // forget trackers whose kernel entries vanished (LRU eviction)
        var it = self.udp_seen.iterator();
        var dead: std.ArrayList(u64) = .empty;
        defer dead.deinit(self.gpa);
        while (it.next()) |kv| {
            if (kv.value_ptr.visited_ms != now_ms) try dead.append(self.gpa, kv.key_ptr.*);
        }
        for (dead.items) |k| _ = self.udp_seen.remove(k);
    }

    fn onSample(ctx_ptr: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr.?));
        if (size < @sizeOf(CgEvent)) return 0;
        const ev: *const CgEvent = @ptrCast(@alignCast(data.?));
        // Observe-only, including close/time_wait: the row shows its final state and
        // the next generation sweep (which nothing re-observes it into) evicts it and
        // reports the close — one eviction authority, no source-side races.
        if (ctx.table) |tbl| {
            tbl.observe(toObservation(ev), ctx.now_ms) catch |e| {
                ctx.err = e;
            };
        }
        return 0;
    }
};

// ---- tests: the decode, no root, no kernel ----------------------------------

const testing = std.testing;

fn v4(b: [4]u8) [16]u8 {
    var x = [_]u8{0} ** 16;
    @memcpy(x[0..4], &b);
    return x;
}

test "CgEvent decodes to an attributed Observation" {
    var ev: CgEvent = std.mem.zeroes(CgEvent);
    ev.family = AF_INET;
    ev.proto = 6;
    ev.newstate = @intFromEnum(TcpState.syn_sent);
    ev.kind = 0;
    ev.pid = 4242;
    ev.uid = 1000;
    ev.sport = 44330;
    ev.dport = 443;
    ev.saddr = v4(.{ 192, 168, 1, 9 });
    ev.daddr = v4(.{ 140, 82, 121, 4 });
    @memcpy(ev.comm[0..6], "claude");

    const obs = toObservation(&ev);
    try testing.expectEqual(cartograph.Proto.tcp, obs.key.proto);
    try testing.expectEqualSlices(u8, &.{ 192, 168, 1, 9 }, obs.key.local.bytes[0..4]);
    try testing.expectEqual(@as(u16, 44330), obs.key.local_port);
    try testing.expectEqualSlices(u8, &.{ 140, 82, 121, 4 }, obs.key.remote.bytes[0..4]);
    try testing.expectEqual(@as(u16, 443), obs.key.remote_port);
    try testing.expectEqual(TcpState.syn_sent, obs.state);
    try testing.expectEqual(@as(u32, 4242), obs.pid);
    try testing.expectEqual(@as(u32, 1000), obs.uid);
    try testing.expectEqualStrings("claude", obs.comm);
}

test "CgEvent decodes an IPv6 event and a short-comm" {
    var ev: CgEvent = std.mem.zeroes(CgEvent);
    ev.family = AF_INET6;
    ev.proto = 6;
    ev.newstate = @intFromEnum(TcpState.established);
    ev.sport = 55000;
    ev.dport = 443;
    ev.saddr = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 };
    ev.daddr = .{ 0x26, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    @memcpy(ev.comm[0..3], "ssh");

    const obs = toObservation(&ev);
    try testing.expect(obs.key.local.is_v6);
    try testing.expectEqualSlices(u8, &ev.daddr, &obs.key.remote.bytes);
    try testing.expectEqual(TcpState.established, obs.state);
    try testing.expectEqualStrings("ssh", obs.comm); // null-terminated comm, trimmed
}

test "fusion: a close event updates state; the generation sweep evicts and reports" {
    const gpa = testing.allocator;
    var table = FlowTable.init(gpa);
    defer table.deinit();
    var ctx: BpfCapturer.Ctx = .{ .gpa = gpa, .table = &table, .now_ms = 1000 };

    // tick 1: birth + death both between polls (the 40 ms connection)
    table.beginCycle();
    var est: CgEvent = std.mem.zeroes(CgEvent);
    est.family = AF_INET;
    est.newstate = @intFromEnum(TcpState.established);
    est.sport = 44330;
    est.dport = 443;
    est.saddr = v4(.{ 192, 168, 1, 9 });
    est.daddr = v4(.{ 140, 82, 121, 4 });
    _ = BpfCapturer.onSample(&ctx, &est, @sizeOf(CgEvent));
    var fin = est;
    fin.newstate = @intFromEnum(TcpState.close);
    _ = BpfCapturer.onSample(&ctx, &fin, @sizeOf(CgEvent));

    // the short-lived flow is VISIBLE this tick, with its final state
    try testing.expectEqual(@as(usize, 1), table.count());
    {
        const snap = try table.snapshot(gpa);
        defer gpa.free(snap);
        try testing.expectEqual(TcpState.close, snap[0].state);
    }
    var closed: std.ArrayList(FlowKey) = .empty;
    defer closed.deinit(gpa);
    try table.collectClosed(&closed);
    try testing.expectEqual(@as(usize, 0), closed.items.len); // seen this cycle — kept

    // tick 2: nothing re-observes it → swept, death reported, no leak
    table.beginCycle();
    closed.clearRetainingCapacity();
    try table.collectClosed(&closed);
    try testing.expectEqual(@as(usize, 1), closed.items.len);
    try testing.expectEqual(@as(usize, 0), table.count());
    try testing.expect(ctx.err == null);
}

test "an unattributed event keeps pid 0 (the late-merge case)" {
    var ev: CgEvent = std.mem.zeroes(CgEvent);
    ev.family = AF_INET;
    ev.newstate = @intFromEnum(TcpState.close_wait);
    ev.pid = 0; // a softirq transition — no owning process in context
    ev.sport = 22;
    ev.daddr = v4(.{ 10, 0, 0, 5 });
    const obs = toObservation(&ev);
    try testing.expectEqual(@as(u32, 0), obs.pid);
    try testing.expectEqualStrings("", obs.comm);
}

test "CgUdpFlow decodes to a UDP observation with byte counters (the QUIC fix)" {
    var v: CgUdpFlow = std.mem.zeroes(CgUdpFlow);
    v.family = AF_INET6;
    v.sport = 50000;
    v.dport = 443;
    v.saddr = .{ 0x26, 0 } ++ .{0} ** 14;
    v.daddr = .{ 0x2a, 0 } ++ .{0} ** 14;
    v.tx_bytes = 123_456;
    v.rx_bytes = 9_876_543;
    v.pid = 777;
    v.uid = 1000;
    @memcpy(v.comm[0..7], "firefox");

    const obs = toUdpObservation(&v);
    try testing.expectEqual(cartograph.Proto.udp, obs.key.proto);
    try testing.expect(obs.key.remote.is_v6);
    try testing.expectEqual(@as(u16, 443), obs.key.remote_port);
    try testing.expectEqual(@as(u64, 123_456), obs.tx_bytes);
    try testing.expectEqual(@as(u64, 9_876_543), obs.rx_bytes);
    try testing.expectEqual(@as(u32, 777), obs.pid);
    try testing.expectEqualStrings("firefox", obs.comm);
}
