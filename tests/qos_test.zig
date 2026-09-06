//! End-to-end QoS 1 / QoS 2 flow through the router: a publish fans out to a
//! subscriber, the router assigns a per-session packet id, and the subscriber's
//! acknowledgements drive the inflight state machine to completion.

const std = @import("std");
const router_mod = @import("../src/core/router.zig");
const Router = router_mod.Router;
const CommandQueue = router_mod.CommandQueue;
const Delivery = router_mod.Delivery;
const Session = @import("../src/core/session.zig").Session;
const Mesh = @import("../src/cluster/mesh.zig").Mesh;
const mqtt = @import("../src/protocol/mqtt.zig");

const Harness = struct {
    mesh: Mesh,
    queue: CommandQueue,
    router: Router,
    got: std.ArrayList(Delivery),

    fn sink(self: *Harness) Router.DeliverySink {
        return .{ .ctx = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, d: Delivery) void {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.got.append(d) catch unreachable;
    }
    fn pump(self: *Harness) void {
        _ = self.router.drain(self.sink(), 256);
    }
};

fn newHarness(a: std.mem.Allocator) !*Harness {
    const h = try a.create(Harness);
    h.* = .{
        .mesh = Mesh.init(a, 1),
        .queue = try CommandQueue.init(a, 128),
        .router = undefined,
        .got = std.ArrayList(Delivery).init(a),
    };
    h.router = Router.init(a, &h.queue, null, &h.mesh);
    return h;
}

fn destroyHarness(a: std.mem.Allocator, h: *Harness) void {
    h.router.deinit();
    h.queue.deinit(a);
    h.mesh.deinit();
    h.got.deinit();
    a.destroy(h);
}

fn attach(a: std.mem.Allocator, h: *Harness, id: u64, ver: mqtt.ProtocolLevel) !*Session {
    const s = try a.create(Session);
    s.* = try Session.init(a, id, "c", ver, true);
    try std.testing.expect(h.queue.tryPush(.{ .attach_session = .{ .session = s } }));
    return s;
}

test "qos2 delivery: publish -> pubrec -> pubrel -> pubcomp, inflight cleared" {
    const a = std.testing.allocator;
    const h = try newHarness(a);
    defer destroyHarness(a, h);

    const sub = try attach(a, h, 100, .v5_0);
    _ = try attach(a, h, 200, .v5_0);
    try std.testing.expect(h.queue.tryPush(.{ .subscribe = .{ .id = 100, .filter = "iot/+/data", .qos = .exactly_once, .no_local = false } }));
    try std.testing.expect(h.queue.tryPush(.{ .publish = .{ .from = 200, .topic = "iot/dev9/data", .qos = .exactly_once, .retain = false, .payload = "x" } }));
    h.pump();

    // One outbound PUBLISH with an assigned packet id; session is tracking it.
    try std.testing.expectEqual(@as(usize, 1), h.got.items.len);
    const d0 = h.got.items[0];
    try std.testing.expectEqual(router_mod.DeliveryKind.publish, d0.kind);
    try std.testing.expectEqual(mqtt.Qos.exactly_once, d0.qos);
    const pid = d0.packet_id.?;
    try std.testing.expectEqual(@as(u32, 1), sub.inflight.count());

    // Subscriber replies PUBREC -> router must answer with PUBREL.
    try std.testing.expect(h.queue.tryPush(.{ .pub_rec = .{ .id = 100, .packet_id = pid } }));
    h.pump();
    try std.testing.expectEqual(@as(usize, 2), h.got.items.len);
    try std.testing.expectEqual(router_mod.DeliveryKind.pubrel, h.got.items[1].kind);
    try std.testing.expectEqual(pid, h.got.items[1].packet_id.?);

    // PUBCOMP completes the handshake.
    try std.testing.expect(h.queue.tryPush(.{ .pub_comp = .{ .id = 100, .packet_id = pid } }));
    h.pump();
    try std.testing.expectEqual(@as(u32, 0), sub.inflight.count());
    try std.testing.expectEqual(@as(u64, 1), h.router.stats.qos2_completed);
}

test "qos1 delivery clears inflight on puback; downgrades to subscriber grant" {
    const a = std.testing.allocator;
    const h = try newHarness(a);
    defer destroyHarness(a, h);

    const sub = try attach(a, h, 1, .v3_1_1);
    _ = try attach(a, h, 2, .v3_1_1);
    // Subscriber only granted QoS 1; publisher sends QoS 2 -> effective QoS 1.
    try std.testing.expect(h.queue.tryPush(.{ .subscribe = .{ .id = 1, .filter = "a/b", .qos = .at_least_once, .no_local = false } }));
    try std.testing.expect(h.queue.tryPush(.{ .publish = .{ .from = 2, .topic = "a/b", .qos = .exactly_once, .retain = false, .payload = "hi" } }));
    h.pump();

    try std.testing.expectEqual(@as(usize, 1), h.got.items.len);
    try std.testing.expectEqual(mqtt.Qos.at_least_once, h.got.items[0].qos);
    const pid = h.got.items[0].packet_id.?;
    try std.testing.expectEqual(@as(u32, 1), sub.inflight.count());

    try std.testing.expect(h.queue.tryPush(.{ .pub_ack = .{ .id = 1, .packet_id = pid } }));
    h.pump();
    try std.testing.expectEqual(@as(u32, 0), sub.inflight.count());
}

test "qos0 delivery carries no packet id and no inflight" {
    const a = std.testing.allocator;
    const h = try newHarness(a);
    defer destroyHarness(a, h);

    const sub = try attach(a, h, 1, .v3_1_1);
    _ = try attach(a, h, 2, .v3_1_1);
    try std.testing.expect(h.queue.tryPush(.{ .subscribe = .{ .id = 1, .filter = "t", .qos = .at_most_once, .no_local = false } }));
    try std.testing.expect(h.queue.tryPush(.{ .publish = .{ .from = 2, .topic = "t", .qos = .at_most_once, .retain = false, .payload = "p" } }));
    h.pump();

    try std.testing.expectEqual(@as(usize, 1), h.got.items.len);
    try std.testing.expectEqual(@as(?u16, null), h.got.items[0].packet_id);
    try std.testing.expectEqual(@as(u32, 0), sub.inflight.count());
}
