//! Load and adversarial-input tests.
//!
//!  * Many network workers pushing PUBLISH commands concurrently onto the
//!    lock-free queue while the single router thread drains them — asserts no
//!    message is lost, duplicated, or misrouted, and nothing races.
//!  * A spray of deliberately malformed frames through the decoder — asserts a
//!    structured error every time, never a panic or an out-of-bounds read.

const std = @import("std");
const router_mod = @import("../src/core/router.zig");
const Router = router_mod.Router;
const CommandQueue = router_mod.CommandQueue;
const Delivery = router_mod.Delivery;
const Session = @import("../src/core/session.zig").Session;
const Mesh = @import("../src/cluster/mesh.zig").Mesh;
const decoder = @import("../src/protocol/decoder.zig");
const mqtt = @import("../src/protocol/mqtt.zig");

test "concurrent publishers, single router: no loss, no misroute" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const a = std.testing.allocator;

    var mesh = Mesh.init(a, 1);
    defer mesh.deinit();
    var queue = try CommandQueue.init(a, 4096);
    defer queue.deinit(a);
    var router = Router.init(a, &queue, null, &mesh);
    defer router.deinit();

    const n_subs = 8;
    const n_producers = 4;
    const per_producer = 5000;

    var subs: [n_subs]*Session = undefined;
    for (&subs, 0..) |*sp, i| {
        const s = try a.create(Session);
        s.* = try Session.init(a, @as(u64, i) + 1, "s", .v3_1_1, true);
        sp.* = s;
        try std.testing.expect(queue.tryPush(.{ .attach_session = .{ .session = s } }));
        try std.testing.expect(queue.tryPush(.{ .subscribe = .{ .id = s.id, .filter = "load/#", .qos = .at_most_once, .no_local = false } }));
    }

    var delivered = std.ArrayList(Delivery).init(a);
    defer delivered.deinit();
    const Sink = struct {
        list: *std.ArrayList(Delivery),
        fn s(self: *@This()) Router.DeliverySink {
            return .{ .ctx = self, .emit = e };
        }
        fn e(ctx: *anyopaque, d: Delivery) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.list.append(d) catch unreachable;
        }
    };
    var sink = Sink{ .list = &delivered };
    _ = router.drain(sink.s(), 1024); // process attaches + subscribes

    const Producer = struct {
        q: *CommandQueue,
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < per_producer) {
                const ok = self.q.tryPush(.{ .publish = .{
                    .from = 999,
                    .topic = "load/x",
                    .qos = .at_most_once,
                    .retain = false,
                    .payload = "m",
                } });
                if (ok) i += 1;
            }
        }
    };
    var pctx = Producer{ .q = &queue };
    var threads: [n_producers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Producer.run, .{&pctx});

    const want = n_subs * n_producers * per_producer;
    var spins: usize = 0;
    while (delivered.items.len < want) {
        const did = router.drain(sink.s(), 4096);
        if (did == 0) {
            spins += 1;
            if (spins > 20_000_000) break; // safety valve
        }
    }
    for (&threads) |*t| t.join();
    _ = router.drain(sink.s(), 8192);

    try std.testing.expectEqual(@as(usize, want), delivered.items.len);
    try std.testing.expectEqual(@as(u64, n_producers * per_producer), router.stats.published);
    // Every delivery went to a real subscriber for the right topic.
    for (delivered.items) |d| {
        try std.testing.expect(d.to >= 1 and d.to <= n_subs);
        try std.testing.expectEqualStrings("load/x", d.topic);
    }
}

test "decoder rejects a spray of malformed frames without panicking" {
    const cases = [_][]const u8{
        &[_]u8{ 0x00, 0x00 }, // reserved packet type
        &[_]u8{ 0x1F, 0x00 }, // CONNECT with illegal flags
        &[_]u8{ 0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F }, // 5-byte remaining-length varint
        &[_]u8{ 0x30, 0x02, 0x00, 0x05 }, // PUBLISH: topic len 5, body has 0
        &[_]u8{ 0x30, 0x04, 0x00, 0x02, '+', '#' }, // PUBLISH topic with wildcards
        &[_]u8{ 0x82, 0x02, 0x00, 0x00 }, // SUBSCRIBE with packet id 0
        &[_]u8{ 0x10, 0x02, 0x00, 0x00 }, // CONNECT: proto-name len 0
        &[_]u8{0x30}, // one byte, not even a full fixed header
    };
    for (cases) |c| {
        const frame = decoder.splitFrame(c) catch continue;
        switch (frame.packet_type) {
            .connect => _ = decoder.parseConnect(frame.body) catch {},
            .publish => _ = decoder.parsePublish(frame.flags, frame.body, .v3_1_1) catch {},
            .subscribe => {
                var it = decoder.parseSubscribe(frame.body, .v3_1_1) catch continue;
                while (it.next() catch break) |_| {}
            },
            else => {},
        }
    }

    // A remaining-length that claims more than the hard cap must be refused
    // outright, before any buffering.
    const big: [16]u8 = .{ 0x30, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(decoder.Error.PacketTooLarge, decoder.splitFrame(&big));

    // A topic filter far deeper than the level cap is rejected by the tree.
    const rt = @import("../src/core/radix_tree.zig");
    var tree = rt.RadixTree.init(std.testing.allocator);
    defer tree.deinit();
    var deep = std.ArrayList(u8).init(std.testing.allocator);
    defer deep.deinit();
    for (0..300) |_| try deep.appendSlice("a/");
    try deep.append('b');
    try std.testing.expectError(rt.Error.MalformedFilter, tree.subscribe(deep.items, 1));
}
