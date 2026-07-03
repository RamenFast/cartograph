//! Stub stand-in for the eBPF source, used when the project is built **without**
//! `-Dbpf=true`. It keeps surveyor's `Source` seam source-agnostic: `BpfCapturer.init`
//! always reports the source is unavailable, so surveyor falls back to the unprivileged
//! inet_diag path. Build with `-Dbpf=true` to compile the real loader (bpf.zig) — which
//! also needs clang + bpftool at build time and `setcap` at run time.

const std = @import("std");
const cartograph = @import("cartograph");

pub const built = false;

pub const BpfCapturer = struct {
    dns_filter_fd: i32 = -1,

    pub fn init(_: std.mem.Allocator) !BpfCapturer {
        return error.BpfNotBuilt;
    }
    pub fn deinit(_: *BpfCapturer) void {}
    pub fn drain(_: *BpfCapturer, _: *cartograph.FlowTable, _: i64) !void {}
};
