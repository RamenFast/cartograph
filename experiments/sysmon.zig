// cartograph · sysmon spike — GPU + system telemetry, unprivileged, in pure Zig.
//
// Proves the "see your whole computer" cross-resource stream (VISION foresight):
// the same app that maps packets can show what the AMD GPU / CPU / RAM are doing,
// read straight from sysfs/procfs with zero privilege and zero deps.
//
//   ../toolchain/zig run experiments/sysmon.zig

const std = @import("std");

const RST = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const GRN = "\x1b[32m";
const YEL = "\x1b[33m";
const CYAN = "\x1b[36m";
const MAG = "\x1b[35m";

fn read1(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    const c = try std.Io.Dir.cwd().readFile(io, path, buf);
    return std.mem.trimEnd(u8, c, " \n");
}

fn readU64(io: std.Io, path: []const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const s = read1(io, path, &buf) catch return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn isCard(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "card")) return false;
    const rest = name["card".len..];
    if (rest.len == 0) return false;
    for (rest) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Find the first DRM card exposing gpu_busy_percent; returns "/sys/class/drm/<card>/device".
fn findCardBase(io: std.Io, out: []u8) ?[]const u8 {
    const drm = std.Io.Dir.openDirAbsolute(io, "/sys/class/drm", .{ .iterate = true }) catch return null;
    defer drm.close(io);
    var it = drm.iterate();
    while (it.next(io) catch null) |de| {
        if (!isCard(de.name)) continue;
        const base = std.fmt.bufPrint(out, "/sys/class/drm/{s}/device", .{de.name}) catch continue;
        var probe: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&probe, "{s}/gpu_busy_percent", .{base}) catch continue;
        var tmp: [32]u8 = undefined;
        _ = read1(io, p, &tmp) catch continue;
        return base;
    }
    return null;
}

fn firstHwmon(io: std.Io, base: []const u8, out: []u8) ?[]const u8 {
    var pbuf: [160]u8 = undefined;
    const hwdir = std.fmt.bufPrint(&pbuf, "{s}/hwmon", .{base}) catch return null;
    const d = std.Io.Dir.openDirAbsolute(io, hwdir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |de| {
        if (!std.mem.startsWith(u8, de.name, "hwmon")) continue;
        return std.fmt.bufPrint(out, "{s}/hwmon/{s}", .{ base, de.name }) catch return null;
    }
    return null;
}

const GiB: f64 = 1024.0 * 1024.0 * 1024.0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const out = std.Io.File.stdout();
    var wbuf: [8192]u8 = undefined;
    var fw = out.writer(io, &wbuf);
    const w = &fw.interface;

    try w.print("{s}cartograph · sysmon{s} {s}— GPU + system telemetry (unprivileged, AMD Radeon){s}\n\n", .{ BOLD, RST, DIM, RST });

    var basebuf: [160]u8 = undefined;
    const base = findCardBase(io, &basebuf) orelse {
        try w.print("  no amdgpu card with gpu_busy_percent found\n", .{});
        try w.flush();
        return;
    };

    var pbuf: [224]u8 = undefined;
    const busy = readU64(io, std.fmt.bufPrint(&pbuf, "{s}/gpu_busy_percent", .{base}) catch "") orelse 0;
    const vused = readU64(io, std.fmt.bufPrint(&pbuf, "{s}/mem_info_vram_used", .{base}) catch "") orelse 0;
    const vtotal = readU64(io, std.fmt.bufPrint(&pbuf, "{s}/mem_info_vram_total", .{base}) catch "") orelse 1;

    var hwbuf: [192]u8 = undefined;
    var power_w: f64 = -1;
    var temp_c: f64 = -1;
    if (firstHwmon(io, base, &hwbuf)) |h| {
        if (readU64(io, std.fmt.bufPrint(&pbuf, "{s}/power1_average", .{h}) catch "")) |p|
            power_w = @as(f64, @floatFromInt(p)) / 1_000_000.0;
        if (readU64(io, std.fmt.bufPrint(&pbuf, "{s}/temp1_input", .{h}) catch "")) |t|
            temp_c = @as(f64, @floatFromInt(t)) / 1000.0;
    }

    try w.print("  {s}GPU{s}   busy {s}{d:>3}%{s}   VRAM {d:.1}/{d:.1} GiB", .{
        MAG, RST, GRN, busy, RST,
        @as(f64, @floatFromInt(vused)) / GiB,
        @as(f64, @floatFromInt(vtotal)) / GiB,
    });
    if (power_w >= 0) try w.print("   {d:.1} W", .{power_w});
    if (temp_c >= 0) try w.print("   {d:.0}°C", .{temp_c});
    try w.print("\n", .{});

    var lbuf: [160]u8 = undefined;
    const load = read1(io, "/proc/loadavg", &lbuf) catch "?";
    try w.print("  {s}SYS{s}   loadavg {s}{s}{s}\n", .{ CYAN, RST, YEL, load, RST });

    try w.print("\n{s}  → this is the seed of \"see your whole computer\": net + GPU + CPU as one place.{s}\n", .{ DIM, RST });
    try w.flush();
}
