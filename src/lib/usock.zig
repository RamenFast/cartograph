//! Minimal AF_UNIX stream-socket helpers — the transport under the binary IPC once
//! surveyor runs as a separate (setcap'd) daemon rather than a pipe stage. The point
//! is that the `ipc` codec does **not** change: a frame is a frame whether it crosses
//! a pipe (M1) or this socket (M2). The privilege boundary is "surveyor on one side,
//! the unprivileged frontend on the other"; setcap raises surveyor's caps, the socket
//! is the seam between them. Proven by sending real frames through a kernel socketpair
//! and reading them back identically (the parity-over-transport assertion).

const std = @import("std");
const linux = std.os.linux;

const AF_UNIX = 1;
const SOCK_STREAM = 1;

const sockaddr_un = extern struct {
    family: u16 = AF_UNIX,
    path: [108]u8 = [_]u8{0} ** 108,
};

fn ok(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.ConnectionRefused,
        .NOENT => error.SocketPathMissing,
        else => error.Socket,
    };
}

const Addr = struct { addr: sockaddr_un, len: u32 };

fn fillAddr(path: []const u8) !Addr {
    if (path.len >= 108) return error.SocketPathTooLong;
    var a = Addr{ .addr = .{}, .len = @intCast(@offsetOf(sockaddr_un, "path") + path.len + 1) };
    @memcpy(a.addr.path[0..path.len], path);
    return a;
}

/// Bind a listening socket at `path`, unlinking any stale socket file first. Returns
/// the listen fd; `accept` it for client connections.
pub fn listen(path: []const u8) !i32 {
    const fd: i32 = @intCast(try ok(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    errdefer _ = linux.close(fd);

    var pz: [109]u8 = undefined; // NUL-terminated copy for unlink
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    _ = linux.unlink(@ptrCast(&pz)); // best effort; fine if it didn't exist

    const a = try fillAddr(path);
    _ = try ok(linux.bind(fd, @ptrCast(&a.addr), a.len));
    _ = try ok(linux.listen(fd, 8));
    return fd;
}

pub fn accept(listen_fd: i32) !i32 {
    return @intCast(try ok(linux.accept4(listen_fd, null, null, 0)));
}

pub fn connect(path: []const u8) !i32 {
    const fd: i32 = @intCast(try ok(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    errdefer _ = linux.close(fd);
    const a = try fillAddr(path);
    _ = try ok(linux.connect(fd, @ptrCast(&a.addr), a.len));
    return fd;
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

test "ipc frames survive the socket transport identically" {
    const ipc = @import("ipc.zig");
    const flow = @import("flow.zig");

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)));
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    var f: flow.Flow = .{ .key = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 44330, .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 } };
    f.pid = 4242;
    f.comm.set("claude");
    f.rx_bytes = 9001;

    var wbuf: [ipc.max_frame]u8 = undefined;
    var w = std.Io.Writer.fixed(&wbuf);
    try ipc.sendHello(&w);
    try ipc.sendFlowUpsert(&w, f);
    const bytes = w.buffered();
    try std.testing.expectEqual(bytes.len, try ok(linux.write(fds[0], bytes.ptr, bytes.len)));

    var rbuf: [ipc.max_frame]u8 = undefined;
    const n = try ok(linux.read(fds[1], &rbuf, rbuf.len));
    var r = std.Io.Reader.fixed(rbuf[0..n]);
    try std.testing.expectEqual(@as(u16, ipc.protocol_version), (try ipc.readFrame(&r)).?.hello);
    const frame = (try ipc.readFrame(&r)).?;
    try std.testing.expect(frame == .flow_upsert);
    try std.testing.expectEqual(@as(u32, 4242), frame.flow_upsert.pid);
    try std.testing.expectEqualStrings("claude", frame.flow_upsert.comm.slice());
    try std.testing.expectEqual(@as(u64, 9001), frame.flow_upsert.rx_bytes);
}
