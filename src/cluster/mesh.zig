//! Local-first mesh layer (design scaffold).
//!
//! The goal, borrowed from self-healing mesh networks like Thread: a broker
//! node keeps serving its locally-connected clients even when every peer is
//! unreachable, and topic ownership re-homes automatically when a node drops.
//!
//! This module defines the data model and the interfaces the router calls into;
//! the transport (QUIC / mTLS gossip) and the CRDT merge are intentionally left
//! as `TODO` so the single-node broker builds and runs today without a cluster.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeId = u64;

pub const PeerState = enum { alive, suspect, dead };

pub const Peer = struct {
    id: NodeId,
    addr: std.net.Address,
    state: PeerState = .alive,
    /// Lamport-ish clock for last message we accepted from this peer.
    last_seen_seq: u64 = 0,
    last_seen_ms: i64 = 0,
};

/// Which node is currently authoritative for a topic-filter shard. A shard is a
/// hash-range over the first topic level, so "sensors/#" traffic for one plant
/// stays on one node under normal operation.
pub const ShardOwnership = struct {
    shard: u16,
    owner: NodeId,
    epoch: u64,
};

pub const Mesh = struct {
    gpa: Allocator,
    self_id: NodeId,
    peers: std.AutoHashMapUnmanaged(NodeId, Peer) = .{},
    ownership: std.AutoHashMapUnmanaged(u16, ShardOwnership) = .{},
    enabled: bool = false,

    pub fn init(gpa: Allocator, self_id: NodeId) Mesh {
        return .{ .gpa = gpa, .self_id = self_id };
    }

    pub fn deinit(self: *Mesh) void {
        self.peers.deinit(self.gpa);
        self.ownership.deinit(self.gpa);
    }

    /// Map a topic to its shard id (stable, first-level based).
    pub fn shardOf(topic: []const u8) u16 {
        const end = std.mem.indexOfScalar(u8, topic, '/') orelse topic.len;
        return @truncate(std.hash.Wyhash.hash(0, topic[0..end]));
    }

    /// True when this node should process the topic locally (single-node mode
    /// always returns true).
    pub fn ownsLocally(self: *const Mesh, topic: []const u8) bool {
        if (!self.enabled) return true;
        const o = self.ownership.get(shardOf(topic)) orelse return true;
        return o.owner == self.self_id;
    }

    /// TODO: gossip round — exchange digests with a random alive peer, apply
    /// received retained-set / subscription deltas through the WAL, and run
    /// failure detection (phi-accrual) to move peers alive -> suspect -> dead.
    pub fn tick(self: *Mesh, now_ms: i64) void {
        _ = self;
        _ = now_ms;
    }

    /// TODO: on peer death, deterministically re-assign its shards to the
    /// lowest-id alive peer and bump the ownership epoch so stragglers converge.
    pub fn onPeerDead(self: *Mesh, dead: NodeId) void {
        _ = self;
        _ = dead;
    }
};

test "shard assignment is stable per first level" {
    const a = Mesh.shardOf("sensors/plant1/temp");
    const b = Mesh.shardOf("sensors/plant2/pressure");
    try std.testing.expectEqual(a, b); // same first level -> same shard
    const c = Mesh.shardOf("actuators/plant1/valve");
    try std.testing.expect(a != c);
}

test "single-node mesh always owns every topic" {
    var m = Mesh.init(std.testing.allocator, 1);
    defer m.deinit();
    try std.testing.expect(m.ownsLocally("anything/at/all"));
}
