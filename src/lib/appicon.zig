//! App icons — map a running process to its XDG icon name (V1/S4).
//!
//! A flow's `comm`/`exe` names the process; a desktop environment already knows
//! that process's icon, in its `.desktop` entry (`Exec=` + `Icon=`). This resolves
//! one to the other so a frontend can draw the *real* app icon (firefox's fox,
//! Steam's gear) instead of a generic glyph — offline, unprivileged, from files
//! already on the box.
//!
//! Split: the parse (`entryOf`) and the match (`Index.lookup`) are pure and tested;
//! `Index.scan` reads the standard XDG application dirs to populate the index. The
//! resolution lives here in `src/lib` (a feature never lives in a frontend, D9) —
//! GTK just calls `lookup` and hands the name to `gtk_image_new_from_icon_name`.
//! The name only *renders* in GTK, so it does not travel the wire or the Flow.

const std = @import("std");
const flow = @import("flow.zig");

/// One parsed desktop entry: the Exec binary's basename → its icon name.
pub const Entry = struct {
    exec: flow.Str(64), // basename of the first Exec token ("firefox", "steam")
    icon: flow.Str(128), // Icon= value (an icon-theme name or an absolute path)
};

/// Parse a `.desktop` file's bytes. Reads the `[Desktop Entry]` group's `Exec` and
/// `Icon` keys (first occurrence wins, matching the spec). Null when either is
/// missing — an entry we can't map to a binary or an icon is not useful.
pub fn entryOf(bytes: []const u8) ?Entry {
    var exec: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var in_group = false;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') { // a new group — we only read [Desktop Entry]
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        const val = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        if (icon == null and std.mem.eql(u8, key, "Icon")) {
            icon = val;
        } else if (exec == null and std.mem.eql(u8, key, "Exec")) {
            exec = execBasename(val);
        }
    }

    const e = exec orelse return null;
    const ic = icon orelse return null;
    if (e.len == 0 or ic.len == 0) return null;
    return .{ .exec = flow.Str(64).from(e), .icon = flow.Str(128).from(ic) };
}

/// The program basename from an `Exec=` value: strip field codes (`%u`), env
/// wrappers (`env A=b prog`), and any directory — `/usr/bin/firefox %u` → `firefox`.
fn execBasename(exec: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, exec, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0 or tok[0] == '%') continue;
        if (std.mem.eql(u8, tok, "env")) continue; // `env` wrapper
        if (std.mem.indexOfScalar(u8, tok, '=') != null) continue; // VAR=val before the program
        const slash = std.mem.lastIndexOfScalar(u8, tok, '/');
        return if (slash) |s| tok[s + 1 ..] else tok;
    }
    return "";
}

/// A resolved icon name index: process basename → icon-theme name. Case-folded on
/// the key so `Discord`/`discord` match. Owns its keys.
pub const Index = struct {
    map: std.StringHashMapUnmanaged(flow.Str(128)) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
    }

    pub fn count(self: *const Index) usize {
        return self.map.count();
    }

    /// Add one parsed entry (last write wins — later XDG dirs override earlier).
    pub fn add(self: *Index, e: Entry) !void {
        var keybuf: [64]u8 = undefined;
        const key = std.ascii.lowerString(keybuf[0..e.exec.len], e.exec.slice());
        const gop = try self.map.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
        }
        gop.value_ptr.* = e.icon;
    }

    /// The icon name for a flow, matched by `comm` first (the kernel's truth), then
    /// the `exe` basename. Null when nothing matches — the caller draws a fallback.
    pub fn lookup(self: *const Index, f: *const flow.Flow) ?[]const u8 {
        var keybuf: [64]u8 = undefined;
        if (f.comm.len > 0) {
            if (self.find(&keybuf, f.comm.slice())) |name| return name;
        }
        if (f.exe.len > 0) {
            const exe = f.exe.slice();
            const slash = std.mem.lastIndexOfScalar(u8, exe, '/');
            const base = if (slash) |s| exe[s + 1 ..] else exe;
            if (self.find(&keybuf, base)) |name| return name;
        }
        return null;
    }

    fn find(self: *const Index, keybuf: []u8, name: []const u8) ?[]const u8 {
        if (name.len > keybuf.len) return null;
        const key = std.ascii.lowerString(keybuf[0..name.len], name);
        return if (self.map.get(key)) |icon| icon.slice() else null;
    }

    /// Populate from the standard XDG application directories (best-effort: a dir
    /// that doesn't exist or a file that won't parse is silently skipped). `home`
    /// is $HOME; pass null to scan only the system dirs.
    pub fn scan(self: *Index, io: std.Io, home: ?[]const u8) void {
        var pathbuf: [512]u8 = undefined;
        if (home) |h| {
            const p = std.fmt.bufPrint(&pathbuf, "{s}/.local/share/applications", .{h}) catch return;
            self.scanDir(io, p);
        }
        for ([_][]const u8{
            "/usr/share/applications",
            "/usr/local/share/applications",
            "/var/lib/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications",
        }) |dir| self.scanDir(io, dir);
    }

    fn scanDir(self: *Index, io: std.Io, path: []const u8) void {
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        var buf: [64 * 1024]u8 = undefined;
        while (it.next(io) catch null) |de| {
            if (de.kind != .file) continue;
            if (!std.mem.endsWith(u8, de.name, ".desktop")) continue;
            const bytes = dir.readFile(io, de.name, &buf) catch continue;
            if (entryOf(bytes)) |e| self.add(e) catch {};
        }
    }
};

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "entryOf reads Exec basename and Icon, ignoring field codes and other groups" {
    const desktop =
        \\[Desktop Entry]
        \\Name=Firefox
        \\Exec=/usr/lib/firefox/firefox %u
        \\Icon=firefox
        \\
        \\[Desktop Action new-window]
        \\Exec=/usr/lib/firefox/firefox --new-window
        \\Icon=firefox-window
    ;
    const e = entryOf(desktop) orelse return error.ExpectedEntry;
    try testing.expectEqualStrings("firefox", e.exec.slice());
    try testing.expectEqualStrings("firefox", e.icon.slice()); // the action group's icon is ignored
}

test "entryOf handles env wrappers and VAR=val prefixes" {
    const desktop =
        \\[Desktop Entry]
        \\Exec=env GDK_BACKEND=x11 /opt/discord/Discord
        \\Icon=discord
    ;
    const e = entryOf(desktop).?;
    try testing.expectEqualStrings("Discord", e.exec.slice());
    try testing.expectEqualStrings("discord", e.icon.slice());
}

test "entryOf rejects an entry missing Exec or Icon" {
    try testing.expect(entryOf("[Desktop Entry]\nName=No Exec\nIcon=x") == null);
    try testing.expect(entryOf("[Desktop Entry]\nExec=foo\nName=No Icon") == null);
}

test "Index matches a flow by comm, then by exe basename, case-insensitively" {
    const gpa = testing.allocator;
    var idx = Index.init(gpa);
    defer idx.deinit();
    try idx.add(entryOf("[Desktop Entry]\nExec=firefox %u\nIcon=firefox").?);
    try idx.add(entryOf("[Desktop Entry]\nExec=/opt/discord/Discord\nIcon=discord").?);

    // by comm
    var f: flow.Flow = .{ .key = undefined };
    f.comm.set("firefox");
    try testing.expectEqualStrings("firefox", idx.lookup(&f).?);

    // case-folded comm (kernel comm can differ in case from the .desktop Exec)
    var g: flow.Flow = .{ .key = undefined };
    g.comm.set("discord");
    try testing.expectEqualStrings("discord", idx.lookup(&g).?);

    // by exe basename when comm doesn't match (comm is truncated to 15 for long names)
    var h: flow.Flow = .{ .key = undefined };
    h.comm.set("firefox-esr-bin"); // no such entry
    h.exe.set("/usr/lib/firefox/firefox");
    try testing.expectEqualStrings("firefox", idx.lookup(&h).?);

    // no match → null (caller draws a fallback)
    var m: flow.Flow = .{ .key = undefined };
    m.comm.set("sshd");
    try testing.expect(idx.lookup(&m) == null);
}

test "later add overrides earlier (user dir wins over system)" {
    const gpa = testing.allocator;
    var idx = Index.init(gpa);
    defer idx.deinit();
    try idx.add(entryOf("[Desktop Entry]\nExec=code\nIcon=com.visualstudio.code").?);
    try idx.add(entryOf("[Desktop Entry]\nExec=code\nIcon=code").?); // a later dir
    try testing.expectEqual(@as(usize, 1), idx.count());
    var f: flow.Flow = .{ .key = undefined };
    f.comm.set("code");
    try testing.expectEqualStrings("code", idx.lookup(&f).?);
}
