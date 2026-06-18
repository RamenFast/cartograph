const std = @import("std");

// Cartograph — M1 build graph.
//
//   libcartograph (module "cartograph")  — the frontend-agnostic view-model.
//   capture        (module "capture")     — the /proc capture core (imports cartograph).
//   surveyor       (exe)                   — privileged-core CLI: `snapshot` | `serve`.
//   cartograph     (exe)                   — the TUI frontend; in-process or over IPC.
//
// Parity by construction: every frontend renders the same `cartograph` view-model,
// and surveyor speaks the same `ipc` frames the frontend decodes.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- libcartograph: the shared, frontend-agnostic view-model ---------------
    const cartograph = b.addModule("cartograph", .{
        .root_source_file = b.path("src/lib/cartograph.zig"),
        .target = target,
    });

    // --- capture: the /proc-based capture core (unprivileged path) -------------
    const capture = b.addModule("capture", .{
        .root_source_file = b.path("src/capture/capture.zig"),
        .target = target,
        .imports = &.{.{ .name = "cartograph", .module = cartograph }},
    });

    // --- surveyor exe: the (eventually privileged) capture daemon / CLI --------
    const surveyor = b.addExecutable(.{
        .name = "surveyor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/surveyor/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cartograph", .module = cartograph },
                .{ .name = "capture", .module = capture },
            },
        }),
    });
    b.installArtifact(surveyor);

    // --- cartograph exe: the TUI frontend -------------------------------------
    const tui = b.addExecutable(.{
        .name = "cartograph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cartograph", .module = cartograph },
                .{ .name = "capture", .module = capture },
            },
        }),
    });
    b.installArtifact(tui);

    // --- man page -------------------------------------------------------------
    b.installFile("man/cartograph.1", "share/man/man1/cartograph.1");

    // --- `zig build run` → the live TUI (in-process capture) ------------------
    const run_step = b.step("run", "Run the live cartograph TUI");
    const run_cmd = b.addRunArtifact(tui);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // --- `zig build serve` → surveyor emitting IPC frames to stdout -----------
    const serve_step = b.step("serve", "Run surveyor in IPC-serve mode (frames to stdout)");
    const serve_cmd = b.addRunArtifact(surveyor);
    serve_cmd.addArg("serve");
    serve_cmd.step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve_cmd.step);

    // --- `zig build snapshot` → one-shot attributed flow table ----------------
    const snap_step = b.step("snapshot", "Print a one-shot attributed flow table");
    const snap_cmd = b.addRunArtifact(surveyor);
    snap_cmd.addArg("snapshot");
    snap_cmd.step.dependOn(b.getInstallStep());
    snap_step.dependOn(&snap_cmd.step);

    // --- `zig build test` → unit tests for the view-model + capture -----------
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = cartograph });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    const cap_tests = b.addTest(.{ .root_module = capture });
    test_step.dependOn(&b.addRunArtifact(cap_tests).step);
}
