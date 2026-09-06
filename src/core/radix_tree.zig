//! Cache-oriented radix tree (compact trie) for MQTT topic routing.
//!
//! Why a radix tree keyed by *level* rather than by byte:
//!   * MQTT matching is defined level-by-level ("sport/tennis/player1"), so the
//!     natural edge label is a whole level, not a character. That keeps the tree
//!     shallow (depth == number of levels, typically 2..5).
//!   * Exact children live in a single contiguous, segment-sorted array. A match
//!     step is a branch-predictable binary search over data that fits in one or
//!     two cache lines for realistic fan-out, instead of chasing a hash map.
//!   * The two wildcards get dedicated slots (`plus`, `hash`) so the hot path
//!     never string-compares against "+" or "#".
//!
//! Matching rules implemented (MQTT-3.1.1 §4.7, carried unchanged into v5):
//!   * `+`  matches exactly one level.
//!   * `#`  matches the parent level and every level below it (including zero,
//!          so "sport/#" matches "sport").
//!   * A subscription whose first level is `+` or `#` must not match a topic
//!     whose first level begins with `$` (reserved topics such as `$SYS/...`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const mqtt = @import("../protocol/mqtt.zig");
const limits = @import("../security/limits.zig");

/// Opaque routing target. In the broker this is a session slot index; the tree
/// neither dereferences nor interprets it.
pub const SubscriberId = u64;

pub const Error = error{
    OutOfMemory,
    /// `#` appeared somewhere other than the final level.
    MultiLevelWildcardNotLast,
    /// A level contained `+`/`#` mixed with other characters, or the filter was
    /// empty / over the configured length ceiling.
    MalformedFilter,
};

const Node = struct {
    /// Owned copy of this node's level label. Empty for the root and for the
    /// legal MQTT "empty level" (as in "a//b").
    segment: []u8,
    children: std.ArrayListUnmanaged(*Node) = .{}, // segment-sorted, exact only
    plus: ?*Node = null,
    hash: ?*Node = null,
    /// Ids whose filter terminates exactly at this node (no trailing `#`).
    subscribers: std.ArrayListUnmanaged(SubscriberId) = .{},

    fn childIndex(self: *const Node, seg: []const u8) union(enum) { found: usize, insert_at: usize } {
        var lo: usize = 0;
        var hi: usize = self.children.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.children.items[mid].segment, seg)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .found = mid },
            }
        }
        return .{ .insert_at = lo };
    }

    fn deinit(self: *Node, gpa: Allocator) void {
        for (self.children.items) |c| {
            c.deinit(gpa);
            gpa.destroy(c);
        }
        self.children.deinit(gpa);
        if (self.plus) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        if (self.hash) |h| {
            h.deinit(gpa);
            gpa.destroy(h);
        }
        self.subscribers.deinit(gpa);
        gpa.free(self.segment);
    }
};

pub const RadixTree = struct {
    gpa: Allocator,
    root: Node,

    pub fn init(gpa: Allocator) RadixTree {
        return .{ .gpa = gpa, .root = .{ .segment = &[_]u8{} } };
    }

    pub fn deinit(self: *RadixTree) void {
        // The root's segment is a zero-length static slice; free everything else.
        for (self.root.children.items) |c| {
            c.deinit(self.gpa);
            self.gpa.destroy(c);
        }
        self.root.children.deinit(self.gpa);
        if (self.root.plus) |p| {
            p.deinit(self.gpa);
            self.gpa.destroy(p);
        }
        if (self.root.hash) |h| {
            h.deinit(self.gpa);
            self.gpa.destroy(h);
        }
        self.root.subscribers.deinit(self.gpa);
    }

    fn makeNode(self: *RadixTree, seg: []const u8) Error!*Node {
        const n = try self.gpa.create(Node);
        errdefer self.gpa.destroy(n);
        const owned = try self.gpa.dupe(u8, seg);
        n.* = .{ .segment = owned };
        return n;
    }

    fn descendExact(self: *RadixTree, node: *Node, seg: []const u8) Error!*Node {
        switch (node.childIndex(seg)) {
            .found => |i| return node.children.items[i],
            .insert_at => |i| {
                const child = try self.makeNode(seg);
                try node.children.insert(self.gpa, i, child);
                return child;
            },
        }
    }

    /// Add `id` to every topic that matches `filter`. Idempotent per (filter,id).
    pub fn subscribe(self: *RadixTree, filter: []const u8, id: SubscriberId) Error!void {
        try validateFilter(filter);
        var node = &self.root;
        var it = std.mem.splitScalar(u8, filter, mqtt.level_separator);
        var level_count: u16 = 0;
        while (it.next()) |level| {
            level_count += 1;
            if (level_count > limits.max_topic_levels) return Error.MalformedFilter;
            if (level.len == 1 and level[0] == mqtt.single_level_wildcard) {
                node.plus = node.plus orelse try self.makeNode("+");
                node = node.plus.?;
            } else if (level.len == 1 and level[0] == mqtt.multi_level_wildcard) {
                node.hash = node.hash orelse try self.makeNode("#");
                node = node.hash.?;
                break; // `#` is always the last level (validateFilter guarantees it)
            } else {
                node = try self.descendExact(node, level);
            }
        }
        for (node.subscribers.items) |existing| {
            if (existing == id) return;
        }
        try node.subscribers.append(self.gpa, id);
    }

    /// Remove `id` from `filter`. Missing (filter,id) pairs are a no-op.
    /// Empty interior nodes are left in place; churny workloads reuse them and a
    /// periodic compaction pass (not shown) can reclaim them off the hot path.
    pub fn unsubscribe(self: *RadixTree, filter: []const u8, id: SubscriberId) Error!void {
        try validateFilter(filter);
        var node: ?*Node = &self.root;
        var it = std.mem.splitScalar(u8, filter, mqtt.level_separator);
        while (it.next()) |level| {
            const cur = node orelse return;
            if (level.len == 1 and level[0] == mqtt.single_level_wildcard) {
                node = cur.plus;
            } else if (level.len == 1 and level[0] == mqtt.multi_level_wildcard) {
                node = cur.hash;
                break;
            } else switch (cur.childIndex(level)) {
                .found => |i| node = cur.children.items[i],
                .insert_at => return,
            }
        }
        const target = node orelse return;
        for (target.subscribers.items, 0..) |existing, i| {
            if (existing == id) {
                _ = target.subscribers.swapRemove(i);
                return;
            }
        }
    }

    pub const MatchSink = struct {
        ctx: *anyopaque,
        emit: *const fn (ctx: *anyopaque, id: SubscriberId) void,
    };

    /// Invoke `sink.emit` for every subscriber whose filter matches `topic`.
    /// An id may be emitted more than once if it holds several matching filters;
    /// the caller (router) deduplicates per delivery.
    pub fn match(self: *RadixTree, topic: []const u8, sink: MatchSink) void {
        // Reserved-topic guard: only consult it for the very first level.
        const first_is_reserved = topic.len > 0 and topic[0] == mqtt.reserved_prefix;
        var levels_buf: [limits.max_topic_levels][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, topic, mqtt.level_separator);
        while (it.next()) |lvl| {
            if (n == levels_buf.len) return; // pathological topic, refuse to match
            levels_buf[n] = lvl;
            n += 1;
        }
        walk(&self.root, levels_buf[0..n], 0, first_is_reserved, sink);
    }

    fn walk(
        node: *Node,
        levels: []const []const u8,
        depth: usize,
        first_is_reserved: bool,
        sink: MatchSink,
    ) void {
        const wildcards_blocked = first_is_reserved and depth == 0;

        if (depth == levels.len) {
            emitAll(node.subscribers.items, sink);
            // "sport/#" matches the exact topic "sport".
            if (node.hash) |h| emitAll(h.subscribers.items, sink);
            return;
        }

        // `#` here swallows this level and everything under it.
        if (!wildcards_blocked) {
            if (node.hash) |h| emitAll(h.subscribers.items, sink);
            if (node.plus) |p| walk(p, levels, depth + 1, first_is_reserved, sink);
        }

        switch (node.childIndex(levels[depth])) {
            .found => |i| walk(node.children.items[i], levels, depth + 1, first_is_reserved, sink),
            .insert_at => {},
        }
    }

    fn emitAll(ids: []const SubscriberId, sink: MatchSink) void {
        for (ids) |id| sink.emit(sink.ctx, id);
    }
};

fn validateFilter(filter: []const u8) Error!void {
    if (filter.len == 0 or filter.len > limits.max_topic_len) return Error.MalformedFilter;
    var it = std.mem.splitScalar(u8, filter, mqtt.level_separator);
    var idx: usize = 0;
    var saw_hash = false;
    while (it.next()) |level| : (idx += 1) {
        if (saw_hash) return Error.MultiLevelWildcardNotLast;
        if (std.mem.indexOfScalar(u8, level, mqtt.multi_level_wildcard)) |_| {
            if (level.len != 1) return Error.MalformedFilter; // "sport#" illegal
            saw_hash = true;
        }
        if (std.mem.indexOfScalar(u8, level, mqtt.single_level_wildcard)) |_| {
            if (level.len != 1) return Error.MalformedFilter; // "sp+rt" illegal
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestCollector = struct {
    list: std.ArrayList(SubscriberId),

    fn sink(self: *TestCollector) RadixTree.MatchSink {
        return .{ .ctx = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, id: SubscriberId) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx));
        self.list.append(id) catch unreachable;
    }
    fn sortedUnique(self: *TestCollector) []SubscriberId {
        std.mem.sort(SubscriberId, self.list.items, {}, std.sort.asc(SubscriberId));
        var w: usize = 0;
        for (self.list.items, 0..) |v, i| {
            if (i == 0 or v != self.list.items[i - 1]) {
                self.list.items[w] = v;
                w += 1;
            }
        }
        return self.list.items[0..w];
    }
};

fn expectMatches(tree: *RadixTree, topic: []const u8, expected: []const SubscriberId) !void {
    var c = TestCollector{ .list = std.ArrayList(SubscriberId).init(std.testing.allocator) };
    defer c.list.deinit();
    tree.match(topic, c.sink());
    try std.testing.expectEqualSlices(SubscriberId, expected, c.sortedUnique());
}

test "exact and single-level wildcard" {
    var tree = RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.subscribe("sport/tennis/player1", 1);
    try tree.subscribe("sport/+/player1", 2);
    try tree.subscribe("sport/tennis/+", 3);

    try expectMatches(&tree, "sport/tennis/player1", &[_]SubscriberId{ 1, 2, 3 });
    try expectMatches(&tree, "sport/football/player1", &[_]SubscriberId{2});
    try expectMatches(&tree, "sport/tennis/player2", &[_]SubscriberId{3});
}

test "multi-level wildcard including zero levels" {
    var tree = RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.subscribe("sport/#", 10);
    try tree.subscribe("#", 11);

    try expectMatches(&tree, "sport", &[_]SubscriberId{ 10, 11 });
    try expectMatches(&tree, "sport/tennis/player1", &[_]SubscriberId{ 10, 11 });
    try expectMatches(&tree, "weather", &[_]SubscriberId{11});
}

test "reserved topics are hidden from leading wildcards" {
    var tree = RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.subscribe("#", 1);
    try tree.subscribe("+/monitor", 2);
    try tree.subscribe("$SYS/#", 3);

    try expectMatches(&tree, "$SYS/broker/uptime", &[_]SubscriberId{3});
    try expectMatches(&tree, "$SYS/monitor", &[_]SubscriberId{3});
    try expectMatches(&tree, "home/monitor", &[_]SubscriberId{ 1, 2 });
}

test "unsubscribe removes exactly one id" {
    var tree = RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.subscribe("a/b", 1);
    try tree.subscribe("a/b", 2);
    try tree.unsubscribe("a/b", 1);
    try expectMatches(&tree, "a/b", &[_]SubscriberId{2});
}

test "malformed filters are rejected" {
    var tree = RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    try std.testing.expectError(Error.MultiLevelWildcardNotLast, tree.subscribe("a/#/b", 1));
    try std.testing.expectError(Error.MalformedFilter, tree.subscribe("sport#", 1));
    try std.testing.expectError(Error.MalformedFilter, tree.subscribe("sp+rt", 1));
    try std.testing.expectError(Error.MalformedFilter, tree.subscribe("", 1));
}
