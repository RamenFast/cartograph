//! A tiny fixed-size ring of recent throughput samples and a Unicode sparkline
//! renderer. Motion = truth: the map should breathe with your traffic.

const std = @import("std");
const Writer = std.Io.Writer;

pub const spark_len = 16;

const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// A ring of the last `spark_len` total-throughput samples (bytes/sec).
pub const RateRing = struct {
    samples: [spark_len]u32 = [_]u32{0} ** spark_len,
    head: u8 = 0, // index of the next slot to write
    count: u8 = 0,

    pub fn push(self: *RateRing, sample: u32) void {
        self.samples[self.head] = sample;
        self.head = (self.head + 1) % spark_len;
        if (self.count < spark_len) self.count += 1;
    }

    pub fn max(self: *const RateRing) u32 {
        var m: u32 = 0;
        for (self.samples) |s| m = @max(m, s);
        return m;
    }

    /// Render oldest→newest into `w`, scaled to the ring's own peak.
    pub fn write(self: *const RateRing, w: *Writer) Writer.Error!void {
        const peak = self.max();
        var i: usize = 0;
        while (i < spark_len) : (i += 1) {
            // walk from the oldest sample to the newest
            const idx = (@as(usize, self.head) + i) % spark_len;
            const filled = i >= spark_len - self.count;
            const v = self.samples[idx];
            const level: usize = if (!filled or peak == 0)
                0
            else
                @min(blocks.len - 1, 1 + (@as(usize, v) * (blocks.len - 2)) / peak);
            try w.writeAll(blocks[level]);
        }
    }
};

test "ring wraps and tracks peak" {
    const t = std.testing;
    var r: RateRing = .{};
    for (0..spark_len * 2) |i| r.push(@intCast(i));
    try t.expectEqual(@as(u8, spark_len), r.count);
    try t.expectEqual(@as(u32, spark_len * 2 - 1), r.max());
}

test "sparkline renders count glyphs" {
    const t = std.testing;
    var r: RateRing = .{};
    r.push(1);
    r.push(8);
    r.push(4);
    var buf: [128]u8 = undefined;
    var w = Writer.fixed(&buf);
    try r.write(&w);
    // spark_len glyphs, each 1..=3 UTF-8 bytes; just assert it produced output.
    try t.expect(w.buffered().len >= spark_len);
}
