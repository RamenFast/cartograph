//! The agent command grammar — the JSON lines an agent (or `surveyor ctl`) sends
//! *upstream* on the NDJSON socket to drive the live session (audit F3: "the agent
//! can observe but cannot control").
//!
//! One codec, two ends: `write*` builds the line `surveyor ctl` sends, `parse`
//! decodes it in the daemon — kept in one file so the two can never drift, and the
//! round-trip is provable in a unit test without a socket.
//!
//! The verb set is deliberately the *shared* session surface (D22): the shared
//! cursor (`focus`) that every observer follows — the human's GTK window included.
//! Profile/lens stay view-local by decision D22 (an agent must not hijack a human's
//! lens rail), so they are not commands here.
//!
//! Wire shape (one JSON object per line):
//!   {"cmd":"focus","target":"orbit"}
//!   {"cmd":"focus","target":"flow","proto":"tcp","local":"192.168.1.9","local_port":44330,
//!    "remote":"1.1.1.1","remote_port":443,"altitude":"street"}
//!   {"cmd":"focus","target":"app","app":"firefox"}
//!   {"cmd":"focus","target":"asn","asn":13335}
//!   {"cmd":"focus","target":"host","host":"140.82.121.4"}
//!
//! The daemon answers on the same socket:
//!   {"event":"ack","cmd":"focus","ok":true}
//!   {"event":"error","error":"...","fix":"..."}

const std = @import("std");
const Writer = std.Io.Writer;
const flow = @import("flow.zig");
const focusmod = @import("focus.zig");

/// A decoded upstream command. Focus targets arrive `shared = true` by construction:
/// an agent command *is* a proposal to move the session cursor (that is its purpose).
pub const Command = union(enum) {
    focus: focusmod.Focus,
    /// Subscribe to the NDJSON stream and do nothing else — the way a watch-only agent
    /// announces itself so the daemon knows this connection speaks JSON lines.
    watch,
};

/// A parse failure that names its fix — the daemon relays both fields verbatim on
/// the error line (the workspace error contract: an error without a fix is a bug).
pub const Error = struct {
    msg: []const u8,
    fix: []const u8,
};

pub const Result = union(enum) {
    command: Command,
    err: Error,
};

/// The wire struct std.json maps a command line onto. Every field optional so one
/// shape covers every verb; `parse` validates per-verb requirements afterwards.
const WireCmd = struct {
    cmd: []const u8,
    target: ?[]const u8 = null,
    altitude: ?[]const u8 = null,
    proto: ?[]const u8 = null,
    local: ?[]const u8 = null,
    local_port: ?u16 = null,
    remote: ?[]const u8 = null,
    remote_port: ?u16 = null,
    app: ?[]const u8 = null,
    asn: ?u32 = null,
    host: ?[]const u8 = null,
};

fn err(msg: []const u8, fix: []const u8) Result {
    return .{ .err = .{ .msg = msg, .fix = fix } };
}

/// Parse an IPv4/IPv6 address string into the view-model's Addr.
pub fn parseAddr(text: []const u8) ?flow.Addr {
    const ip = std.Io.net.IpAddress.parse(text, 0) catch return null;
    return switch (ip) {
        .ip4 => |a| flow.Addr.v4(a.bytes),
        .ip6 => |a| flow.Addr.v6(a.bytes),
    };
}

/// Decode one command line. Allocation is scoped to parsing (an arena the caller
/// provides or gpa — freed internally); the returned Command is plain value data.
pub fn parse(gpa: std.mem.Allocator, line: []const u8) Result {
    const parsed = std.json.parseFromSlice(WireCmd, gpa, line, .{
        .ignore_unknown_fields = true,
    }) catch return err(
        "unparseable command line",
        "send one JSON object per line, e.g. {\"cmd\":\"focus\",\"target\":\"orbit\"} — see `surveyor --schema`",
    );
    defer parsed.deinit();
    const c = parsed.value;

    if (std.mem.eql(u8, c.cmd, "focus")) return parseFocus(c);
    if (std.mem.eql(u8, c.cmd, "watch")) return .{ .command = .watch };
    return err(
        "unknown command",
        "supported: focus (targets: orbit, flow, app, asn, host), watch — see `surveyor --schema`",
    );
}

fn parseFocus(c: WireCmd) Result {
    const target = c.target orelse return err(
        "focus needs a target",
        "add \"target\": one of orbit, flow, app, asn, host",
    );

    if (std.mem.eql(u8, target, "orbit")) {
        return .{ .command = .{ .focus = .{ .shared = true } } };
    }

    if (std.mem.eql(u8, target, "flow")) {
        const proto_s = c.proto orelse return err("flow focus needs proto", "add \"proto\":\"tcp\" or \"udp\"");
        const proto: flow.Proto = if (std.mem.eql(u8, proto_s, "tcp"))
            .tcp
        else if (std.mem.eql(u8, proto_s, "udp"))
            .udp
        else
            return err("unknown proto", "use \"tcp\" or \"udp\"");
        const local = parseAddr(c.local orelse return err("flow focus needs local", "add \"local\":\"<addr>\" and \"local_port\"")) orelse
            return err("unparseable local address", "use a bare IPv4/IPv6 address, e.g. \"192.168.1.9\"");
        const remote = parseAddr(c.remote orelse return err("flow focus needs remote", "add \"remote\":\"<addr>\" and \"remote_port\"")) orelse
            return err("unparseable remote address", "use a bare IPv4/IPv6 address, e.g. \"1.1.1.1\"");
        const lp = c.local_port orelse return err("flow focus needs local_port", "add \"local_port\":<number>");
        const rp = c.remote_port orelse return err("flow focus needs remote_port", "add \"remote_port\":<number>");

        var altitude: focusmod.Altitude = .street;
        if (c.altitude) |alt| {
            if (std.mem.eql(u8, alt, "street")) {
                altitude = .street;
            } else if (std.mem.eql(u8, alt, "ground")) {
                altitude = .ground;
            } else return err("a flow focus is street or ground altitude", "use \"altitude\":\"street\" (default) or \"ground\"");
        }
        return .{ .command = .{ .focus = .{
            .altitude = altitude,
            .target = .{ .flow = .{ .proto = proto, .local = local, .local_port = lp, .remote = remote, .remote_port = rp } },
            .shared = true,
        } } };
    }

    if (std.mem.eql(u8, target, "app")) {
        const name = c.app orelse return err("app focus needs a name", "add \"app\":\"<comm>\", e.g. \"firefox\"");
        return .{ .command = .{ .focus = .{
            .altitude = .region,
            .target = .{ .entity = .{ .app = flow.Str(64).from(name) } },
            .shared = true,
        } } };
    }

    if (std.mem.eql(u8, target, "asn")) {
        const n = c.asn orelse return err("asn focus needs a number", "add \"asn\":<number>, e.g. 13335");
        return .{ .command = .{ .focus = .{
            .altitude = .region,
            .target = .{ .entity = .{ .asn = n } },
            .shared = true,
        } } };
    }

    if (std.mem.eql(u8, target, "host")) {
        const addr = parseAddr(c.host orelse return err("host focus needs an address", "add \"host\":\"<addr>\"")) orelse
            return err("unparseable host address", "use a bare IPv4/IPv6 address");
        return .{ .command = .{ .focus = .{
            .altitude = .region,
            .target = .{ .entity = .{ .host = addr } },
            .shared = true,
        } } };
    }

    return err("unknown focus target", "use one of: orbit, flow, app, asn, host");
}

// ---- the sending side (surveyor ctl / any agent) ------------------------------

/// Write the command line for a focus move — the exact JSON `parse` accepts.
/// (No trailing newline; the transport adds it.)
pub fn writeFocusCommand(w: *Writer, f: focusmod.Focus) Writer.Error!void {
    try w.writeAll("{\"cmd\":\"focus\"");
    switch (f.target) {
        .machine => try w.writeAll(",\"target\":\"orbit\""),
        .entity => |ek| switch (ek) {
            .app => |s| {
                try w.writeAll(",\"target\":\"app\",\"app\":");
                try jsonStr(w, s.slice());
            },
            .asn => |n| try w.print(",\"target\":\"asn\",\"asn\":{d}", .{n}),
            .host => |a| {
                var ab: [48]u8 = undefined;
                try w.writeAll(",\"target\":\"host\",\"host\":");
                try jsonStr(w, a.fmt(&ab));
            },
        },
        .flow => |fk| {
            var lb: [48]u8 = undefined;
            var rb: [48]u8 = undefined;
            try w.print(",\"target\":\"flow\",\"proto\":\"{s}\"", .{fk.proto.label()});
            try w.writeAll(",\"local\":");
            try jsonStr(w, fk.local.fmt(&lb));
            try w.print(",\"local_port\":{d}", .{fk.local_port});
            try w.writeAll(",\"remote\":");
            try jsonStr(w, fk.remote.fmt(&rb));
            try w.print(",\"remote_port\":{d},\"altitude\":\"{s}\"", .{ fk.remote_port, f.altitude.label() });
        },
    }
    try w.writeByte('}');
}

fn jsonStr(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => if (ch < 0x20) {
            try w.print("\\u{x:0>4}", .{ch});
        } else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(f: focusmod.Focus) !focusmod.Focus {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeFocusCommand(&w, f);
    const res = parse(testing.allocator, w.buffered());
    try testing.expect(res == .command);
    return res.command.focus;
}

test "focus commands round-trip the writer→parser codec (no drift possible)" {
    // orbit
    {
        const back = try roundTrip(.{});
        try testing.expect(back.target == .machine);
        try testing.expect(back.shared); // a command IS a shared-cursor proposal
    }
    // a street flow
    {
        const key: flow.FlowKey = .{
            .proto = .tcp,
            .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
            .local_port = 44330,
            .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }),
            .remote_port = 443,
        };
        const back = try roundTrip(.{ .altitude = .street, .target = .{ .flow = key } });
        try testing.expectEqual(focusmod.Altitude.street, back.altitude);
        try testing.expect(std.meta.eql(key, back.target.flow));
        try testing.expect(back.shared);
    }
    // a v6 ground flow
    {
        const key: flow.FlowKey = .{
            .proto = .tcp,
            .local = flow.Addr.v6(.{ 0xfe, 0x80 } ++ .{0} ** 13 ++ .{9}),
            .local_port = 55000,
            .remote = flow.Addr.v6(.{ 0x26, 0x06 } ++ .{0} ** 13 ++ .{1}),
            .remote_port = 443,
        };
        const back = try roundTrip(.{ .altitude = .ground, .target = .{ .flow = key } });
        try testing.expectEqual(focusmod.Altitude.ground, back.altitude);
        try testing.expect(std.meta.eql(key, back.target.flow));
    }
    // region entities
    {
        const back = try roundTrip(.{ .altitude = .region, .target = .{ .entity = .{ .app = flow.Str(64).from("firefox") } } });
        try testing.expectEqualStrings("firefox", back.target.entity.app.slice());
        try testing.expectEqual(focusmod.Altitude.region, back.altitude);
    }
    {
        const back = try roundTrip(.{ .altitude = .region, .target = .{ .entity = .{ .asn = 13335 } } });
        try testing.expectEqual(@as(u32, 13335), back.target.entity.asn);
    }
    {
        const back = try roundTrip(.{ .altitude = .region, .target = .{ .entity = .{ .host = flow.Addr.v4(.{ 140, 82, 121, 4 }) } } });
        try testing.expectEqualSlices(u8, &.{ 140, 82, 121, 4 }, back.target.entity.host.bytes[0..4]);
    }
}

test "watch is the agent's subscribe handshake" {
    const r = parse(testing.allocator, "{\"cmd\":\"watch\"}");
    try testing.expect(r == .command);
    try testing.expect(r.command == .watch);
}

test "bad commands fail with a fix, never a crash or a shrug" {
    const gpa = testing.allocator;
    // not JSON at all
    {
        const r = parse(gpa, "definitely not json");
        try testing.expect(r == .err);
        try testing.expect(r.err.fix.len > 0);
    }
    // an unknown verb names the supported set
    {
        const r = parse(gpa, "{\"cmd\":\"format-disk\"}");
        try testing.expect(r == .err);
        try testing.expect(std.mem.indexOf(u8, r.err.fix, "focus") != null);
    }
    // a flow focus missing its port names exactly the missing field
    {
        const r = parse(gpa,
            \\{"cmd":"focus","target":"flow","proto":"tcp","local":"1.2.3.4","remote":"5.6.7.8","remote_port":443}
        );
        try testing.expect(r == .err);
        try testing.expect(std.mem.indexOf(u8, r.err.msg, "local_port") != null);
    }
    // a garbage address is named, not guessed
    {
        const r = parse(gpa, "{\"cmd\":\"focus\",\"target\":\"host\",\"host\":\"not-an-ip\"}");
        try testing.expect(r == .err);
        try testing.expect(std.mem.indexOf(u8, r.err.msg, "unparseable") != null);
    }
    // altitude outside the flow's range is rejected
    {
        const r = parse(gpa,
            \\{"cmd":"focus","target":"flow","proto":"tcp","local":"1.2.3.4","local_port":1,"remote":"5.6.7.8","remote_port":443,"altitude":"orbit"}
        );
        try testing.expect(r == .err);
    }
}
