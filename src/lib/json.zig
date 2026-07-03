//! NDJSON projection of the view-model — the agent/script surface.
//!
//! A real Unix program speaks plain text any tool (or any AI, or any kid with `jq`)
//! can parse. This emits one flow as one JSON object on one line — line-oriented,
//! streamable, greppable, stable field names. It is *another renderer over the same
//! `Flow`*, so the agent surface can never drift from what the TUI shows (parity).
//!
//! Schema contract: see docs/AGENT-INTERFACE.md. Field names are stable; numbers are
//! numbers; `pid: 0` means unattributed (kernel/other-user); addresses are bare
//! strings with the port as a separate number.

const std = @import("std");
const Writer = std.Io.Writer;
const flow = @import("flow.zig");
const identity = @import("identity.zig");
const lens = @import("lens.zig");
const scope = @import("scope.zig");
const focusmod = @import("focus.zig");
const ipc = @import("ipc.zig");
const Flow = flow.Flow;

/// Write one flow as a single NDJSON line (no trailing newline; caller adds it).
/// This is the stable `snapshot --json` shape: a bare flow object, no envelope.
pub fn writeFlow(w: *Writer, f: *const Flow) Writer.Error!void {
    try w.writeByte('{');
    try writeFlowFields(w, f, false);
    try w.writeByte('}');
}

/// Write a flow as one event line on the `serve --json` stream: the same fields,
/// tagged with `"ev":"flow"` so an agent watching the live stream can branch on the
/// event kind while reading the *identical* flow fields it gets from `snapshot --json`.
pub fn writeFlowEvent(w: *Writer, f: *const Flow) Writer.Error!void {
    try w.writeAll("{\"ev\":\"flow\"");
    try writeFlowFields(w, f, true);
    try w.writeByte('}');
}

/// The flow fields themselves, brace-free, so the bare object (`snapshot`) and the
/// enveloped event (`serve --json`) share one field list and can never drift apart.
/// `lead_comma` = the first field needs a leading comma (it follows `"ev":"flow"`).
fn writeFlowFields(w: *Writer, f: *const Flow, lead_comma: bool) Writer.Error!void {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    try field(w, "proto", lead_comma);
    try str(w, f.key.proto.label());
    try field(w, "state", true);
    try str(w, f.state.label());
    try field(w, "category", true);
    try str(w, f.category.label());
    try field(w, "service", true);
    try str(w, f.service().label());
    try field(w, "exposure", true);
    try str(w, f.exposure().label());
    try field(w, "pid", true);
    try w.print("{d}", .{f.pid});
    try field(w, "uid", true);
    try w.print("{d}", .{f.uid});
    try field(w, "comm", true);
    try str(w, f.comm.slice());
    try field(w, "exe", true);
    try str(w, f.exe.slice());
    try field(w, "local", true);
    try str(w, f.key.local.fmt(&ab));
    try field(w, "local_port", true);
    try w.print("{d}", .{f.key.local_port});
    try field(w, "remote", true);
    try str(w, f.key.remote.fmt(&bb));
    try field(w, "remote_port", true);
    try w.print("{d}", .{f.key.remote_port});
    try field(w, "remote_name", true);
    try str(w, f.remote_name.slice());
    try field(w, "asn", true);
    try w.print("{d}", .{f.asn});
    try field(w, "as_org", true);
    try str(w, f.as_org.slice());
    try field(w, "country", true);
    try str(w, if (f.country[0] != 0) &f.country else "");
    try field(w, "rx_bytes", true);
    try w.print("{d}", .{f.rx_bytes});
    try field(w, "tx_bytes", true);
    try w.print("{d}", .{f.tx_bytes});
    try field(w, "rx_rate", true);
    try w.print("{d}", .{f.rx_rate});
    try field(w, "tx_rate", true);
    try w.print("{d}", .{f.tx_rate});
    try field(w, "rtt_us", true);
    try w.print("{d}", .{f.rtt_us});
    try field(w, "fresh", true);
    try w.writeAll(if (f.fresh) "true" else "false");
    try field(w, "first_seen_ms", true);
    try w.print("{d}", .{f.first_seen_ms});
    try field(w, "last_seen_ms", true);
    try w.print("{d}", .{f.last_seen_ms});
}

// ---- event-stream lines (the text twin of the binary IPC, AGENT-INTERFACE.md) ----
// `serve --json` emits one of these per line so an agent watches the *same* live
// view-model the GUI renders — flow upserts, closes, and tick boundaries — instead of
// re-polling a one-shot snapshot. Each line is self-identifying via `"ev"`.

pub fn writeHelloEvent(w: *Writer, proto_version: u16) Writer.Error!void {
    try w.print("{{\"ev\":\"hello\",\"proto_version\":{d}}}", .{proto_version});
}

/// A flow that ended this tick — carries just its key (the same identity fields the
/// `flow` event leads with), so an agent can drop the row it was tracking.
pub fn writeClosedEvent(w: *Writer, key: flow.FlowKey) Writer.Error!void {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    try w.writeAll("{\"ev\":\"closed\"");
    try field(w, "proto", true);
    try str(w, key.proto.label());
    try field(w, "local", true);
    try str(w, key.local.fmt(&ab));
    try field(w, "local_port", true);
    try w.print("{d}", .{key.local_port});
    try field(w, "remote", true);
    try str(w, key.remote.fmt(&bb));
    try field(w, "remote_port", true);
    try w.print("{d}}}", .{key.remote_port});
}

/// The shared cursor (focus.zig, R1) as the agent's own-fidelity rendering: the *same* state
/// the human's window holds, rendered as JSON instead of pixels (Ben — "different UI, same
/// accuracy"). `desc` carries the identical plain-language line the human's "Why" header shows,
/// so the agent narrates from one source. `entity` is always a string; read `entity_kind` to
/// interpret it (host=address, app=name, asn=number-as-string).
pub fn writeFocusEvent(w: *Writer, f: focusmod.Focus) Writer.Error!void {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    var db: [160]u8 = undefined;
    try w.writeAll("{\"ev\":\"focus\"");
    try field(w, "altitude", true);
    try str(w, f.altitude.label());
    try field(w, "shared", true);
    try w.writeAll(if (f.shared) "true" else "false");
    try field(w, "target", true);
    switch (f.target) {
        .machine => try str(w, "machine"),
        .entity => |ek| {
            try str(w, "entity");
            try field(w, "entity_kind", true);
            switch (ek) {
                .host => |a| {
                    try str(w, "host");
                    try field(w, "entity", true);
                    try str(w, a.fmt(&ab));
                },
                .app => |s| {
                    try str(w, "app");
                    try field(w, "entity", true);
                    try str(w, s.slice());
                },
                .asn => |n| {
                    try str(w, "asn");
                    try field(w, "entity", true);
                    var nb: [16]u8 = undefined;
                    try str(w, std.fmt.bufPrint(&nb, "{d}", .{n}) catch "0");
                },
            }
        },
        .flow => |fk| {
            try str(w, "flow");
            try field(w, "proto", true);
            try str(w, fk.proto.label());
            try field(w, "local", true);
            try str(w, fk.local.fmt(&ab));
            try field(w, "local_port", true);
            try w.print("{d}", .{fk.local_port});
            try field(w, "remote", true);
            try str(w, fk.remote.fmt(&bb));
            try field(w, "remote_port", true);
            try w.print("{d}", .{fk.remote_port});
        },
    }
    try field(w, "desc", true);
    try str(w, f.describe(&db));
    try w.writeByte('}');
}

/// End-of-batch marker: every flow/closed line since the last tick is now consistent.
/// `at_ms` is surveyor's clock; `flows` is the live count, so an agent gets a heartbeat
/// even when nothing changed.
pub fn writeTickEvent(w: *Writer, at_ms: i64, flows: usize) Writer.Error!void {
    try w.print("{{\"ev\":\"tick\",\"at_ms\":{d},\"flows\":{d}}}", .{ at_ms, flows });
}

fn field(w: *Writer, name: []const u8, comma: bool) Writer.Error!void {
    if (comma) try w.writeByte(',');
    try str(w, name);
    try w.writeByte(':');
}

// ---- the self-describing surface (`surveyor --schema`) ----------------------
// "No AI left out" (D18) means a model that has never seen this tool can run one
// command and learn the whole contract — field names, event kinds, and every closed
// vocabulary — with zero prior training. The enum lists are generated from the actual
// enums at comptime, so the schema can never lie about what the code emits.

fn jsonStrArray(w: *Writer, comptime E: type) Writer.Error!void {
    try w.writeByte('[');
    inline for (std.enums.values(E), 0..) |v, i| {
        if (i != 0) try w.writeByte(',');
        try str(w, v.label());
    }
    try w.writeByte(']');
}

fn fieldDoc(w: *Writer, name: []const u8, typ: []const u8, note: []const u8) Writer.Error!void {
    try w.writeAll("{\"name\":");
    try str(w, name);
    try w.writeAll(",\"type\":");
    try str(w, typ);
    try w.writeAll(",\"note\":");
    try str(w, note);
    try w.writeByte('}');
}

/// Emit the full machine-readable contract for every text surface. One document, valid
/// JSON, lightly indented so it reads to a human too (the kid and the agent, same pipe).
pub fn writeSchema(w: *Writer) Writer.Error!void {
    try w.print("{{\n  \"tool\": \"cartograph/surveyor\",\n  \"protocol_version\": {d},\n", .{ipc.protocol_version});
    try w.writeAll(
        \\  "surfaces": {
        \\    "snapshot_json": "surveyor snapshot --json  -> one bare Flow object per line (NDJSON); stable field names",
        \\    "event_stream":  "surveyor serve --json     -> one event object per line; ev in [hello,flow,closed,tick]",
        \\    "binary_ipc":    "surveyor serve            -> length-prefixed binary frames (the GUI/TUI hot path)"
        \\  },
        \\  "flow_fields": [
        \\
    );
    // The fields, in emit order — must match writeFlowFields above (the documented contract).
    const fields = [_][3][]const u8{
        .{ "proto", "string", "tcp | udp" },
        .{ "state", "string", "ESTAB, LISTEN, TIME_WAIT, ..." },
        .{ "category", "string", "coarse color/glyph bucket (see enums.category)" },
        .{ "service", "string", "daemon-precise service, attribution-independent (enums.service)" },
        .{ "exposure", "string", "listener attack-surface (enums.exposure); none if not a listener" },
        .{ "pid", "number", "0 = unattributed (kernel/other-user/short-lived)" },
        .{ "uid", "number", "owning user id" },
        .{ "comm", "string", "process short name (may be empty)" },
        .{ "exe", "string", "resolved executable path (may be empty)" },
        .{ "local", "string", "bare address, no brackets (v4 dotted, v6 compressed)" },
        .{ "local_port", "number", "" },
        .{ "remote", "string", "bare address, no brackets" },
        .{ "remote_port", "number", "" },
        .{ "remote_name", "string", "hostname (rDNS today, SNI/passive-DNS later); empty = unknown" },
        .{ "asn", "number", "autonomous system number; 0 = unknown" },
        .{ "as_org", "string", "AS organization (who owns the remote); empty = unknown" },
        .{ "country", "string", "ISO 3166-1 alpha-2 of the remote; empty = unknown" },
        .{ "rx_bytes", "number", "cumulative bytes (inet_diag; TCP)" },
        .{ "tx_bytes", "number", "cumulative bytes" },
        .{ "rx_rate", "number", "bytes/sec, derived between ticks" },
        .{ "tx_rate", "number", "bytes/sec, derived between ticks" },
        .{ "rtt_us", "number", "smoothed RTT, microseconds (0 if unknown)" },
        .{ "fresh", "bool", "first-seen this run" },
        .{ "first_seen_ms", "number", "epoch milliseconds" },
        .{ "last_seen_ms", "number", "epoch milliseconds" },
    };
    for (fields, 0..) |fd, i| {
        if (i != 0) try w.writeAll(",\n    ");
        try fieldDoc(w, fd[0], fd[1], fd[2]);
    }
    try w.writeAll("\n  ],\n");
    try w.writeAll(
        \\  "events": [
        \\    {"ev":"hello","fields":["proto_version"]},
        \\    {"ev":"flow","fields":["<every flow_field above>"]},
        \\    {"ev":"closed","fields":["proto","local","local_port","remote","remote_port"]},
        \\    {"ev":"tick","fields":["at_ms","flows"]},
        \\    {"ev":"focus","fields":["altitude","shared","target","entity_kind","entity","proto","local","local_port","remote","remote_port","desc"],"note":"the shared cursor (R1): what is being looked at, at what altitude; target in [machine,entity,flow]"}
        \\  ],
        \\  "enums": {
        \\
    );
    try w.writeAll("\"proto\": ");
    try jsonStrArray(w, flow.Proto);
    try w.writeAll(",\n    \"category\": ");
    try jsonStrArray(w, identity.Category);
    try w.writeAll(",\n    \"service\": ");
    try jsonStrArray(w, identity.Service);
    try w.writeAll(",\n    \"exposure\": ");
    try jsonStrArray(w, identity.Exposure);
    try w.writeAll(",\n    \"lens\": ");
    try jsonStrArray(w, lens.Lens);
    try w.writeAll(",\n    \"profile\": ");
    try jsonStrArray(w, lens.Profile);
    try w.writeAll(",\n    \"scope\": ");
    try jsonStrArray(w, scope.Scope);
    try w.writeAll(",\n    \"altitude\": ");
    try jsonStrArray(w, focusmod.Altitude);
    try w.writeAll("\n  },\n");
    try w.writeAll(
        \\  "exit_codes": {"0":"ok","nonzero":"error (reason on stderr)"}
        \\}
    );
}

/// Write a JSON string literal with correct escaping.
fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...7, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "flow emits valid, parseable json" {
    const t = std.testing;
    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = flow.Addr.v4(.{ 192, 168, 1, 9 }),
        .local_port = 44330,
        .remote = flow.Addr.v4(.{ 160, 79, 104, 10 }),
        .remote_port = 443,
    } };
    f.state = .established;
    f.category = .web;
    f.pid = 81777;
    f.comm.set("clau\"de\n"); // force escaping
    f.exe.set("/usr/lib/x");
    f.rx_bytes = 410_000;
    f.rtt_us = 24_200;
    f.remote_name.set("api.anthropic.com");
    f.asn = 13335;
    f.as_org.set("CLOUDFLARENET");
    f.country = .{ 'U', 'S' };

    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeFlow(&w, &f);
    const out = w.buffered();

    // Parses as JSON, and key fields survive.
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try t.expectEqualStrings("tcp", obj.get("proto").?.string);
    try t.expectEqualStrings("clau\"de\n", obj.get("comm").?.string);
    try t.expectEqual(@as(i64, 81777), obj.get("pid").?.integer);
    try t.expectEqual(@as(i64, 410_000), obj.get("rx_bytes").?.integer);
    try t.expectEqualStrings("160.79.104.10", obj.get("remote").?.string);
    try t.expectEqual(@as(i64, 443), obj.get("remote_port").?.integer);
    // the `?`-flow answer is on the agent surface too (derived, always present)
    try t.expectEqualStrings("https", obj.get("service").?.string);
    try t.expectEqualStrings("none", obj.get("exposure").?.string);
    // the S1 identity fields ride the same line
    try t.expectEqualStrings("api.anthropic.com", obj.get("remote_name").?.string);
    try t.expectEqual(@as(i64, 13335), obj.get("asn").?.integer);
    try t.expectEqualStrings("CLOUDFLARENET", obj.get("as_org").?.string);
    try t.expectEqualStrings("US", obj.get("country").?.string);
}

test "unknown identity emits empty strings, not garbage" {
    const t = std.testing;
    var f: Flow = .{ .key = .{ .proto = .udp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 5353, .remote = flow.Addr.v4(.{ 224, 0, 0, 251 }), .remote_port = 5353 } };
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeFlow(&w, &f);
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
    defer p.deinit();
    try t.expectEqualStrings("", p.value.object.get("remote_name").?.string);
    try t.expectEqual(@as(i64, 0), p.value.object.get("asn").?.integer);
    try t.expectEqualStrings("", p.value.object.get("country").?.string);
}

test "event-stream lines parse and carry the right discriminator" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;

    // a flow event carries the same fields as a bare flow, tagged ev:flow
    var f: Flow = .{ .key = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 5, .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 } };
    f.state = .established;
    f.category = .web;
    {
        var w = Writer.fixed(&buf);
        try writeFlowEvent(&w, &f);
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        try t.expectEqualStrings("flow", p.value.object.get("ev").?.string);
        try t.expectEqualStrings("tcp", p.value.object.get("proto").?.string); // fields still present
        try t.expectEqual(@as(i64, 443), p.value.object.get("remote_port").?.integer);
    }
    // a closed event carries just the key
    {
        var w = Writer.fixed(&buf);
        try writeClosedEvent(&w, f.key);
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        try t.expectEqualStrings("closed", p.value.object.get("ev").?.string);
        try t.expectEqualStrings("1.1.1.1", p.value.object.get("remote").?.string);
    }
    // hello + tick are well-formed
    {
        var w = Writer.fixed(&buf);
        try writeHelloEvent(&w, 2);
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        try t.expectEqual(@as(i64, 2), p.value.object.get("proto_version").?.integer);
    }
    {
        var w = Writer.fixed(&buf);
        try writeTickEvent(&w, 1700, 7);
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        try t.expectEqualStrings("tick", p.value.object.get("ev").?.string);
        try t.expectEqual(@as(i64, 7), p.value.object.get("flows").?.integer);
    }
}

test "focus event is the agent's JSON rendering of the cursor (R1)" {
    const t = std.testing;
    var buf: [512]u8 = undefined;

    // a flow-altitude shared cursor
    const key: flow.FlowKey = .{ .proto = .tcp, .local = flow.Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 5, .remote = flow.Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 };
    {
        var w = Writer.fixed(&buf);
        try writeFocusEvent(&w, .{ .altitude = .street, .target = .{ .flow = key }, .shared = true });
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        const o = p.value.object;
        try t.expectEqualStrings("focus", o.get("ev").?.string);
        try t.expectEqualStrings("street", o.get("altitude").?.string);
        try t.expectEqualStrings("flow", o.get("target").?.string);
        try t.expectEqualStrings("1.1.1.1", o.get("remote").?.string);
        try t.expect(o.get("shared").?.bool);
        try t.expect(o.get("desc").?.string.len > 0); // the human's line is on the agent surface too
    }
    // an entity cursor carries kind + value as strings
    {
        var w = Writer.fixed(&buf);
        try writeFocusEvent(&w, .{ .altitude = .region, .target = .{ .entity = .{ .asn = 13335 } } });
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        const o = p.value.object;
        try t.expectEqualStrings("entity", o.get("target").?.string);
        try t.expectEqualStrings("asn", o.get("entity_kind").?.string);
        try t.expectEqualStrings("13335", o.get("entity").?.string);
    }
}

test "schema is valid JSON and its enums match the code (no drift)" {
    const t = std.testing;
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeSchema(&w);
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
    defer p.deinit();
    const root = p.value.object;
    // the schema describes every flow field the writer emits
    try t.expectEqual(@as(usize, 25), root.get("flow_fields").?.array.items.len);
    // and the category vocabulary is generated from the enum, so counts must agree
    const cats = root.get("enums").?.object.get("category").?.array;
    try t.expectEqual(std.enums.values(identity.Category).len, cats.items.len);
    try t.expectEqual(@as(usize, 5), root.get("events").?.array.items.len); // hello/flow/closed/tick/focus
    // the altitude vocabulary is generated from the enum too
    const alts = root.get("enums").?.object.get("altitude").?.array;
    try t.expectEqual(std.enums.values(focusmod.Altitude).len, alts.items.len);
}
