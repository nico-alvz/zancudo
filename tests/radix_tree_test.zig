//! Extra radix-tree scenarios kept out of the module file: larger fan-out,
//! churn, and the OASIS specification's own worked examples.

const std = @import("std");
const rt = @import("../src/core/radix_tree.zig");

const Collector = struct {
    ids: std.ArrayList(u64),
    fn sink(self: *Collector) rt.RadixTree.MatchSink {
        return .{ .ctx = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, id: u64) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.ids.append(id) catch unreachable;
    }
    fn sortedUnique(self: *Collector) []u64 {
        std.mem.sort(u64, self.ids.items, {}, std.sort.asc(u64));
        var w: usize = 0;
        for (self.ids.items, 0..) |v, i| {
            if (i == 0 or v != self.ids.items[i - 1]) {
                self.ids.items[w] = v;
                w += 1;
            }
        }
        return self.ids.items[0..w];
    }
};

fn matches(tree: *rt.RadixTree, topic: []const u8, expected: []const u64) !void {
    var c = Collector{ .ids = std.ArrayList(u64).init(std.testing.allocator) };
    defer c.ids.deinit();
    tree.match(topic, c.sink());
    try std.testing.expectEqualSlices(u64, expected, c.sortedUnique());
}

test "OASIS 3.1.1 wildcard examples" {
    var tree = rt.RadixTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.subscribe("sport/tennis/player1/#", 1); // matches player1 and below
    try tree.subscribe("sport/#", 2);
    try tree.subscribe("sport/tennis/#", 3);
    try tree.subscribe("+/+", 4);
    try tree.subscribe("/+", 5);
    try tree.subscribe("+", 6);

    try matches(&tree, "sport/tennis/player1", &[_]u64{ 1, 2, 3 });
    try matches(&tree, "sport/tennis/player1/ranking", &[_]u64{ 1, 2, 3 });
    try matches(&tree, "sport", &[_]u64{ 2, 6 });
    try matches(&tree, "/finance", &[_]u64{ 4, 5 });
}

test "high fan-out under one level stays correct" {
    var tree = rt.RadixTree.init(std.testing.allocator);
    defer tree.deinit();

    var buf: [64]u8 = undefined;
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        const filter = try std.fmt.bufPrint(&buf, "devices/{d}/telemetry", .{i});
        try tree.subscribe(filter, i);
    }
    try tree.subscribe("devices/+/telemetry", 9999);

    try matches(&tree, "devices/250/telemetry", &[_]u64{ 250, 9999 });
    try matches(&tree, "devices/999/telemetry", &[_]u64{9999});
}

test "subscribe/unsubscribe churn does not leak or misroute" {
    var tree = rt.RadixTree.init(std.testing.allocator);
    defer tree.deinit();

    var round: u64 = 0;
    while (round < 200) : (round += 1) {
        try tree.subscribe("a/b/c", round);
        try tree.subscribe("a/+/c", round);
        if (round % 2 == 0) {
            try tree.unsubscribe("a/b/c", round);
            try tree.unsubscribe("a/+/c", round);
        }
    }

    var c = Collector{ .ids = std.ArrayList(u64).init(std.testing.allocator) };
    defer c.ids.deinit();
    tree.match("a/b/c", c.sink());
    const got = c.sortedUnique();
    for (got) |id| try std.testing.expect(id % 2 == 1);
}
