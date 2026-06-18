//! The eBPF capture source — the privileged producer behind the same `Observation`
//! seam the inet_diag path uses, so the `FlowTable` and every frontend are unchanged
//! (ARCHITECTURE.md "swap the capture source behind the seam"). The kernel program is
//! src/capture/bpf/cartograph.bpf.c; this is its userspace loader (libbpf via FFI) plus
//! the event decode.
//!
//! Privilege: loading/attaching needs CAP_BPF + CAP_PERFMON. `init` returns an error
//! when those caps are absent, so surveyor falls back to the unprivileged inet_diag
//! source — eBPF is an upgrade, never a hard requirement. The decode (`toObservation`)
//! is pure and unit-tested without root; the live load is exercised by surveyor under
//! `setcap` (see ARCHITECTURE.md — Ben runs that, root-only).

const std = @import("std");
const cartograph = @import("cartograph");

const Observation = cartograph.Observation;
const FlowKey = cartograph.FlowKey;
const FlowTable = cartograph.FlowTable;
const TcpState = cartograph.TcpState;

pub const built = true;

const AF_INET = 2;
const AF_INET6 = 10;

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

comptime {
    // Guards the ABI against silent drift between the C struct and this mirror.
    std.debug.assert(@sizeOf(CgEvent) == 72);
}

fn commSlice(comm: *const [16]u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, comm, 0) orelse comm.len;
    return comm[0..n];
}

/// Decode one ring-buffer event into the shared `Observation` the FlowTable folds in.
/// Pure: no kernel, no allocation — the unit-testable core of the eBPF path.
pub fn toObservation(ev: *const CgEvent) Observation {
    const is_v6 = ev.family == AF_INET6;
    const local = if (is_v6) cartograph.Addr.v6(ev.saddr) else cartograph.Addr.v4(ev.saddr[0..4].*);
    const remote = if (is_v6) cartograph.Addr.v6(ev.daddr) else cartograph.Addr.v4(ev.daddr[0..4].*);
    return .{
        .key = .{
            .proto = .tcp,
            .local = local,
            .local_port = ev.sport,
            .remote = remote,
            .remote_port = ev.dport,
        },
        .state = @enumFromInt(ev.newstate),
        .pid = ev.pid,
        .uid = ev.uid,
        .comm = commSlice(&ev.comm),
        // byte counters/RTT aren't in this hook (the state machine, not the data path);
        // they stay 0 here. inet_diag remains the byte-counter source until a sockops/
        // tcp_sendmsg counter program lands (post-M2). 0 is honest, not a guess.
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
extern fn bpf_link__destroy(link: ?*anyopaque) c_int;
extern fn bpf_object__find_map_by_name(obj: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn bpf_map__fd(map: ?*anyopaque) c_int;
extern fn ring_buffer__new(map_fd: c_int, cb: RingSampleFn, ctx: ?*anyopaque, opts: ?*const anyopaque) ?*anyopaque;
extern fn ring_buffer__poll(rb: ?*anyopaque, timeout_ms: c_int) c_int;
extern fn ring_buffer__free(rb: ?*anyopaque) void;

/// The compiled CO-RE object, embedded so surveyor stays a single binary.
const obj_bytes: []const u8 = @embedFile("cartograph_bpf_obj");

/// eBPF capture source. Same shape (`refresh`) as the inet_diag `Capturer`, so the
/// `Source` seam in surveyor dispatches to either without the table noticing.
pub const BpfCapturer = struct {
    obj: *anyopaque,
    link: *anyopaque,
    rb: *anyopaque,
    ctx: *Ctx,
    gpa: std.mem.Allocator,

    const Ctx = struct {
        gpa: std.mem.Allocator,
        table: ?*FlowTable = null,
        closed: ?*std.ArrayList(FlowKey) = null,
        now_ms: i64 = 0,
        err: ?anyerror = null,
    };

    pub fn init(gpa: std.mem.Allocator) !BpfCapturer {
        const obj = bpf_object__open_mem(obj_bytes.ptr, obj_bytes.len, null) orelse return error.BpfOpen;
        errdefer bpf_object__close(obj);
        if (bpf_object__load(obj) != 0) return error.BpfLoad; // needs CAP_BPF
        const prog = bpf_object__find_program_by_name(obj, "cg_inet_sock_set_state") orelse return error.BpfProgramMissing;
        const link = bpf_program__attach(prog) orelse return error.BpfAttach; // needs CAP_PERFMON
        errdefer _ = bpf_link__destroy(link);
        const map = bpf_object__find_map_by_name(obj, "events") orelse return error.BpfMapMissing;
        const map_fd = bpf_map__fd(map);

        const ctx = try gpa.create(Ctx);
        errdefer gpa.destroy(ctx);
        ctx.* = .{ .gpa = gpa };

        const rb = ring_buffer__new(map_fd, onSample, ctx, null) orelse return error.BpfRingNew;
        return .{ .obj = obj, .link = link, .rb = rb, .ctx = ctx, .gpa = gpa };
    }

    pub fn deinit(self: *BpfCapturer) void {
        ring_buffer__free(self.rb);
        _ = bpf_link__destroy(self.link);
        bpf_object__close(self.obj);
        self.gpa.destroy(self.ctx);
    }

    /// Drain pending kernel events into `table`; collect deaths into `closed`. Same
    /// contract the diag path's tick provides, so surveyor's loop is source-agnostic.
    pub fn refresh(self: *BpfCapturer, table: *FlowTable, now_ms: i64, closed: *std.ArrayList(FlowKey)) !void {
        self.ctx.table = table;
        self.ctx.closed = closed;
        self.ctx.now_ms = now_ms;
        self.ctx.err = null;
        if (ring_buffer__poll(self.rb, 0) < 0) return error.BpfRingPoll; // 0 ms = non-blocking
        if (self.ctx.err) |e| return e;
    }

    fn onSample(ctx_ptr: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr.?));
        if (size < @sizeOf(CgEvent)) return 0;
        const ev: *const CgEvent = @ptrCast(@alignCast(data.?));
        const obs = toObservation(ev);
        if (ev.newstate == @intFromEnum(TcpState.close) or ev.newstate == @intFromEnum(TcpState.time_wait)) {
            if (ctx.closed) |cl| cl.append(ctx.gpa, obs.key) catch {
                ctx.err = error.OutOfMemory;
            };
        } else if (ctx.table) |tbl| {
            tbl.observe(obs, ctx.now_ms) catch |e| {
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
