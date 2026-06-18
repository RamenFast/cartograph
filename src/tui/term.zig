//! Terminal control for the TUI: alternate screen, raw mode, size, key polling.
//! Display-agnostic (it's a terminal), so it works identically under X11 and Wayland.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const esc = "\x1b";
pub const alt_screen_enter = esc ++ "[?1049h";
pub const alt_screen_leave = esc ++ "[?1049l";
pub const cursor_hide = esc ++ "[?25l";
pub const cursor_show = esc ++ "[?25h";
pub const cursor_home = esc ++ "[H";
pub const clear_screen = esc ++ "[2J";
pub const clear_to_eol = esc ++ "[K";
pub const reset = esc ++ "[0m";
pub const bold = esc ++ "[1m";
pub const dim = esc ++ "[2m";

const winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

pub const Size = struct { rows: u16, cols: u16 };

/// Owns the terminal: a tty fd for input, saved termios, and screen state.
pub const Term = struct {
    io: std.Io,
    tty: std.Io.File,
    out_fd: i32,
    orig: posix.termios,
    raw_active: bool = false,

    pub fn init(io: std.Io) !Term {
        // Keys come from the controlling terminal even when stdin is a pipe.
        const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{});
        const orig = try posix.tcgetattr(tty.handle);
        return .{
            .io = io,
            .tty = tty,
            .out_fd = std.Io.File.stdout().handle,
            .orig = orig,
        };
    }

    pub fn deinit(self: *Term) void {
        self.tty.close(self.io);
    }

    pub fn enterRaw(self: *Term) !void {
        var raw = self.orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        try posix.tcsetattr(self.tty.handle, .FLUSH, raw);
        self.raw_active = true;
    }

    pub fn leaveRaw(self: *Term) void {
        if (!self.raw_active) return;
        posix.tcsetattr(self.tty.handle, .FLUSH, self.orig) catch {};
        self.raw_active = false;
    }

    pub fn size(self: *Term) Size {
        var ws: winsize = undefined;
        const rc = linux.ioctl(self.out_fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (linux.errno(rc) != .SUCCESS or ws.col == 0) return .{ .rows = 40, .cols = 100 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// Read pending key bytes from the tty (after poll says it's readable).
    pub fn readKeys(self: *Term, buf: []u8) []const u8 {
        const rc = linux.read(self.tty.handle, buf.ptr, buf.len);
        if (linux.errno(rc) != .SUCCESS) return buf[0..0];
        return buf[0..rc];
    }

    pub fn ttyFd(self: *Term) i32 {
        return self.tty.handle;
    }
};

/// Poll up to two fds for input with a millisecond timeout.
/// Returns a bitmask: bit0 = fds[0] readable, bit1 = fds[1] readable.
pub fn pollIn(fd0: i32, fd1: ?i32, timeout_ms: i32) u2 {
    var fds: [2]linux.pollfd = undefined;
    fds[0] = .{ .fd = fd0, .events = linux.POLL.IN, .revents = 0 };
    var n: linux.nfds_t = 1;
    if (fd1) |f| {
        fds[1] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
        n = 2;
    }
    const rc = linux.poll(&fds, n, timeout_ms);
    if (linux.errno(rc) != .SUCCESS) return 0;
    var mask: u2 = 0;
    if (fds[0].revents & linux.POLL.IN != 0) mask |= 0b01;
    if (fd1 != null and fds[1].revents & linux.POLL.IN != 0) mask |= 0b10;
    return mask;
}
