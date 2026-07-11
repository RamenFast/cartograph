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

/// The tool version for envelopes (workspace R2) — the same injected build.zig.zon
/// string every `--version` prints.
const tool_version: []const u8 = @import("buildinfo").version;

/// Write epoch-milliseconds as ISO-8601 UTC (`2026-07-11T21:40:00+00:00`) — the
/// workspace envelope's `ts` (R1). Epoch fields ride along as extras, never instead.
pub fn writeIso8601(w: *Writer, epoch_ms: i64) Writer.Error!void {
    const secs: u64 = @intCast(@max(0, @divFloor(epoch_ms, 1000)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        day.year,                 md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(),     ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
    });
}

/// The one-shot envelope opener (workspace convention §1): status/tool/version/ts.
/// Callers append their payload fields and the closing brace.
fn openEnvelope(w: *Writer, now_ms: i64) Writer.Error!void {
    try w.writeAll("{\"status\":\"ok\",\"tool\":\"surveyor\"");
    try field(w, "version", true);
    try str(w, tool_version);
    try field(w, "ts", true);
    try w.writeByte('"');
    try writeIso8601(w, now_ms);
    try w.writeByte('"');
}

/// Write one flow as a single NDJSON line (no trailing newline; caller adds it).
/// This is the stable `snapshot --json` shape: a bare flow object, no envelope.
pub fn writeFlow(w: *Writer, f: *const Flow) Writer.Error!void {
    try w.writeByte('{');
    try writeFlowFields(w, f, false);
    try w.writeByte('}');
}

/// Open an event line with its discriminator. Canonical field is **`event`**
/// (workspace R3, adopted at the v5 proto bump); the shipped `ev` rides along as a
/// legacy alias so existing `jq 'select(.ev==…)'` pipelines keep working. One helper
/// so no line can carry one tag and not the other.
fn eventTag(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll("{\"event\":");
    try str(w, name);
    try field(w, "ev", true);
    try str(w, name);
}

/// Write a flow as one event line on the `serve --json` stream: the same fields,
/// tagged `event:flow` so an agent watching the live stream can branch on the
/// event kind while reading the *identical* flow fields it gets from `snapshot --json`.
pub fn writeFlowEvent(w: *Writer, f: *const Flow) Writer.Error!void {
    try eventTag(w, "flow");
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
    try field(w, "ppid", true);
    try w.print("{d}", .{f.ppid});
    try field(w, "pcomm", true);
    try str(w, f.pcomm.slice());
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

/// One-shot `surveyor status`: the box's network posture as a **single JSON object**
/// (the station convention's one-shot shape, vs snapshot's per-flow NDJSON). The
/// agent's "what's my machine doing right now?" answer: listener inventory with
/// exposure/risk badges + summary counts. Same Flow source as every other renderer,
/// so it can never drift from what the TUI/GUI shows (parity).
pub fn writeStatus(w: *Writer, flows: []const *Flow, now_ms: i64, posture: ipc.Posture) Writer.Error!void {
    var attributed: usize = 0;
    var established: usize = 0;
    var listeners: usize = 0;
    var expo_loop: usize = 0;
    var expo_net: usize = 0;
    var expo_inet: usize = 0;
    for (flows) |f| {
        if (f.attributed()) attributed += 1;
        if (f.state == .established) established += 1;
        switch (f.exposure()) {
            .none => {},
            .loopback => expo_loop += 1,
            .network => expo_net += 1,
            .internet => expo_inet += 1,
        }
    }
    listeners = expo_loop + expo_net + expo_inet;

    try openEnvelope(w, now_ms);
    try field(w, "proto_version", true);
    try w.print("{d}", .{ipc.protocol_version});
    try field(w, "ts_ms", true);
    try w.print("{d}", .{now_ms});
    // Capture-mode truth (audit F14): what the stack is *actually* doing — polling vs the
    // eBPF hybrid, passive DNS, GeoIP dbs — so "everything looks fine" can't hide a
    // degraded posture from the one command whose whole job is posture.
    try field(w, "capture", true);
    try w.print("{{\"source\":\"{s}\",\"pdns\":{},\"geoip_asn\":{},\"geoip_country\":{}}}", .{
        posture.sourceLabel(), posture.pdns, posture.geoip_asn, posture.geoip_country,
    });
    try field(w, "flows", true);
    try w.print("{{\"total\":{d},\"attributed\":{d},\"established\":{d},\"listeners\":{d}}}", .{ flows.len, attributed, established, listeners });
    try field(w, "exposure", true);
    try w.print("{{\"loopback\":{d},\"network\":{d},\"internet\":{d}}}", .{ expo_loop, expo_net, expo_inet });
    try field(w, "listeners", true);
    try w.writeByte('[');
    var first = true;
    var ab: [64]u8 = undefined;
    for (flows) |f| {
        const expo = f.exposure();
        if (expo == .none) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('{');
        try field(w, "proto", false);
        try str(w, f.key.proto.label());
        try field(w, "local", true);
        try str(w, f.key.local.fmt(&ab));
        try field(w, "port", true);
        try w.print("{d}", .{f.key.local_port});
        try field(w, "pid", true);
        try w.print("{d}", .{f.pid});
        try field(w, "comm", true);
        try str(w, f.comm.slice());
        try field(w, "exe", true);
        try str(w, f.exe.slice());
        try field(w, "service", true);
        try str(w, f.service().label());
        try field(w, "exposure", true);
        try str(w, expo.label());
        try field(w, "badge", true);
        try str(w, expo.hex());
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

// ---- event-stream lines (the text twin of the binary IPC, AGENT-INTERFACE.md) ----
// `serve --json` emits one of these per line so an agent watches the *same* live
// view-model the GUI renders — flow upserts, closes, and tick boundaries — instead of
// re-polling a one-shot snapshot. Each line is self-identifying via `"ev"`.

pub fn writeHelloEvent(w: *Writer, proto_version: u16) Writer.Error!void {
    try eventTag(w, "hello");
    try w.print(",\"proto_version\":{d},\"tool\":\"surveyor\",\"version\":", .{proto_version});
    try str(w, tool_version);
    try w.writeByte('}');
}

/// A flow that ended this tick — carries just its key (the same identity fields the
/// `flow` event leads with), so an agent can drop the row it was tracking.
pub fn writeClosedEvent(w: *Writer, key: flow.FlowKey) Writer.Error!void {
    var ab: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    try eventTag(w, "closed");
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
    try eventTag(w, "focus");
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
    try eventTag(w, "tick");
    try w.print(",\"at_ms\":{d},\"ts\":\"", .{at_ms});
    try writeIso8601(w, at_ms);
    try w.print("\",\"flows\":{d}}}", .{flows});
}

/// Capture-mode truth on the stream (F14): emitted once after hello, and again if the
/// posture ever changes, so a watching agent knows whether "everything" means the eBPF
/// hybrid with true hostnames or polling-only with rDNS guesses.
pub fn writePostureEvent(w: *Writer, p: ipc.Posture) Writer.Error!void {
    try eventTag(w, "posture");
    try w.print(",\"source\":\"{s}\",\"pdns\":{},\"geoip_asn\":{},\"geoip_country\":{}}}", .{
        p.sourceLabel(), p.pdns, p.geoip_asn, p.geoip_country,
    });
}

/// The daemon's answer to an accepted agent command (F3): named verb, ok:true.
pub fn writeAckEvent(w: *Writer, cmd: []const u8) Writer.Error!void {
    try eventTag(w, "ack");
    try w.print(",\"cmd\":\"{s}\",\"ok\":true}}", .{cmd});
}

/// The daemon's answer to a rejected agent command: what failed and how to fix it
/// (the workspace error contract — an error without a fix is a bug).
pub fn writeErrorEvent(w: *Writer, msg: []const u8, fix: []const u8) Writer.Error!void {
    try eventTag(w, "error");
    try field(w, "error", true);
    try str(w, msg);
    try field(w, "fix", true);
    try str(w, fix);
    try w.writeByte('}');
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
/// A one-shot, so it carries the envelope too (workspace R5).
pub fn writeSchema(w: *Writer, now_ms: i64) Writer.Error!void {
    try w.writeAll("{\n  \"status\": \"ok\",\n  \"tool\": \"cartograph/surveyor\",\n  \"version\": ");
    try str(w, tool_version);
    try w.writeAll(",\n  \"ts\": \"");
    try writeIso8601(w, now_ms);
    try w.print("\",\n  \"protocol_version\": {d},\n", .{ipc.protocol_version});
    try w.writeAll(
        \\  "surfaces": {
        \\    "status_json":   "surveyor status            -> ONE JSON envelope: capture posture + listener inventory + exposure badges + flow counts (always JSON, declared per R6)",
        \\    "snapshot_json": "surveyor snapshot --json  -> one bare Flow object per line (NDJSON); stable field names",
        \\    "event_stream":  "surveyor serve --json     -> one event object per line; event in [hello,posture,focus,flow,closed,tick,ack,error]",
        \\    "binary_ipc":    "surveyor serve            -> length-prefixed binary frames (the GUI/TUI hot path)",
        \\    "session_daemon": "surveyor serve --socket <p> -> binary frames on <p>, duplex NDJSON on <p>.json: same events out, JSON command lines in",
        \\    "ctl":           "surveyor ctl focus <orbit|flow …|app <comm>|asn <n>|host <addr>> [--socket <p>] -> moves the live session's shared cursor; prints the ack/error line"
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
        .{ "ppid", "number", "parent pid (what launched this); 0 = unknown" },
        .{ "pcomm", "string", "parent process short name; empty = unknown" },
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
        \\    {"event":"hello","fields":["proto_version","tool","version"]},
        \\    {"event":"posture","fields":["source","pdns","geoip_asn","geoip_country"],"note":"capture-mode truth: source in [polling,ebpf+polling]; false = that enrichment is not live"},
        \\    {"event":"flow","fields":["<every flow_field above>"]},
        \\    {"event":"closed","fields":["proto","local","local_port","remote","remote_port"]},
        \\    {"event":"tick","fields":["at_ms","ts","flows"]},
        \\    {"event":"focus","fields":["altitude","shared","target","entity_kind","entity","proto","local","local_port","remote","remote_port","desc"],"note":"the shared cursor: what the session is looking at, at what altitude; target in [machine,entity,flow]; every line also carries legacy alias ev"},
        \\    {"event":"ack","fields":["cmd","ok"],"note":"a command was accepted"},
        \\    {"event":"error","fields":["error","fix"],"note":"a command was rejected; fix says how to repair it"}
        \\  ],
        \\  "commands": [
        \\    {"cmd":"watch","note":"subscribe-only handshake; optional"},
        \\    {"cmd":"focus","target":"orbit","note":"back to the whole machine"},
        \\    {"cmd":"focus","target":"flow","fields":["proto","local","local_port","remote","remote_port","altitude?"],"note":"altitude street (default) or ground"},
        \\    {"cmd":"focus","target":"app","fields":["app"]},
        \\    {"cmd":"focus","target":"asn","fields":["asn"]},
        \\    {"cmd":"focus","target":"host","fields":["host"]}
        \\  ],
        \\  "commands_note": "one JSON object per line on the daemon's .json socket; every focus command moves the SHARED session cursor — the human's window visibly follows",
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
        \\  "exit_codes": {"0":"ok","2":"unavailable/runtime failure (stderr names the fix)","3":"bad arguments/unknown verb (stderr shows usage)"}
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

test "posture, ack, and error events parse and self-identify" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    {
        var w = Writer.fixed(&buf);
        try writePostureEvent(&w, .{ .source = .hybrid, .pdns = true, .geoip_asn = false, .geoip_country = false });
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        const o = p.value.object;
        try t.expectEqualStrings("posture", o.get("ev").?.string);
        try t.expectEqualStrings("ebpf+polling", o.get("source").?.string);
        try t.expect(o.get("pdns").?.bool);
        try t.expect(!o.get("geoip_asn").?.bool);
    }
    {
        var w = Writer.fixed(&buf);
        try writeAckEvent(&w, "focus");
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        try t.expectEqualStrings("ack", p.value.object.get("ev").?.string);
        try t.expect(p.value.object.get("ok").?.bool);
    }
    {
        var w = Writer.fixed(&buf);
        try writeErrorEvent(&w, "unknown \"command\"", "see `surveyor --schema`");
        const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
        defer p.deinit();
        const o = p.value.object;
        try t.expectEqualStrings("error", o.get("ev").?.string);
        try t.expectEqualStrings("unknown \"command\"", o.get("error").?.string); // escaping held
        try t.expect(o.get("fix").?.string.len > 0); // the contract: every error names its fix
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

test "schema is a valid enveloped one-shot and its enums match the code (no drift)" {
    const t = std.testing;
    var buf: [16384]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeSchema(&w, 1773500000000);
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
    defer p.deinit();
    const root = p.value.object;
    // the envelope (workspace R5: discovery verbs are one-shots too)
    try t.expectEqualStrings("ok", root.get("status").?.string);
    try t.expect(root.get("version").?.string.len > 0);
    try t.expect(std.mem.indexOf(u8, root.get("ts").?.string, "T") != null); // ISO-8601
    // the schema describes every flow field the writer emits
    try t.expectEqual(@as(usize, 27), root.get("flow_fields").?.array.items.len);
    // and the category vocabulary is generated from the enum, so counts must agree
    const cats = root.get("enums").?.object.get("category").?.array;
    try t.expectEqual(std.enums.values(identity.Category).len, cats.items.len);
    try t.expectEqual(@as(usize, 8), root.get("events").?.array.items.len); // hello/posture/flow/closed/tick/focus/ack/error
    try t.expect(root.get("commands") != null); // the duplex command surface is self-described
    // the altitude vocabulary is generated from the enum too
    const alts = root.get("enums").?.object.get("altitude").?.array;
    try t.expectEqual(std.enums.values(focusmod.Altitude).len, alts.items.len);
}

test "iso-8601 ts renders correctly" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    // 2026-01-01T00:00:00Z == 1767225600000 ms
    try writeIso8601(&w, 1767225600000);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00+00:00", w.buffered());
}

test "event lines carry both the canonical event field and the legacy ev alias" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeTickEvent(&w, 1767225600000, 3);
    const p = try std.json.parseFromSlice(std.json.Value, t.allocator, w.buffered(), .{});
    defer p.deinit();
    try t.expectEqualStrings("tick", p.value.object.get("event").?.string); // R3 canonical
    try t.expectEqualStrings("tick", p.value.object.get("ev").?.string); // grandfathered alias
    try t.expectEqualStrings("2026-01-01T00:00:00+00:00", p.value.object.get("ts").?.string);
}
