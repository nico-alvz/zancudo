//! Local-first mesh layer.
//!
//! Goal, borrowed from self-healing mesh networks like Thread: a broker node
//! keeps serving its locally-connected clients even when every peer is
//! unreachable, and topic ownership re-homes automatically and deterministically
//! when a node drops.
//!
//! Implemented here:
//!   * Shard model — a topic maps to a shard by its first level, so all traffic
//!     for "sensors/#" at one site stays on one node under normal operation.
//!   * Ownership by **rendezvous hashing (HRW)** over the *alive* members. HRW
//!     moves only ~1/N of shards when a node joins or leaves, so a failure
//!     re-homes the minimum possible traffic.
//!   * A time-based failure detector: alive -> suspect -> dead based on the age
//!     of the last heartbeat, with a monotonically increasing `epoch` bumped on
//!     every membership change so stragglers can detect stale ownership.
//!
//! Left as `TODO` (needs a socket): the gossip transport that carries
//! heartbeats and retained/subscription deltas between nodes. Everything below
//! is pure, deterministic, and unit-tested, and the single-node broker keeps
//! working because `enabled == false` short-circuits to "owns everything".

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NodeId = u64;

pub const PeerState = enum { alive, suspect, dead };

pub const Peer = struct {
    id: NodeId,
    addr: std.net.Address = undefined,
    state: PeerState = .alive,
    /// Lamport-ish clock of the last gossip message we accepted from this peer.
    last_seen_seq: u64 = 0,
    last_seen_ms: i64 = 0,
};

pub const Config = struct {
    /// No heartbeat for this long -> the peer is `suspect`.
    suspect_after_ms: i64 = 3_000,
    /// No heartbeat for this long -> the peer is `dead` and its shards re-home.
    dead_after_ms: i64 = 10_000,
};

pub const Mesh = struct {
    gpa: Allocator,
    self_id: NodeId,
    cfg: Config = .{},
    peers: std.AutoHashMapUnmanaged(NodeId, Peer) = .{},
    enabled: bool = false,
    /// Bumped on every membership transition (join, alive<->dead). Ownership
    /// answers computed under an older epoch must be treated as stale.
    epoch: u64 = 0,

    pub fn init(gpa: Allocator, self_id: NodeId) Mesh {
        return .{ .gpa = gpa, .self_id = self_id };
    }

    pub fn deinit(self: *Mesh) void {
        self.peers.deinit(self.gpa);
    }

    // -- shard model ------------------------------------------------------

    /// Map a topic to its shard id (stable, first-level based).
    pub fn shardOf(topic: []const u8) u16 {
        const end = std.mem.indexOfScalar(u8, topic, '/') orelse topic.len;
        return @truncate(std.hash.Wyhash.hash(0, topic[0..end]));
    }

    /// HRW weight of a (node, shard) pair. The node with the highest weight owns
    /// the shard.
    fn weight(node: NodeId, shard: u16) u64 {
        var h = std.hash.Wyhash.init(0x9E3779B97F4A7C15);
        h.update(std.mem.asBytes(&node));
        h.update(std.mem.asBytes(&shard));
        return h.final();
    }

    /// Deterministic owner of `shard` among this node plus every `alive` peer.
    /// With no peers (or the layer disabled) that is always `self_id`.
    pub fn ownerOf(self: *const Mesh, shard: u16) NodeId {
        var best_id = self.self_id;
        var best_w = weight(self.self_id, shard);
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            if (p.state == .dead) continue;
            const w = weight(p.id, shard);
            if (w > best_w or (w == best_w and p.id < best_id)) {
                best_w = w;
                best_id = p.id;
            }
        }
        return best_id;
    }

    /// True when this node should process `topic` locally.
    pub fn ownsLocally(self: *const Mesh, topic: []const u8) bool {
        if (!self.enabled) return true;
        return self.ownerOf(shardOf(topic)) == self.self_id;
    }

    // -- membership / failure detection --------------------------------

    /// Record a heartbeat (or any accepted gossip) from `id`. Adds the peer if
    /// unknown and revives a suspect/dead one.
    pub fn recordHeartbeat(self: *Mesh, id: NodeId, seq: u64, now_ms: i64) !void {
        if (id == self.self_id) return;
        const gop = try self.peers.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = id };
            self.epoch += 1;
        } else if (gop.value_ptr.state == .dead) {
            self.epoch += 1; // resurrection is a membership change
        }
        if (seq >= gop.value_ptr.last_seen_seq) gop.value_ptr.last_seen_seq = seq;
        gop.value_ptr.last_seen_ms = now_ms;
        gop.value_ptr.state = .alive;
    }

    /// Age every peer's liveness against the clock. Returns true if any peer
    /// crossed into `dead` this tick (ownership for its shards has moved).
    pub fn tick(self: *Mesh, now_ms: i64) bool {
        var any_died = false;
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            const age = now_ms - p.last_seen_ms;
            const next: PeerState = if (age >= self.cfg.dead_after_ms)
                .dead
            else if (age >= self.cfg.suspect_after_ms)
                .suspect
            else
                .alive;
            if (next != p.state) {
                if (next == .dead or p.state == .dead) self.epoch += 1;
                if (next == .dead) any_died = true;
                p.state = next;
            }
        }
        return any_died;
    }

    /// Count of members currently able to own shards (this node + alive peers).
    pub fn aliveCount(self: *const Mesh) usize {
        var n: usize = 1; // self
        var it = self.peers.valueIterator();
        while (it.next()) |p| {
            if (p.state != .dead) n += 1;
        }
        return n;
    }

    pub fn stateOf(self: *const Mesh, id: NodeId) ?PeerState {
        if (id == self.self_id) return .alive;
        const p = self.peers.get(id) orelse return null;
        return p.state;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "shard assignment is stable per first level" {
    try std.testing.expectEqual(Mesh.shardOf("sensors/plant1/temp"), Mesh.shardOf("sensors/plant2/pressure"));
    try std.testing.expect(Mesh.shardOf("sensors/x") != Mesh.shardOf("actuators/x"));
}

test "single-node mesh always owns every topic" {
    var m = Mesh.init(std.testing.allocator, 1);
    defer m.deinit();
    m.enabled = true;
    try std.testing.expect(m.ownsLocally("anything/at/all"));
    try std.testing.expectEqual(@as(usize, 1), m.aliveCount());
}

test "HRW ownership partitions shards and moves ~1/N on membership change" {
    var m = Mesh.init(std.testing.allocator, 1);
    defer m.deinit();
    m.enabled = true;
    try m.recordHeartbeat(2, 1, 0);
    try m.recordHeartbeat(3, 1, 0);
    try m.recordHeartbeat(4, 1, 0);

    var owner_before: [4096]NodeId = undefined;
    var mine: usize = 0;
    for (0..4096) |s| {
        owner_before[s] = m.ownerOf(@intCast(s));
        if (owner_before[s] == 1) mine += 1;
    }
    // Four members -> each owns roughly a quarter (generous bounds).
    try std.testing.expect(mine > 4096 / 8 and mine < 4096 / 2);

    // Node 4 dies: only shards it owned may move, and they move to a survivor.
    m.peers.getPtr(4).?.state = .dead;
    var moved: usize = 0;
    for (0..4096) |s| {
        const now = m.ownerOf(@intCast(s));
        if (now != owner_before[s]) {
            try std.testing.expectEqual(@as(NodeId, 4), owner_before[s]);
            try std.testing.expect(now != 4);
            moved += 1;
        }
    }
    try std.testing.expect(moved > 0 and moved < 4096 / 2);
}

test "failure detector walks alive -> suspect -> dead and bumps epoch" {
    var m = Mesh.init(std.testing.allocator, 1);
    defer m.deinit();
    m.cfg = .{ .suspect_after_ms = 100, .dead_after_ms = 500 };

    try m.recordHeartbeat(2, 1, 1_000);
    const e0 = m.epoch;
    try std.testing.expectEqual(PeerState.alive, m.stateOf(2).?);

    _ = m.tick(1_150); // +150ms
    try std.testing.expectEqual(PeerState.suspect, m.stateOf(2).?);

    const died = m.tick(1_600); // +600ms
    try std.testing.expect(died);
    try std.testing.expectEqual(PeerState.dead, m.stateOf(2).?);
    try std.testing.expect(m.epoch > e0);

    // A late heartbeat resurrects it and bumps the epoch again.
    const e1 = m.epoch;
    try m.recordHeartbeat(2, 2, 1_700);
    try std.testing.expectEqual(PeerState.alive, m.stateOf(2).?);
    try std.testing.expect(m.epoch > e1);
}
