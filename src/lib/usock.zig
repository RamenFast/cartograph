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

/// Bind a listening socket at `path`. Returns the listen fd; `accept` it for clients.
///
/// Hardened (audit F9/F21):
///   * A pre-existing path is unlinked **only if it is a socket** — `listen()` on a
///     typo'd path must never delete a user's regular file (surveyor may carry caps).
///     A non-socket in the way is `error.PathNotSocket`, an error naming the problem.
///   * The socket file is created mode 0600 (umask-guarded around `bind`), so only the
///     owning user can connect. The stream carries PIDs, exe paths, and every remote
///     endpoint — the watcher must not become the leak.
pub fn listen(path: []const u8) !i32 {
    const a = try fillAddr(path); // validates length BEFORE any copy — a long path is an error, not a panic
    const fd: i32 = @intCast(try ok(linux.socket(AF_UNIX, SOCK_STREAM, 0)));
    errdefer _ = linux.close(fd);

    var pz: [109]u8 = undefined; // NUL-terminated copy for stat/unlink
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    const src: [*:0]const u8 = @ptrCast(&pz);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, src, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) == .SUCCESS) {
        if (stx.mode & linux.S.IFMT != linux.S.IFSOCK) return error.PathNotSocket;
        _ = linux.unlink(src); // a stale socket from a previous run — safe to clear
    }

    // 0600 socket file: bind() creates it as 0777 & ~umask, so guard with umask
    // rather than a racy post-bind chmod.
    const old_umask = linux.syscall1(.umask, 0o177);
    const bind_rc = linux.bind(fd, @ptrCast(&a.addr), a.len);
    _ = linux.syscall1(.umask, old_umask);
    _ = try ok(bind_rc);
    _ = try ok(linux.listen(fd, 8));
    return fd;
}

fn checkPeerCred(fd: i32) !void {
    // Peer-credential check (F9): the socket file is 0600, but defense-in-depth —
    // only the owning user (or root) may consume the flow stream.
    var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
    var len: u32 = @sizeOf(@TypeOf(cred));
    const SOL_SOCKET = 1;
    const SO_PEERCRED = 17;
    if (linux.errno(linux.getsockopt(fd, SOL_SOCKET, SO_PEERCRED, @ptrCast(&cred), &len)) == .SUCCESS) {
        const me = linux.getuid();
        if (cred.uid != me and cred.uid != 0) return error.PeerNotOwner;
    }
}

pub fn accept(listen_fd: i32) !i32 {
    const fd: i32 = @intCast(try ok(linux.accept4(listen_fd, null, null, 0)));
    errdefer _ = linux.close(fd);
    try checkPeerCred(fd);
    return fd;
}

/// Accept without blocking: null when no connection is pending. The *listen* fd must
/// be nonblocking (`setNonblocking`); the accepted fd stays blocking — the daemon polls
/// before every read, and writes ride the normal blocking path (audit F5: one accept
/// loop that never parks on a single client).
pub fn acceptNonblocking(listen_fd: i32) !?i32 {
    const rc = linux.accept4(listen_fd, null, null, 0);
    if (linux.errno(rc) == .AGAIN) return null;
    const fd: i32 = @intCast(try ok(rc));
    errdefer _ = linux.close(fd);
    try checkPeerCred(fd);
    return fd;
}

/// Flip a descriptor to O_NONBLOCK (the daemon's listen fd, so a raced-away
/// connection can never park the whole session in accept()).
pub fn setNonblocking(fd: i32) void {
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK: usize = 0o4000;
    const cur = linux.fcntl(@intCast(fd), F_GETFL, 0);
    if (linux.errno(cur) != .SUCCESS) return;
    _ = linux.fcntl(@intCast(fd), F_SETFL, cur | O_NONBLOCK);
}

/// The box's *default* session socket — where the double-clicked GUI hosts its daemon
/// and where `surveyor ctl` looks when no --socket is given. One well-known rendezvous
/// is what lets the human's window and the agent's command meet in the same session
/// (audit F2/F3): $XDG_RUNTIME_DIR/cartograph.sock, else /tmp/cartograph-<uid>.sock.
pub fn defaultPath(buf: []u8, runtime_dir: ?[]const u8) []const u8 {
    if (runtime_dir) |rd| {
        if (std.fmt.bufPrint(buf, "{s}/cartograph.sock", .{rd})) |s| return s else |_| {}
    }
    return std.fmt.bufPrint(buf, "/tmp/cartograph-{d}.sock", .{linux.getuid()}) catch unreachable;
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

test "listen refuses to delete a non-socket path (F21) and creates 0600 sockets (F9)" {
    const t = std.testing;
    var tmpbuf: [64]u8 = undefined;
    const pid = linux.getpid();

    // a regular file in the way is an error, never an unlink
    const filepath = try std.fmt.bufPrint(&tmpbuf, "/tmp/cg-usock-test-{d}.txt", .{pid});
    {
        var pz: [109]u8 = undefined;
        @memcpy(pz[0..filepath.len], filepath);
        pz[filepath.len] = 0;
        const fd: i32 = @intCast(linux.open(@ptrCast(&pz), .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644));
        try t.expect(fd >= 0);
        _ = linux.close(fd);
        defer _ = linux.unlink(@ptrCast(&pz));

        try t.expectError(error.PathNotSocket, listen(filepath));
        // the file survived
        var stx: linux.Statx = undefined;
        try t.expectEqual(linux.E.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&pz), 0, .{ .TYPE = true }, &stx)));
    }

    // a fresh socket binds 0600 and a stale socket is cleared on rebind
    var sockbuf: [64]u8 = undefined;
    const sockpath = try std.fmt.bufPrint(&sockbuf, "/tmp/cg-usock-test-{d}.sock", .{pid});
    var pz: [109]u8 = undefined;
    @memcpy(pz[0..sockpath.len], sockpath);
    pz[sockpath.len] = 0;
    defer _ = linux.unlink(@ptrCast(&pz));

    const lfd = try listen(sockpath);
    var stx: linux.Statx = undefined;
    try t.expectEqual(linux.E.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&pz), 0, .{ .TYPE = true, .MODE = true }, &stx)));
    try t.expectEqual(@as(u32, linux.S.IFSOCK), stx.mode & linux.S.IFMT);
    try t.expectEqual(@as(u32, 0o600), stx.mode & 0o777); // owner-only (F9)
    _ = linux.close(lfd);

    // stale socket file left behind → a second listen succeeds (the unlink-if-socket path)
    const lfd2 = try listen(sockpath);
    _ = linux.close(lfd2);
}

test "accept admits the owning user (peer-cred check exercised live)" {
    var sockbuf: [64]u8 = undefined;
    const sockpath = try std.fmt.bufPrint(&sockbuf, "/tmp/cg-usock-cred-{d}.sock", .{linux.getpid()});
    var pz: [109]u8 = undefined;
    @memcpy(pz[0..sockpath.len], sockpath);
    pz[sockpath.len] = 0;
    defer _ = linux.unlink(@ptrCast(&pz));

    const lfd = try listen(sockpath);
    defer _ = linux.close(lfd);
    const cfd = try connect(sockpath); // same uid — must be admitted
    defer _ = linux.close(cfd);
    const afd = try accept(lfd);
    _ = linux.close(afd);
}
