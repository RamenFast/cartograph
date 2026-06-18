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

    // --- bpf: the eBPF capture source, gated behind -Dbpf ----------------------
    // Default OFF so the base build stays the proven unprivileged path with no extra
    // toolchain. -Dbpf=true compiles the CO-RE object (clang + bpftool, needs BTF) and
    // links libbpf; loading it then needs setcap (ARCHITECTURE.md). When off, surveyor
    // imports a stub so its `Source` seam is identical either way.
    const want_bpf = b.option(bool, "bpf", "Build the eBPF capture source (clang+bpftool at build; setcap at run)") orelse false;
    const bpf_mod = if (want_bpf) blk: {
        const m = b.addModule("bpf", .{
            .root_source_file = b.path("src/capture/bpf.zig"),
            .target = target,
            .link_libc = true,
            .imports = &.{.{ .name = "cartograph", .module = cartograph }},
        });
        m.addAnonymousImport("cartograph_bpf_obj", .{ .root_source_file = compileBpfObject(b) });
        m.linkSystemLibrary("bpf", .{});
        m.linkSystemLibrary("elf", .{});
        m.linkSystemLibrary("z", .{});
        break :blk m;
    } else b.addModule("bpf", .{
        .root_source_file = b.path("src/capture/bpf_stub.zig"),
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
                .{ .name = "bpf", .module = bpf_mod },
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
    if (want_bpf) { // the eBPF decode tests link libbpf; only run them when bpf is built
        const bpf_tests = b.addTest(.{ .root_module = bpf_mod });
        test_step.dependOn(&b.addRunArtifact(bpf_tests).step);
    }
}

/// Compile the CO-RE eBPF object with clang, generating `vmlinux.h` from the running
/// kernel's BTF (D3). Returns the object's path for `@embedFile` into the bpf module.
fn compileBpfObject(b: *std.Build) std.Build.LazyPath {
    const dump = b.addSystemCommand(&.{ "bpftool", "btf", "dump", "file", "/sys/kernel/btf/vmlinux", "format", "c" });
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(dump.captureStdOut(.{}), "vmlinux.h");

    const clang = b.addSystemCommand(&.{ "clang", "-g", "-O2", "-target", "bpf", "-D__TARGET_ARCH_x86", "-c" });
    clang.addArg("-I");
    clang.addDirectoryArg(wf.getDirectory()); // where vmlinux.h landed
    clang.addArg("-I");
    clang.addDirectoryArg(b.path("src/capture/bpf")); // event.h
    clang.addArg("-I/usr/include"); // bpf/ helper headers
    clang.addFileArg(b.path("src/capture/bpf/cartograph.bpf.c"));
    clang.addArg("-o");
    return clang.addOutputFileArg("cartograph.bpf.o");
}
