// cartograph · surveyor — attribution spike (unprivileged path)
//
// Proves the no-privilege fallback that maps live TCP sockets -> owning process,
// in pure Zig with zero external deps. This is the same join the privileged eBPF
// path will do in-kernel; here we do it from /proc to validate the model + toolchain.
//
//   build:  ../toolchain/zig run src/main.zig
//   watch:  ../toolchain/zig run src/main.zig -- watch

const std = @import("std");

const RST = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const CYAN = "\x1b[36m";
const YEL = "\x1b[33m";
const GRN = "\x1b[32m";
const MAG = "\x1b[35m";

const state_names = [_][]const u8{
    "-",         "ESTAB",     "SYN_SENT",  "SYN_RECV",
    "FIN_WAIT1", "FIN_WAIT2", "TIME_WAIT", "CLOSE",
    "CLOSE_WAIT","LAST_ACK",  "LISTEN",    "CLOSING",
    "NEW_SYN_RX",
};

const PidInfo = struct {
    pid: u32,
    comm: [16]u8 = undefined,
    comm_len: u8 = 0,
};

/// Read a (typically small) /proc file into `buf`.
fn readProc(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    return std.Io.Dir.cwd().readFile(io, path, buf);
}

/// Build inode -> (pid, comm) by scanning /proc/<pid>/fd/* socket symlinks.
fn buildInodeMap(io: std.Io, map: *std.AutoHashMap(u64, PidInfo)) !void {
    map.clearRetainingCapacity();
    const proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();

    var pathbuf: [64]u8 = undefined;
    var linkbuf: [64]u8 = undefined;
    var commbuf: [32]u8 = undefined;

    while (try it.next(io)) |de| {
        if (de.kind != .directory) continue;
        const pid = std.fmt.parseInt(u32, de.name, 10) catch continue;

        const fdpath = std.fmt.bufPrint(&pathbuf, "/proc/{d}/fd", .{pid}) catch continue;
        const fddir = std.Io.Dir.openDirAbsolute(io, fdpath, .{ .iterate = true }) catch continue;
        defer fddir.close(io);

        // resolve comm once per pid (lazily, only if it owns a socket)
        var info = PidInfo{ .pid = pid };
        var have_comm = false;

        var fdit = fddir.iterate();
        while (fdit.next(io) catch null) |fde| {
            const n = fddir.readLink(io, fde.name, &linkbuf) catch continue;
            const link = linkbuf[0..n];
            if (!std.mem.startsWith(u8, link, "socket:[")) continue;
            const inode_str = link["socket:[".len .. link.len - 1];
            const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;

            if (!have_comm) {
                const cp = std.fmt.bufPrint(&pathbuf, "/proc/{d}/comm", .{pid}) catch continue;
                const c = readProc(io, cp, &commbuf) catch "";
                const trimmed = std.mem.trimEnd(u8, c, "\n");
                const clen = @min(trimmed.len, info.comm.len);
                @memcpy(info.comm[0..clen], trimmed[0..clen]);
                info.comm_len = @intCast(clen);
                have_comm = true;
            }
            try map.put(inode, info);
        }
    }
}

fn fmtV4(hex_addr: []const u8, port_hex: []const u8, out: []u8) ![]u8 {
    const v = try std.fmt.parseInt(u32, hex_addr, 16);
    const port = try std.fmt.parseInt(u16, port_hex, 16);
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}:{d}", .{
        v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF, port,
    });
}

fn render(io: std.Io, map: *std.AutoHashMap(u64, PidInfo), w: anytype) !void {
    var tcpbuf: [256 * 1024]u8 = undefined;
    const data = try readProc(io, "/proc/net/tcp", &tcpbuf);

    try w.print("{s}{s}{s:<6} {s:<16} {s:<11} {s:<22} {s:<22} {s}\n", .{
        BOLD, GRN, "PID", "COMM", "STATE", "LOCAL", "REMOTE", RST,
    });

    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    var lbuf: [22]u8 = undefined;
    var rbuf: [22]u8 = undefined;

    var attributed: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        var t = std.mem.tokenizeScalar(u8, line, ' ');
        _ = t.next() orelse continue; // sl
        const local = t.next() orelse continue;
        const rem = t.next() orelse continue;
        const st_hex = t.next() orelse continue;
        _ = t.next() orelse continue; // tx:rx
        _ = t.next() orelse continue; // tr:when
        _ = t.next() orelse continue; // retrnsmt
        _ = t.next() orelse continue; // uid
        _ = t.next() orelse continue; // timeout
        const inode_str = t.next() orelse continue;

        total += 1;
        const st = std.fmt.parseInt(u8, st_hex, 16) catch 0;
        const state = if (st < state_names.len) state_names[st] else "?";

        var lsplit = std.mem.splitScalar(u8, local, ':');
        const la = lsplit.next() orelse continue;
        const lp = lsplit.next() orelse continue;
        var rsplit = std.mem.splitScalar(u8, rem, ':');
        const ra = rsplit.next() orelse continue;
        const rp = rsplit.next() orelse continue;

        const lstr = fmtV4(la, lp, &lbuf) catch continue;
        const rstr = fmtV4(ra, rp, &rbuf) catch continue;

        const inode = std.fmt.parseInt(u64, inode_str, 10) catch 0;
        const info = map.get(inode);

        if (info) |i| {
            attributed += 1;
            try w.print("{s}{d:<6}{s} {s}{s:<16}{s} {s:<11} {s:<22} {s}{s:<22}{s}\n", .{
                MAG, i.pid, RST, YEL, i.comm[0..i.comm_len], RST, state, lstr, CYAN, rstr, RST,
            });
        } else {
            try w.print("{s}{s:<6} {s:<16} {s:<11} {s:<22} {s:<22}{s}\n", .{
                DIM, "?", "?", state, lstr, rstr, RST,
            });
        }
    }
    try w.print("\n{s}{d}/{d} sockets attributed to a local process (rest owned by other users / kernel).{s}\n", .{ DIM, attributed, total, RST });
}

// One-shot snapshot. For a live view today: `watch -n1 ./surveyor`.
// Native streaming/real-time is the job of the eBPF event path (see docs/ROADMAP.md).
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = std.AutoHashMap(u64, PidInfo).init(alloc);
    defer map.deinit();

    try buildInodeMap(io, &map);

    const out = std.Io.File.stdout();
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = out.writer(io, &wbuf);
    const w = &fw.interface;

    try w.print("{s}cartograph · surveyor{s} {s}— live socket attribution (unprivileged /proc path){s}\n\n", .{ BOLD, RST, DIM, RST });
    try render(io, &map, w);
    try w.flush();
}
