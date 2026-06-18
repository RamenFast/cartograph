//! Attribution via /proc — "why was this sent" (the unprivileged path, proven in E2).
//!
//! inet_diag gives us the socket inode + uid; this maps inode → owning process by
//! scanning `/proc/<pid>/fd/*` for `socket:[inode]` symlinks, then resolves the
//! process comm and executable path. The privileged eBPF path (M2) will populate
//! the same fields in-kernel for the short-lived / other-user sockets we miss here.

const std = @import("std");

pub const PidInfo = struct {
    pid: u32,
    comm: [16]u8 = undefined,
    comm_len: u8 = 0,
    exe: [255]u8 = undefined,
    exe_len: u8 = 0,

    pub fn commSlice(self: *const PidInfo) []const u8 {
        return self.comm[0..self.comm_len];
    }
    pub fn exeSlice(self: *const PidInfo) []const u8 {
        return self.exe[0..self.exe_len];
    }
};

pub const InodeMap = std.AutoHashMap(u64, PidInfo);

/// Rebuild inode → (pid, comm, exe) by scanning every process's open fds.
pub fn buildInodeMap(io: std.Io, map: *InodeMap) !void {
    map.clearRetainingCapacity();
    const proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();

    var pathbuf: [64]u8 = undefined;
    var linkbuf: [256]u8 = undefined;
    var commbuf: [64]u8 = undefined;

    while (try it.next(io)) |de| {
        if (de.kind != .directory) continue;
        const pid = std.fmt.parseInt(u32, de.name, 10) catch continue;

        const fdpath = std.fmt.bufPrint(&pathbuf, "/proc/{d}/fd", .{pid}) catch continue;
        const fddir = std.Io.Dir.openDirAbsolute(io, fdpath, .{ .iterate = true }) catch continue;
        defer fddir.close(io);

        var info = PidInfo{ .pid = pid };
        var resolved = false; // comm + exe resolved lazily, only if pid owns a socket

        var fdit = fddir.iterate();
        while (fdit.next(io) catch null) |fde| {
            const n = fddir.readLink(io, fde.name, &linkbuf) catch continue;
            const link = linkbuf[0..n];
            if (!std.mem.startsWith(u8, link, "socket:[")) continue;
            const inode_str = link["socket:[".len .. link.len - 1];
            const inode = std.fmt.parseInt(u64, inode_str, 10) catch continue;

            if (!resolved) {
                resolveComm(io, pid, &info, &pathbuf, &commbuf);
                resolveExe(io, pid, &info, &pathbuf, &linkbuf);
                resolved = true;
            }
            try map.put(inode, info);
        }
    }
}

fn resolveComm(io: std.Io, pid: u32, info: *PidInfo, pathbuf: []u8, commbuf: []u8) void {
    const cp = std.fmt.bufPrint(pathbuf, "/proc/{d}/comm", .{pid}) catch return;
    const c = std.Io.Dir.cwd().readFile(io, cp, commbuf) catch return;
    const trimmed = std.mem.trimEnd(u8, c, "\n");
    const clen: u8 = @intCast(@min(trimmed.len, info.comm.len));
    @memcpy(info.comm[0..clen], trimmed[0..clen]);
    info.comm_len = clen;
}

fn resolveExe(io: std.Io, pid: u32, info: *PidInfo, pathbuf: []u8, linkbuf: []u8) void {
    const ep = std.fmt.bufPrint(pathbuf, "/proc/{d}/exe", .{pid}) catch return;
    const n = std.Io.Dir.cwd().readLink(io, ep, linkbuf) catch return;
    const elen: u8 = @intCast(@min(n, info.exe.len));
    @memcpy(info.exe[0..elen], linkbuf[0..elen]);
    info.exe_len = elen;
}
