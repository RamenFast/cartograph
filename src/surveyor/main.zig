//! surveyor — Cartograph's capture core.
//!
//!   surveyor snapshot   one-shot attributed flow table (human-readable)
//!   surveyor serve      stream the live view-model as binary IPC frames to stdout
//!
//! `serve` is the (eventually privileged) producer a frontend consumes:
//!   surveyor serve | cartograph --ipc
//! The same frames will travel a Unix socket once surveyor runs as a setcap daemon.

const std = @import("std");
const cartograph = @import("cartograph");
const capture = @import("capture");

const ipc = cartograph.ipc;

const RST = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv0
    const cmd = args.next() orelse "snapshot";

    if (std.mem.eql(u8, cmd, "serve")) {
        try serve(gpa, io);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        try snapshot(gpa, io);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try usage(io);
    } else {
        try usage(io);
        return error.UnknownCommand;
    }
}

fn usage(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll(
        \\surveyor — cartograph capture core
        \\
        \\usage:
        \\  surveyor snapshot     one-shot attributed flow table
        \\  surveyor serve        stream live IPC frames to stdout
        \\
    );
    try w.flush();
}

/// One-shot, human-readable table — the promoted spike, now tcp6/udp + bytes + RTT.
fn snapshot(gpa: std.mem.Allocator, io: std.Io) !void {
    var cap = try capture.Capturer.init(gpa, io);
    defer cap.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();

    table.beginCycle();
    try cap.refresh(&table, capture.nowMs(io));

    const flows = try table.snapshot(gpa);
    defer gpa.free(flows);

    var buf: [128 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    try w.print("{s}cartograph · surveyor{s} {s}— live attributed flows (inet_diag + /proc)\n\n{s}", .{ BOLD, RST, DIM, RST });
    try w.print("{s}{s:<6} {s:<15} {s:<3} {s:<10} {s:<21} {s:<21} {s:>9} {s:>9} {s:>6}{s}\n", .{
        BOLD, "PID", "COMM", "·", "STATE", "LOCAL", "REMOTE", "RX", "TX", "RTT", RST,
    });

    var attributed: usize = 0;
    var lbuf: [48]u8 = undefined;
    var rbuf: [48]u8 = undefined;
    var rxbuf: [16]u8 = undefined;
    var txbuf: [16]u8 = undefined;
    for (flows) |f| {
        if (f.attributed()) attributed += 1;
        const cat = f.category;
        const rtt_ms: f64 = @as(f64, @floatFromInt(f.rtt_us)) / 1000.0;
        try w.print("{s}{s}{d:<6}{s} {s:<15} {s}{s}{s} {s:<10} {s:<21} {s}{s:<21}{s} {s:>9} {s:>9} ", .{
            cat.ansi(),
            "",
            f.pid,
            RST,
            f.name(),
            cat.ansi(),
            cat.glyph(),
            RST,
            f.state.label(),
            localStr(f, &lbuf),
            cat.ansi(),
            remoteStr(f, &rbuf),
            RST,
            cartograph.humanBytes(&rxbuf, f.rx_bytes),
            cartograph.humanBytes(&txbuf, f.tx_bytes),
        });
        if (f.rtt_us != 0) {
            try w.print("{s}{d:>5.1}ms{s}\n", .{ DIM, rtt_ms, RST });
        } else {
            try w.print("{s}{s:>7}{s}\n", .{ DIM, "·", RST });
        }
    }
    try w.print("\n{s}{d}/{d} flows attributed to a local process (rest = other-user / kernel / closing).{s}\n", .{ DIM, attributed, flows.len, RST });
    try w.flush();
}

fn localStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    return cartograph.endpoint(buf, f.key.local, f.key.local_port);
}

fn remoteStr(f: *cartograph.Flow, buf: []u8) []const u8 {
    return cartograph.endpoint(buf, f.key.remote, f.key.remote_port);
}

/// Stream the live view-model as binary IPC frames to stdout, forever.
fn serve(gpa: std.mem.Allocator, io: std.Io) !void {
    var cap = try capture.Capturer.init(gpa, io);
    defer cap.deinit();
    var table = cartograph.FlowTable.init(gpa);
    defer table.deinit();

    var buf: [256 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    try ipc.sendHello(w);
    try w.flush();

    var closed: std.ArrayList(cartograph.FlowKey) = .empty;
    defer closed.deinit(gpa);

    while (true) {
        const now = capture.nowMs(io);
        table.beginCycle();
        try cap.refresh(&table, now);

        const flows = try table.snapshot(gpa);
        defer gpa.free(flows);
        for (flows) |f| try ipc.sendFlowUpsert(w, f.*);

        closed.clearRetainingCapacity();
        try table.collectClosed(&closed);
        for (closed.items) |k| try ipc.sendFlowClosed(w, k);

        try ipc.sendTick(w, now);
        try w.flush();

        try io.sleep(std.Io.Duration.fromMilliseconds(1000), .awake);
    }
}
