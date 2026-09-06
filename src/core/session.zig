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

/// Where an outbound QoS 1/2 message currently sits in its handshake.
pub const InflightState = enum {
    /// PUBLISH sent to the subscriber, waiting for PUBACK (QoS 1).
    awaiting_puback,
    /// PUBLISH sent, waiting for PUBREC (QoS 2, step 2).
    awaiting_pubrec,
    /// PUBREC received and PUBREL sent, waiting for PUBCOMP (QoS 2, step 4).
    awaiting_pubcomp,
};

/// A QoS 1/2 message we have sent (or are about to send) and are still tracking
/// for acknowledgement. Backed by the WAL for persistent sessions.
pub const InflightMessage = struct {
    packet_id: u16,
    qos: mqtt.Qos,
    state: InflightState,
    /// Offset of the `inflight_publish` record in the WAL, or 0 when not logged
    /// (clean session / no WAL configured).
    wal_offset: u64 = 0,
    sent_at_ms: i64,
    retries: u8 = 0,
};

pub const Session = struct {
    gpa: Allocator,
    id: SessionId,
    client_id: []const u8, // owned by `arena`
    version: mqtt.ProtocolLevel,
    persistent: bool,
    /// Live connection slot, or null when the session is detached but retained.
    conn_slot: ?u32,

    arena: std.heap.ArenaAllocator,
    subscriptions: std.ArrayListUnmanaged(Subscription) = .{},
    /// Outbound QoS>0 messages keyed by the packet id we assigned. Uses `gpa`
    /// (not the arena) because entries churn for the life of a session.
    inflight: std.AutoHashMapUnmanaged(u16, InflightMessage) = .{},
    next_packet_id: u16 = 1,
    session_expiry_s: u32 = 0,

    pub fn init(gpa: Allocator, id: SessionId, client_id: []const u8, version: mqtt.ProtocolLevel, persistent: bool) !Session {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned_id = try arena.allocator().dupe(u8, client_id);
        return .{
            .gpa = gpa,
            .id = id,
            .client_id = owned_id,
            .version = version,
            .persistent = persistent,
            .conn_slot = null,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Session) void {
        self.inflight.deinit(self.gpa);
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

    /// Begin tracking an outbound QoS>0 delivery. Returns the assigned packet id,
    /// or null when the inflight window is full (caller applies back-pressure).
    pub fn beginOutbound(self: *Session, qos: mqtt.Qos, wal_offset: u64, now_ms: i64) ?u16 {
        std.debug.assert(qos != .at_most_once);
        const pid = self.allocPacketId() orelse return null;
        self.inflight.put(self.gpa, pid, .{
            .packet_id = pid,
            .qos = qos,
            .state = if (qos == .at_least_once) .awaiting_puback else .awaiting_pubrec,
            .wal_offset = wal_offset,
            .sent_at_ms = now_ms,
        }) catch return null;
        return pid;
    }

    /// PUBACK arrived (QoS 1). True if it matched a tracked message.
    pub fn onPubAck(self: *Session, pid: u16) bool {
        const e = self.inflight.getPtr(pid) orelse return false;
        if (e.state != .awaiting_puback) return false;
        _ = self.inflight.remove(pid);
        return true;
    }

    /// PUBREC arrived (QoS 2, step 2). Transitions to awaiting PUBCOMP; the
    /// caller must now send PUBREL. True if it matched and advanced.
    pub fn onPubRec(self: *Session, pid: u16) bool {
        const e = self.inflight.getPtr(pid) orelse return false;
        if (e.state == .awaiting_pubcomp) return true; // idempotent re-PUBREC
        if (e.state != .awaiting_pubrec) return false;
        e.state = .awaiting_pubcomp;
        return true;
    }

    /// PUBCOMP arrived (QoS 2, step 4). Completes the handshake.
    pub fn onPubComp(self: *Session, pid: u16) bool {
        const e = self.inflight.getPtr(pid) orelse return false;
        if (e.state != .awaiting_pubcomp) return false;
        _ = self.inflight.remove(pid);
        return true;
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
    try s.inflight.put(s.gpa, 2, undefined);
    const b = s.allocPacketId().?;
    try std.testing.expectEqual(@as(u16, 3), b); // 2 skipped
}

test "qos2 outbound handshake advances publish -> pubrec -> pubcomp" {
    var s = try Session.init(std.testing.allocator, 1, "c", .v5_0, true);
    defer s.deinit();
    const pid = s.beginOutbound(.exactly_once, 0, 0).?;
    try std.testing.expect(!s.onPubAck(pid)); // wrong ack for qos2
    try std.testing.expect(s.onPubRec(pid));
    try std.testing.expect(s.onPubRec(pid)); // idempotent
    try std.testing.expect(!s.onPubComp(0xBEEF)); // unknown id
    try std.testing.expect(s.onPubComp(pid));
    try std.testing.expectEqual(@as(u32, 0), s.inflight.count());
}

test "qos1 outbound completes on puback" {
    var s = try Session.init(std.testing.allocator, 1, "c", .v3_1_1, true);
    defer s.deinit();
    const pid = s.beginOutbound(.at_least_once, 0, 0).?;
    try std.testing.expect(!s.onPubRec(pid));
    try std.testing.expect(s.onPubAck(pid));
    try std.testing.expectEqual(@as(u32, 0), s.inflight.count());
}

test "subscription add is idempotent on the filter" {
    var s = try Session.init(std.testing.allocator, 1, "c", .v3_1_1, false);
    defer s.deinit();
    try s.addSubscription("a/b", .at_most_once, false);
    try s.addSubscription("a/b", .at_least_once, false);
    try std.testing.expectEqual(@as(usize, 1), s.subscriptions.items.len);
    try std.testing.expectEqual(mqtt.Qos.at_least_once, s.subscriptions.items[0].qos);
}
