//! Session bookkeeping: what the router needs to know about a connected client
//! independent of the socket. A persistent session (clean_start = false) can
//! outlive its `Connection`; a clean session is discarded on disconnect.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mqtt = @import("../protocol/mqtt.zig");
const limits = @import("../security/limits.zig");

pub const SessionId = u64;

pub const Subscription = struct {
    filter: []const u8, // owned by the session arena
    qos: mqtt.Qos,
    no_local: bool = false,
};

/// A QoS 1/2 message we have sent (or are about to send) and are still tracking
/// for acknowledgement. Backed by the WAL for persistent sessions.
pub const InflightMessage = struct {
    packet_id: u16,
    qos: mqtt.Qos,
    /// PUBLISH sent, waiting for PUBACK (qos1) / PUBREC (qos2).
    awaiting: enum { puback, pubrec, pubcomp },
    payload_wal_offset: u64,
    sent_at_ms: i64,
    retries: u8 = 0,
};

pub const Session = struct {
    id: SessionId,
    client_id: []const u8, // owned by `arena`
    version: mqtt.ProtocolLevel,
    persistent: bool,
    /// Live connection slot, or null when the session is detached but retained.
    conn_slot: ?u32,

    arena: std.heap.ArenaAllocator,
    subscriptions: std.ArrayListUnmanaged(Subscription) = .{},
    inflight: std.AutoHashMapUnmanaged(u16, InflightMessage) = .{},
    next_packet_id: u16 = 1,
    session_expiry_s: u32 = 0,

    pub fn init(gpa: Allocator, id: SessionId, client_id: []const u8, version: mqtt.ProtocolLevel, persistent: bool) !Session {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned_id = try arena.allocator().dupe(u8, client_id);
        return .{
            .id = id,
            .client_id = owned_id,
            .version = version,
            .persistent = persistent,
            .conn_slot = null,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Rotating packet-id allocator that skips ids currently inflight.
    pub fn allocPacketId(self: *Session) ?u16 {
        if (self.inflight.count() >= limits.max_inflight_per_session) return null;
        var tries: u32 = 0;
        while (tries < 0x10000) : (tries += 1) {
            const id = self.next_packet_id;
            self.next_packet_id = if (id == 0xFFFF) 1 else id + 1;
            if (!self.inflight.contains(id)) return id;
        }
        return null;
    }

    pub fn addSubscription(self: *Session, filter: []const u8, qos: mqtt.Qos, no_local: bool) !void {
        const a = self.arena.allocator();
        for (self.subscriptions.items) |*s| {
            if (std.mem.eql(u8, s.filter, filter)) {
                s.qos = qos; // re-subscribe just updates the granted QoS
                s.no_local = no_local;
                return;
            }
        }
        try self.subscriptions.append(a, .{
            .filter = try a.dupe(u8, filter),
            .qos = qos,
            .no_local = no_local,
        });
    }

    pub fn removeSubscription(self: *Session, filter: []const u8) bool {
        for (self.subscriptions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.filter, filter)) {
                _ = self.subscriptions.swapRemove(i);
                return true;
            }
        }
        return false;
    }
};

test "packet id allocation rotates and avoids inflight ids" {
    var s = try Session.init(std.testing.allocator, 1, "c", .v5_0, true);
    defer s.deinit();
    const a = s.allocPacketId().?;
    try std.testing.expectEqual(@as(u16, 1), a);
    try s.inflight.put(s.arena.allocator(), 2, undefined);
    const b = s.allocPacketId().?;
    try std.testing.expectEqual(@as(u16, 3), b); // 2 skipped
}

test "subscription add is idempotent on the filter" {
    var s = try Session.init(std.testing.allocator, 1, "c", .v3_1_1, false);
    defer s.deinit();
    try s.addSubscription("a/b", .at_most_once, false);
    try s.addSubscription("a/b", .at_least_once, false);
    try std.testing.expectEqual(@as(usize, 1), s.subscriptions.items.len);
    try std.testing.expectEqual(mqtt.Qos.at_least_once, s.subscriptions.items[0].qos);
}
