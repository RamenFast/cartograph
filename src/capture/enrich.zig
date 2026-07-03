//! Identity enrichment — the V1/S1 post-capture pass: bare remote IPs become names
//! (rDNS), owners (AS org), and countries (offline MMDB lookups).
//!
//! Capture stays pure; this decorates the *same* `Flow`s the renderers read — call
//! `Enricher.decorate` on the `[]*Flow` that `table.snapshot` returns, right before
//! emitting/rendering, on both the surveyor path and the TUI's in-process path
//! (parity). The 1 Hz tick only ever *reads* the resolve cache — DNS lookups run on
//! a small pool of concurrent tasks and land in the cache a tick or two later.

const std = @import("std");
const Io = std.Io;
const cartograph = @import("cartograph");

const flow = cartograph.flow;
const mmdb = cartograph.mmdb;
const Flow = cartograph.Flow;
const Addr = cartograph.Addr;

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

/// One loud line on stderr — degradation is never silent (V1.md S1).
fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    fw.interface.print("\x1b[2mnote:\x1b[0m " ++ fmt ++ "\n", args) catch return;
    fw.interface.flush() catch {};
}

// ---- the resolve cache (pure logic — threading lives in Resolver) ---------------

pub const name_ttl_ms: i64 = 60 * 60 * 1000; // a name is good for an hour
pub const negative_ttl_ms: i64 = 5 * 60 * 1000; // a miss is retried after 5 min
pub const pending_ttl_ms: i64 = 30 * 1000; // a lost in-flight lookup retries after 30 s

pub const ResolveCache = struct {
    pub const State = enum { pending, named, negative };
    pub const Entry = struct {
        state: State,
        name: flow.Str(128) = .{},
        expires_ms: i64,
        /// True for a passive-DNS name (S3): what this box actually asked for —
        /// it outranks an rDNS guess for the same address and upgrades it in place.
        authoritative: bool = false,
    };

    map: std.AutoHashMapUnmanaged(Addr, Entry) = .empty,

    pub fn deinit(self: *ResolveCache, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
    }

    /// The live named entry for `addr`, if we hold one.
    pub fn getNamed(self: *const ResolveCache, addr: Addr, now_ms: i64) ?*const Entry {
        const e = (self.map.getPtr(addr)) orelse return null;
        if (e.state != .named or now_ms >= e.expires_ms) return null;
        return e;
    }

    /// The live name for `addr`, if we hold one.
    pub fn get(self: *const ResolveCache, addr: Addr, now_ms: i64) ?[]const u8 {
        return if (self.getNamed(addr, now_ms)) |e| e.name.slice() else null;
    }

    /// Should a lookup launch for `addr`? True exactly once per expiry window — the
    /// slot is claimed (pending) so concurrent ticks don't double-resolve.
    pub fn claim(self: *ResolveCache, gpa: std.mem.Allocator, addr: Addr, now_ms: i64) !bool {
        const gop = try self.map.getOrPut(gpa, addr);
        if (gop.found_existing and now_ms < gop.value_ptr.expires_ms) return false;
        gop.value_ptr.* = .{ .state = .pending, .expires_ms = now_ms + pending_ttl_ms };
        return true;
    }

    /// An rDNS lookup finished: record the name — or the miss, with its shorter TTL.
    /// Never displaces a live authoritative (passive-DNS) name.
    pub fn put(self: *ResolveCache, gpa: std.mem.Allocator, addr: Addr, name: ?[]const u8, now_ms: i64) !void {
        const gop = try self.map.getOrPut(gpa, addr);
        if (gop.found_existing and gop.value_ptr.authoritative and
            gop.value_ptr.state == .named and now_ms < gop.value_ptr.expires_ms) return;
        if (name) |n| {
            gop.value_ptr.* = .{ .state = .named, .expires_ms = now_ms + name_ttl_ms };
            gop.value_ptr.name.set(n);
        } else {
            gop.value_ptr.* = .{ .state = .negative, .expires_ms = now_ms + negative_ttl_ms };
        }
    }

    /// A passive-DNS answer: authoritative, always wins, refreshes its TTL.
    pub fn offer(self: *ResolveCache, gpa: std.mem.Allocator, addr: Addr, name: []const u8, now_ms: i64) !void {
        const gop = try self.map.getOrPut(gpa, addr);
        gop.value_ptr.* = .{ .state = .named, .expires_ms = now_ms + name_ttl_ms, .authoritative = true };
        gop.value_ptr.name.set(name);
    }
};

// ---- rDNS via the system resolver ------------------------------------------------
// glibc getnameinfo goes through nsswitch — /etc/hosts, systemd-resolved's cache,
// mDNS (.local) via avahi — so the names match what the *system* believes, which a
// hand-rolled PTR query would not. This is the one libc dependency in the project.

const NI_NAMEREQD: c_int = 8;
extern "c" fn getnameinfo(
    addr: *const anyopaque,
    addrlen: u32,
    host: [*]u8,
    hostlen: u32,
    serv: ?[*]u8,
    servlen: u32,
    flags: c_int,
) c_int;

const SockaddrIn = extern struct {
    family: u16 = std.posix.AF.INET,
    port: u16 = 0,
    addr: [4]u8,
    zero: [8]u8 = @splat(0),
};

const SockaddrIn6 = extern struct {
    family: u16 = std.posix.AF.INET6,
    port: u16 = 0,
    flowinfo: u32 = 0,
    addr: [16]u8,
    scope_id: u32 = 0,
};

/// Blocking PTR lookup. Returns null when the address has no (required) name.
fn rdns(addr: Addr, buf: *[256]u8) ?[]const u8 {
    const rc = if (addr.is_v6) blk: {
        var sa: SockaddrIn6 = .{ .addr = addr.bytes };
        break :blk getnameinfo(@ptrCast(&sa), @sizeOf(SockaddrIn6), buf, buf.len, null, 0, NI_NAMEREQD);
    } else blk: {
        var sa: SockaddrIn = .{ .addr = addr.bytes[0..4].* };
        break :blk getnameinfo(@ptrCast(&sa), @sizeOf(SockaddrIn), buf, buf.len, null, 0, NI_NAMEREQD);
    };
    if (rc != 0) return null;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    if (len == 0) return null;
    return buf[0..len];
}

/// Async rDNS over a small pool of concurrent lookups. `decorate` reads the cache
/// and, on a miss, claims the address and starts a background lookup when a slot is
/// free — it never blocks on DNS itself.
pub const Resolver = struct {
    const max_inflight = 4;
    const Slot = struct {
        future: Io.Future(void),
        done: std.atomic.Value(bool),
        addr: Addr,
    };

    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    cache: ResolveCache = .{},
    slots: [max_inflight]?*Slot = @splat(null),
    no_concurrency: bool = false, // set once; warn loudly exactly once

    pub fn init(gpa: std.mem.Allocator, io: Io) Resolver {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Resolver) void {
        for (&self.slots) |*s| if (s.*) |slot| {
            slot.future.await(self.io); // in-flight getnameinfo finishes on its own clock
            self.gpa.destroy(slot);
            s.* = null;
        };
        self.cache.deinit(self.gpa);
    }

    /// Fill `f.remote_name` from the cache, or start a background lookup for it.
    /// An authoritative (passive-DNS) name upgrades an already-named flow in place;
    /// an rDNS name only fills emptiness.
    pub fn decorate(self: *Resolver, f: *Flow, now_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cache.getNamed(f.key.remote, now_ms)) |e| {
            if (e.authoritative or f.remote_name.len == 0) f.remote_name.set(e.name.slice());
            return;
        }
        if (f.remote_name.len > 0) return; // already named (an expired cache entry keeps its flow name)
        if (self.no_concurrency) return;
        self.reapLocked();
        const free: usize = for (self.slots, 0..) |s, i| {
            if (s == null) break i;
        } else return; // pool busy — next tick picks it up
        if (!(self.cache.claim(self.gpa, f.key.remote, now_ms) catch return)) return;

        const slot = self.gpa.create(Slot) catch return;
        slot.* = .{ .future = undefined, .done = .init(false), .addr = f.key.remote };
        slot.future = self.io.concurrent(resolveOne, .{ self, slot }) catch {
            self.gpa.destroy(slot);
            self.no_concurrency = true;
            note(self.io, "rDNS unavailable (no concurrency in this Io) — names degrade to raw addresses", .{});
            return;
        };
        self.slots[free] = slot;
    }

    /// Reap finished lookups (await is instant once `done` is set). Caller holds the lock.
    fn reapLocked(self: *Resolver) void {
        for (&self.slots) |*s| if (s.*) |slot| {
            if (slot.done.load(.acquire)) {
                slot.future.await(self.io);
                self.gpa.destroy(slot);
                s.* = null;
            }
        };
    }

    /// True while any lookup is in flight.
    pub fn busy(self: *Resolver) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reapLocked();
        for (self.slots) |s| if (s != null) return true;
        return false;
    }

    /// Wait (bounded) for in-flight lookups — the one-shot `snapshot` uses this so
    /// its single frame gets names; the serve loops never call it.
    pub fn drainFor(self: *Resolver, budget_ms: i64) void {
        const deadline = nowMs(self.io) + budget_ms;
        while (self.busy() and nowMs(self.io) < deadline) {
            self.io.sleep(Io.Duration.fromMilliseconds(15), .awake) catch return;
        }
    }

    fn resolveOne(self: *Resolver, slot: *Slot) void {
        var buf: [256]u8 = undefined;
        const name = rdns(slot.addr, &buf);
        self.mutex.lockUncancelable(self.io);
        self.cache.put(self.gpa, slot.addr, name, nowMs(self.io)) catch {};
        self.mutex.unlock(self.io);
        slot.done.store(true, .release);
    }
};

// ---- offline GeoIP (ASN + country MMDBs) ----------------------------------------

pub const GeoDb = struct {
    asn_raw: ?[]u8 = null,
    country_raw: ?[]u8 = null,
    asn: ?mmdb.Mmdb = null,
    country: ?mmdb.Mmdb = null,

    /// Load `<dir>/asn.mmdb` and `<dir>/country.mmdb` (scripts/fetch-geoip.sh writes
    /// them). Missing or corrupt files degrade **loudly** to rDNS-only identity.
    pub fn open(gpa: std.mem.Allocator, io: Io, dir: []const u8) GeoDb {
        var g: GeoDb = .{};
        g.asn_raw = load(gpa, io, dir, "asn.mmdb", &g.asn);
        g.country_raw = load(gpa, io, dir, "country.mmdb", &g.country);
        return g;
    }

    fn load(gpa: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, out: *?mmdb.Mmdb) ?[]u8 {
        var pathbuf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ dir, name }) catch return null;
        const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch {
            note(io, "geoip: {s} not loadable — owner/country stay unknown (fetch: scripts/fetch-geoip.sh)", .{path});
            return null;
        };
        out.* = mmdb.Mmdb.init(raw) catch {
            note(io, "geoip: {s} is not a readable mmdb — owner/country stay unknown", .{path});
            gpa.free(raw);
            return null;
        };
        return raw;
    }

    pub fn deinit(self: *GeoDb, gpa: std.mem.Allocator) void {
        if (self.asn_raw) |b| gpa.free(b);
        if (self.country_raw) |b| gpa.free(b);
        self.* = .{};
    }

    pub fn loaded(self: *const GeoDb) bool {
        return self.asn != null or self.country != null;
    }

    /// Fill the AS + country fields for `f.key.remote` (GeoLite2/DB-IP field paths).
    pub fn annotate(self: *const GeoDb, f: *Flow) void {
        if (self.asn) |*db| {
            if (db.lookup(f.key.remote) catch null) |off| {
                if (db.getPath(off, &.{"autonomous_system_number"}) catch null) |v| {
                    if (v == .uint) f.asn = @truncate(v.uint);
                }
                if (db.getPath(off, &.{"autonomous_system_organization"}) catch null) |v| {
                    if (v == .string) f.as_org.set(v.string);
                }
            }
        }
        if (self.country) |*db| {
            if (db.lookup(f.key.remote) catch null) |off| {
                if (db.getPath(off, &.{ "country", "iso_code" }) catch null) |v| {
                    if (v == .string and v.string.len == 2) f.country = v.string[0..2].*;
                }
            }
        }
    }
};

// ---- the S1 post-pass -------------------------------------------------------------

pub const Enricher = struct {
    resolver: Resolver,
    geo: GeoDb,

    /// `geoip_dir` null = identity without owner/country (still rDNS). The surveyor
    /// CLI computes the default dir (`~/.local/share/cartograph/geoip`) — this layer
    /// takes an explicit path so it stays env-free and testable.
    pub fn init(gpa: std.mem.Allocator, io: Io, geoip_dir: ?[]const u8) Enricher {
        return .{
            .resolver = Resolver.init(gpa, io),
            .geo = if (geoip_dir) |d| GeoDb.open(gpa, io, d) else .{},
        };
    }

    pub fn deinit(self: *Enricher) void {
        const gpa = self.resolver.gpa;
        self.resolver.deinit();
        self.geo.deinit(gpa);
    }

    /// Decorate the live table's flows in place (write-through the `[]*Flow` snapshot
    /// pointers — the table keeps the fields across ticks). Never blocks on DNS.
    pub fn decorate(self: *Enricher, flows: []const *Flow, now_ms: i64) void {
        for (flows) |f| {
            const r = f.key.remote;
            if (r.isUnspecified() or r.isLoopback() or r.isMulticast() or f.isListen()) continue;
            if (f.asn == 0 and f.country[0] == 0) self.geo.annotate(f);
            self.resolver.decorate(f, now_ms);
        }
    }

    /// The passive-DNS sink (pdns.zig calls this per A/AAAA answer): remember the
    /// name this box asked for, authoritatively. Thread-safe like the resolver.
    pub fn offerName(self: *Enricher, addr: cartograph.Addr, name: []const u8, now_ms: i64) void {
        self.resolver.mutex.lockUncancelable(self.resolver.io);
        defer self.resolver.mutex.unlock(self.resolver.io);
        self.resolver.cache.offer(self.resolver.gpa, addr, name, now_ms) catch {};
    }
};

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "resolve cache: claim once per window, named/negative TTLs expire" {
    const gpa = testing.allocator;
    var c: ResolveCache = .{};
    defer c.deinit(gpa);
    const a = Addr.v4(.{ 1, 1, 1, 1 });

    // claim is granted once, then held (pending) against double-resolve
    try testing.expect(try c.claim(gpa, a, 1000));
    try testing.expect(!try c.claim(gpa, a, 1001));
    try testing.expectEqual(@as(?[]const u8, null), c.get(a, 1002));

    // a name lands and is served until its TTL, then re-claimable
    try c.put(gpa, a, "one.one.one.one", 2000);
    try testing.expectEqualStrings("one.one.one.one", c.get(a, 2001).?);
    try testing.expect(!try c.claim(gpa, a, 2002)); // fresh name — no re-resolve
    try testing.expectEqual(@as(?[]const u8, null), c.get(a, 2000 + name_ttl_ms));
    try testing.expect(try c.claim(gpa, a, 2000 + name_ttl_ms));

    // a negative answer is retried sooner (negative TTL < name TTL)
    const b = Addr.v4(.{ 192, 168, 1, 254 });
    try testing.expect(try c.claim(gpa, b, 5000));
    try c.put(gpa, b, null, 5100);
    try testing.expectEqual(@as(?[]const u8, null), c.get(b, 5200));
    try testing.expect(!try c.claim(gpa, b, 5200));
    try testing.expect(try c.claim(gpa, b, 5100 + negative_ttl_ms));

    // a pending claim that never resolves (lost worker) is retried after its TTL
    const d = Addr.v4(.{ 10, 0, 0, 1 });
    try testing.expect(try c.claim(gpa, d, 9000));
    try testing.expect(try c.claim(gpa, d, 9000 + pending_ttl_ms));
}

test "a passive-DNS name outranks rDNS and upgrades in place; rDNS never displaces it" {
    const gpa = testing.allocator;
    var c: ResolveCache = .{};
    defer c.deinit(gpa);
    const a = Addr.v4(.{ 140, 82, 116, 3 });

    // rDNS lands first (the S1 baseline)…
    try c.put(gpa, a, "lb-140-82-116-3-sea.github.com", 1000);
    try testing.expectEqualStrings("lb-140-82-116-3-sea.github.com", c.get(a, 1001).?);
    // …then the box resolves the name itself: the asked-for name wins
    try c.offer(gpa, a, "github.com", 2000);
    try testing.expectEqualStrings("github.com", c.get(a, 2001).?);
    try testing.expect(c.getNamed(a, 2001).?.authoritative);
    // a later rDNS answer must NOT displace it
    try c.put(gpa, a, "lb-140-82-116-3-sea.github.com", 3000);
    try testing.expectEqualStrings("github.com", c.get(a, 3001).?);
}

test "resolver smoke: 127.0.0.1 resolves via /etc/hosts and lands in the flow" {
    const gpa = testing.allocator;
    var r = Resolver.init(gpa, testing.io);
    defer r.deinit();

    var f: Flow = .{ .key = .{
        .proto = .tcp,
        .local = Addr.v4(.{ 127, 0, 0, 1 }),
        .local_port = 40000,
        .remote = Addr.v4(.{ 127, 0, 0, 1 }),
        .remote_port = 631,
    } };

    r.decorate(&f, nowMs(testing.io)); // first touch: claims + spawns, no name yet
    r.drainFor(3000);
    r.decorate(&f, nowMs(testing.io)); // second touch: reads the landed cache entry
    try testing.expectEqualStrings("localhost", f.remote_name.slice());
}

test "geodb: missing dir degrades to empty (and says so on stderr)" {
    const gpa = testing.allocator;
    var g = GeoDb.open(gpa, testing.io, "/nonexistent/cartograph-geoip");
    defer g.deinit(gpa);
    try testing.expect(!g.loaded());
    // annotate is a no-op, not a crash
    var f: Flow = .{ .key = .{ .proto = .tcp, .local = Addr.v4(.{ 192, 168, 1, 9 }), .local_port = 1, .remote = Addr.v4(.{ 1, 1, 1, 1 }), .remote_port = 443 } };
    g.annotate(&f);
    try testing.expectEqual(@as(u32, 0), f.asn);
}
