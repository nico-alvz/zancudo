//! Central router. Owns the topic radix tree, the session table, the retained
//! store and the WAL. It is single-threaded by design: network workers never
//! touch these structures directly, they post `Command`s onto the lock-free
//! queue and the router drains it. That removes every data-path lock and makes
//! routing latency a function of tree depth alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mqtt = @import("../protocol/mqtt.zig");
const RadixTree = @import("radix_tree.zig").RadixTree;
const SubscriberId = @import("radix_tree.zig").SubscriberId;
const Session = @import("session.zig").Session;
const SessionId = @import("session.zig").SessionId;
const BoundedQueue = @import("lockfree.zig").BoundedQueue;
const Wal = @import("../persist/wal.zig").Wal;
const Mesh = @import("../cluster/mesh.zig").Mesh;
const limits = @import("../security/limits.zig");

/// A unit of work handed from a network worker to the router. Payload/topic
/// slices point into a worker-owned staging buffer that stays valid until the
/// router acknowledges the command (single consumer, so a simple generation
/// counter suffices — omitted here for brevity).
pub const Command = union(enum) {
    attach_session: struct { session: *Session },
    detach_session: struct { id: SessionId, clean: bool },
    subscribe: struct { id: SessionId, filter: []const u8, qos: mqtt.Qos, no_local: bool },
    unsubscribe: struct { id: SessionId, filter: []const u8 },
    publish: struct {
        from: SessionId,
        topic: []const u8,
        qos: mqtt.Qos,
        retain: bool,
        payload: []const u8,
    },
};

/// The router emits deliveries the network layer must serialize onto sockets.
pub const Delivery = struct {
    to: SessionId,
    topic: []const u8,
    qos: mqtt.Qos,
    retain: bool,
    payload: []const u8,
};

pub const CommandQueue = BoundedQueue(Command);

pub const Router = struct {
    gpa: Allocator,
    tree: RadixTree,
    sessions: std.AutoHashMapUnmanaged(SessionId, *Session) = .{},
    retained: std.StringHashMapUnmanaged([]const u8) = .{},
    wal: ?*Wal,
    mesh: *Mesh,
    inbox: *CommandQueue,

    // Scratch reused across match() calls so a fan-out does not allocate.
    match_scratch: std.ArrayListUnmanaged(SubscriberId) = .{},
    stats: Stats = .{},

    pub const Stats = struct {
        published: u64 = 0,
        delivered: u64 = 0,
        dropped_no_subscriber: u64 = 0,
        retained_stored: u64 = 0,
    };

    pub fn init(gpa: Allocator, inbox: *CommandQueue, wal: ?*Wal, mesh: *Mesh) Router {
        return .{
            .gpa = gpa,
            .tree = RadixTree.init(gpa),
            .wal = wal,
            .mesh = mesh,
            .inbox = inbox,
        };
    }

    pub fn deinit(self: *Router) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            sp.*.deinit();
            self.gpa.destroy(sp.*);
        }
        self.sessions.deinit(self.gpa);
        var rit = self.retained.iterator();
        while (rit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.retained.deinit(self.gpa);
        self.match_scratch.deinit(self.gpa);
        self.tree.deinit();
    }

    /// Drain up to `budget` commands. Returns how many were processed so the
    /// caller can decide whether to keep spinning or go back to the reactor.
    pub fn drain(self: *Router, sink: DeliverySink, budget: usize) usize {
        var n: usize = 0;
        while (n < budget) : (n += 1) {
            const cmd = self.inbox.tryPop() orelse break;
            self.apply(cmd, sink);
        }
        return n;
    }

    pub const DeliverySink = struct {
        ctx: *anyopaque,
        emit: *const fn (ctx: *anyopaque, d: Delivery) void,
    };

    fn apply(self: *Router, cmd: Command, sink: DeliverySink) void {
        switch (cmd) {
            .attach_session => |c| {
                self.sessions.put(self.gpa, c.session.id, c.session) catch return;
            },
            .detach_session => |c| {
                if (self.sessions.fetchRemove(c.id)) |kv| {
                    if (c.clean) {
                        for (kv.value.subscriptions.items) |s|
                            self.tree.unsubscribe(s.filter, kv.value.id) catch {};
                        kv.value.deinit();
                        self.gpa.destroy(kv.value);
                    } else {
                        // Persistent: keep the Session object, just mark detached.
                        kv.value.conn_slot = null;
                        self.sessions.put(self.gpa, c.id, kv.value) catch {};
                    }
                }
            },
            .subscribe => |c| {
                const sess = self.sessions.get(c.id) orelse return;
                sess.addSubscription(c.filter, c.qos, c.no_local) catch return;
                self.tree.subscribe(c.filter, sess.id) catch return;
                self.replayRetained(c.filter, sess.id, sink);
            },
            .unsubscribe => |c| {
                const sess = self.sessions.get(c.id) orelse return;
                _ = sess.removeSubscription(c.filter);
                self.tree.unsubscribe(c.filter, sess.id) catch {};
            },
            .publish => |c| self.routePublish(c, sink),
        }
    }

    fn routePublish(self: *Router, c: anytype, sink: DeliverySink) void {
        self.stats.published += 1;

        if (c.retain) self.storeRetained(c.topic, c.payload);

        if (!self.mesh.ownsLocally(c.topic)) {
            // TODO: forward to the shard owner over the mesh transport.
            return;
        }

        self.match_scratch.clearRetainingCapacity();
        const collector = Collector{ .list = &self.match_scratch, .gpa = self.gpa };
        self.tree.match(c.topic, collector.sink());

        // Deduplicate: a session may match through several filters.
        std.mem.sort(SubscriberId, self.match_scratch.items, {}, std.sort.asc(SubscriberId));
        var last: ?SubscriberId = null;
        var any = false;
        for (self.match_scratch.items) |sid| {
            if (last != null and last.? == sid) continue;
            last = sid;
            const sess = self.sessions.get(sid) orelse continue;
            if (sess.id == c.from and self.hasNoLocal(sess, c.topic)) continue;
            const eff_qos: mqtt.Qos = minQos(c.qos, self.grantedQos(sess, c.topic));
            sink.emit(sink.ctx, .{
                .to = sid,
                .topic = c.topic,
                .qos = eff_qos,
                .retain = false,
                .payload = c.payload,
            });
            self.stats.delivered += 1;
            any = true;
        }
        if (!any) self.stats.dropped_no_subscriber += 1;
    }

    fn storeRetained(self: *Router, topic: []const u8, payload: []const u8) void {
        if (payload.len == 0) {
            if (self.retained.fetchRemove(topic)) |kv| {
                self.gpa.free(kv.key);
                self.gpa.free(kv.value);
            }
            return;
        }
        const key = self.gpa.dupe(u8, topic) catch return;
        const val = self.gpa.dupe(u8, payload) catch {
            self.gpa.free(key);
            return;
        };
        if (self.retained.fetchPut(self.gpa, key, val) catch null) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        self.stats.retained_stored += 1;
        if (self.wal) |w| _ = w.append(.retained_set, payload) catch {};
    }

    fn replayRetained(self: *Router, filter: []const u8, to: SessionId, sink: DeliverySink) void {
        var it = self.retained.iterator();
        while (it.next()) |e| {
            if (topicMatchesFilter(e.key_ptr.*, filter)) {
                sink.emit(sink.ctx, .{
                    .to = to,
                    .topic = e.key_ptr.*,
                    .qos = .at_most_once,
                    .retain = true,
                    .payload = e.value_ptr.*,
                });
            }
        }
    }

    fn hasNoLocal(_: *Router, sess: *Session, topic: []const u8) bool {
        for (sess.subscriptions.items) |s| {
            if (s.no_local and topicMatchesFilter(topic, s.filter)) return true;
        }
        return false;
    }

    fn grantedQos(_: *Router, sess: *Session, topic: []const u8) mqtt.Qos {
        var best: mqtt.Qos = .at_most_once;
        for (sess.subscriptions.items) |s| {
            if (topicMatchesFilter(topic, s.filter) and @intFromEnum(s.qos) > @intFromEnum(best))
                best = s.qos;
        }
        return best;
    }

    const Collector = struct {
        list: *std.ArrayListUnmanaged(SubscriberId),
        gpa: Allocator,
        fn sink(self: *const Collector) RadixTree.MatchSink {
            return .{ .ctx = @constCast(self), .emit = emit };
        }
        fn emit(ctx: *anyopaque, id: SubscriberId) void {
            const self: *Collector = @ptrCast(@alignCast(ctx));
            self.list.append(self.gpa, id) catch {};
        }
    };
};

fn minQos(a: mqtt.Qos, b: mqtt.Qos) mqtt.Qos {
    return if (@intFromEnum(a) <= @intFromEnum(b)) a else b;
}

/// Standalone "does this concrete topic match this filter" check, used for
/// retained replay and no-local without touching the tree.
pub fn topicMatchesFilter(topic: []const u8, filter: []const u8) bool {
    var t_it = std.mem.splitScalar(u8, topic, '/');
    var f_it = std.mem.splitScalar(u8, filter, '/');
    var first = true;
    while (true) {
        const f = f_it.next();
        const t = t_it.next();
        if (f == null and t == null) return true;
        if (f == null) return false;
        if (std.mem.eql(u8, f.?, "#")) {
            if (first and t != null and t.?.len > 0 and t.?[0] == '$') return false;
            return true;
        }
        if (t == null) return false;
        if (std.mem.eql(u8, f.?, "+")) {
            if (first and t.?.len > 0 and t.?[0] == '$') return false;
        } else if (!std.mem.eql(u8, f.?, t.?)) {
            return false;
        }
        first = false;
    }
}

test "topicMatchesFilter matches the spec examples" {
    try std.testing.expect(topicMatchesFilter("sport/tennis/player1", "sport/tennis/#"));
    try std.testing.expect(topicMatchesFilter("sport", "sport/#"));
    try std.testing.expect(topicMatchesFilter("sport/tennis/player1", "sport/+/player1"));
    try std.testing.expect(!topicMatchesFilter("sport/tennis/player1/score", "sport/+/player1"));
    try std.testing.expect(!topicMatchesFilter("$SYS/x", "#"));
    try std.testing.expect(!topicMatchesFilter("$SYS/x", "+/x"));
}

test "router routes a publish to a matching subscriber" {
    const testing = std.testing;
    var mesh = Mesh.init(testing.allocator, 1);
    defer mesh.deinit();
    var queue = try CommandQueue.init(testing.allocator, 64);
    defer queue.deinit(testing.allocator);
    var router = Router.init(testing.allocator, &queue, null, &mesh);
    defer router.deinit();

    const sub = try testing.allocator.create(Session);
    sub.* = try Session.init(testing.allocator, 100, "sub", .v3_1_1, true);
    const pubr = try testing.allocator.create(Session);
    pubr.* = try Session.init(testing.allocator, 200, "pub", .v3_1_1, true);

    const Sink = struct {
        got: std.ArrayList(Delivery),
        fn s(self: *@This()) Router.DeliverySink {
            return .{ .ctx = self, .emit = e };
        }
        fn e(ctx: *anyopaque, d: Delivery) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.got.append(d) catch unreachable;
        }
    };
    var sink = Sink{ .got = std.ArrayList(Delivery).init(testing.allocator) };
    defer sink.got.deinit();

    try testing.expect(queue.tryPush(.{ .attach_session = .{ .session = sub } }));
    try testing.expect(queue.tryPush(.{ .attach_session = .{ .session = pubr } }));
    try testing.expect(queue.tryPush(.{ .subscribe = .{ .id = 100, .filter = "a/+/c", .qos = .at_least_once, .no_local = false } }));
    try testing.expect(queue.tryPush(.{ .publish = .{ .from = 200, .topic = "a/b/c", .qos = .at_most_once, .retain = false, .payload = "hi" } }));

    _ = router.drain(sink.s(), 16);
    try testing.expectEqual(@as(usize, 1), sink.got.items.len);
    try testing.expectEqual(@as(SessionId, 100), sink.got.items[0].to);
    try testing.expectEqualStrings("a/b/c", sink.got.items[0].topic);
}
