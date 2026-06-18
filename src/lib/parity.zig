//! Parity harness — the in-process view-model and the IPC view-model must agree.
//!
//! The architecture's headline claim is *parity by construction*: every renderer
//! reads the same `libcartograph` view-model, in-process **or** over the binary IPC
//! (`surveyor serve | cartograph --ipc`). M1 proved the *mechanism* (one `render()`);
//! this file makes the claim *checkable* (Nexus critique v3 §1e/§5.2). For the same
//! capture input, the `Flow` a frontend sees in-process must equal — on every field
//! the wire carries — the `Flow` it sees after a round-trip through `ipc`. This has to
//! hold *before* the Unix socket goes live (M2/§5), or parity fractures silently at
//! the transport and a future GTK frontend inherits the fracture.

const std = @import("std");
const flow = @import("flow.zig");
const ipc = @import("ipc.zig");
const table = @import("table.zig");

const Flow = flow.Flow;
const FlowKey = flow.FlowKey;

/// Equal on the fields `ipc` actually serializes — i.e. everything except the
/// local-only sparkline `rates` ring, which each side derives independently from the
/// throughput it observes (so it is *intentionally* not transmitted, and comparing it
/// would be wrong, not a parity failure).
pub fn flowWireEqual(a: Flow, b: Flow) bool {
    return std.meta.eql(a.key, b.key) and
        a.state == b.state and
        a.category == b.category and
        a.pid == b.pid and a.uid == b.uid and a.inode == b.inode and
        a.rx_bytes == b.rx_bytes and a.tx_bytes == b.tx_bytes and
        a.rx_rate == b.rx_rate and a.tx_rate == b.tx_rate and
        a.rtt_us == b.rtt_us and
        a.first_seen_ms == b.first_seen_ms and a.last_seen_ms == b.last_seen_ms and
        a.fresh == b.fresh and
        std.mem.eql(u8, a.comm.slice(), b.comm.slice()) and
        std.mem.eql(u8, a.exe.slice(), b.exe.slice());
}

/// Encode a flow as the producer would, then decode it as a consumer would.
fn roundTrip(f: Flow) !Flow {
    var buf: [ipc.max_frame]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ipc.sendFlowUpsert(&w, f);
    var r = std.Io.Reader.fixed(w.buffered());
    const frame = (try ipc.readFrame(&r)).?;
    std.debug.assert(frame == .flow_upsert);
    return frame.flow_upsert;
}

fn findByKey(flows: []*Flow, key: FlowKey) ?*Flow {
    for (flows) |f| if (std.meta.eql(f.key, key)) return f;
    return null;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn randomStr(comptime N: usize, rnd: std.Random) flow.Str(N) {
    var s: flow.Str(N) = .{};
    const len = rnd.intRangeAtMost(usize, 0, N);
    var buf: [N]u8 = undefined;
    for (0..len) |k| buf[k] = rnd.intRangeAtMost(u8, 'a', 'z');
    s.set(buf[0..len]);
    return s;
}

fn randomAddr(rnd: std.Random, is_v6: bool) flow.Addr {
    var a: flow.Addr = .{ .is_v6 = is_v6 };
    rnd.bytes(&a.bytes);
    if (!is_v6) @memset(a.bytes[4..], 0); // v4 lives in the first 4 bytes
    return a;
}

fn randomFlow(rnd: std.Random) Flow {
    const is_v6 = rnd.boolean();
    var f: Flow = .{ .key = .{
        .proto = if (rnd.boolean()) .tcp else .udp,
        .local = randomAddr(rnd, is_v6),
        .local_port = rnd.int(u16),
        .remote = randomAddr(rnd, is_v6),
        .remote_port = rnd.int(u16),
    } };
    f.state = @enumFromInt(rnd.intRangeAtMost(u8, 0, 12));
    f.category = @enumFromInt(rnd.intRangeAtMost(u8, 0, 10));
    f.pid = rnd.int(u32);
    f.uid = rnd.int(u32);
    f.inode = rnd.int(u64);
    f.rx_bytes = rnd.int(u64);
    f.tx_bytes = rnd.int(u64);
    f.rx_rate = rnd.int(u32);
    f.tx_rate = rnd.int(u32);
    f.rtt_us = rnd.int(u32);
    f.first_seen_ms = rnd.int(i64);
    f.last_seen_ms = rnd.int(i64);
    f.fresh = rnd.boolean();
    f.comm = randomStr(16, rnd);
    f.exe = randomStr(255, rnd);
    return f;
}

test "ipc round-trip preserves every wire field (property, 500 flows)" {
    var prng = std.Random.DefaultPrng.init(0xCA27_0F00_0FED_BEEF);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const f = randomFlow(rnd);
        const g = try roundTrip(f);
        if (!flowWireEqual(f, g)) {
            std.debug.print("parity mismatch at flow #{d}\n", .{i});
            return error.ParityFracture;
        }
    }
}

test "in-process and IPC table paths agree for the same capture input" {
    const gpa = testing.allocator;
    var producer = table.FlowTable.init(gpa); // the in-process path (TUI linked direct)
    defer producer.deinit();
    var consumer = table.FlowTable.init(gpa); // the socket path (frontend over IPC)
    defer consumer.deinit();

    const k1: FlowKey = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 44330, .remote = flow.Addr.v4(.{ 140, 82, 121, 4 }), .remote_port = 443 };
    const k2: FlowKey = .{ .proto = .udp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 53, .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 53 };
    const k3: FlowKey = .{ .proto = .tcp, .local = flow.Addr.v6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 }), .local_port = 55000, .remote = flow.Addr.v6(.{ 0x26, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }), .remote_port = 443 };

    // two capture ticks, so flows are non-fresh and carry derived rates
    producer.beginCycle();
    try producer.observe(.{ .key = k1, .state = .established, .pid = 100, .comm = "chrome", .exe = "/usr/bin/chrome", .rtt_us = 20000 }, 1000);
    try producer.observe(.{ .key = k2, .state = .established, .pid = 0 }, 1000); // an unattributed `?`
    try producer.observe(.{ .key = k3, .state = .established, .pid = 200, .comm = "firefox" }, 1000);
    producer.beginCycle();
    try producer.observe(.{ .key = k1, .state = .established, .pid = 100, .comm = "chrome", .exe = "/usr/bin/chrome", .rx_bytes = 10_000, .tx_bytes = 2_000, .rtt_us = 21000 }, 2000);
    try producer.observe(.{ .key = k2, .state = .established, .pid = 0, .rx_bytes = 500 }, 2000);
    try producer.observe(.{ .key = k3, .state = .established, .pid = 200, .comm = "firefox", .rx_bytes = 4096 }, 2000);

    // mirror the producer's view through the IPC codec into the consumer
    const psnap = try producer.snapshot(gpa);
    defer gpa.free(psnap);
    for (psnap) |f| try consumer.apply(try roundTrip(f.*));

    const csnap = try consumer.snapshot(gpa);
    defer gpa.free(csnap);
    try testing.expectEqual(psnap.len, csnap.len);
    for (psnap) |pf| {
        const cf = findByKey(csnap, pf.key) orelse return error.MissingFlowOnConsumer;
        try testing.expect(flowWireEqual(pf.*, cf.*));
    }
}
