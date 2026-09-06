//! Per-client connection: socket, receive buffer, frame reassembly, and — the
//! point of this file — a dedicated arena allocator.
//!
//! Every byte a connection allocates (its parsed client-id, its subscription
//! filter copies, its will message, per-packet scratch) comes from
//! `self.arena`. On disconnect the broker calls `deinit`, the arena's whole
//! backing region is handed back in one `free`, and there is nothing to leak
//! and no heap fragmentation to accumulate over millions of short sessions.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const limits = @import("../security/limits.zig");
const mqtt = @import("../protocol/mqtt.zig");
const decoder = @import("../protocol/decoder.zig");

pub const State = enum {
    /// TCP up, no valid CONNECT yet. A client gets a short grace window here.
    awaiting_connect,
    /// CONNECT accepted, normal operation.
    established,
    /// We queued a response that must flush before we close.
    draining,
    closed,
};

pub const Connection = struct {
    fd: posix.fd_t,
    /// Reactor token == index into the broker's connection table.
    slot: u32,
    state: State = .awaiting_connect,
    version: mqtt.ProtocolLevel = .v3_1_1,
    /// Router session id, assigned once a valid CONNECT has been processed.
    session_id: ?u64 = null,

    /// Backing store for `arena`. One allocation for the connection's lifetime.
    arena: std.heap.ArenaAllocator,

    /// Bytes received but not yet consumed by a complete frame. Fixed capacity;
    /// a frame that cannot fit is a protocol error, not a reason to grow.
    rx: []u8,
    rx_len: usize = 0,

    /// Pending outbound bytes (CONNACK/PUBLISH/...) not yet written to the socket.
    tx: std.ArrayListUnmanaged(u8) = .{},

    /// Packet ids of inbound QoS 2 PUBLISHes we have accepted a PUBREC for but
    /// not yet seen the matching PUBREL. Lets us drop a DUP retransmit instead
    /// of delivering the message twice (MQTT-4.3.3). Keyed on `gpa`.
    qos2_rx: std.AutoHashMapUnmanaged(u16, void) = .{},

    peer: std.net.Address = undefined,
    connected_at_ms: i64 = 0,
    last_activity_ms: i64 = 0,
    keep_alive_s: u16 = 0,

    /// `gpa` is the process allocator; it backs the arena and the rx buffer.
    /// Everything the *session* touches after this uses `allocator()`.
    pub fn init(gpa: Allocator, fd: posix.fd_t, slot: u32, peer: std.net.Address) !Connection {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const rx = try gpa.alloc(u8, limits.connection_read_buffer);
        const now = std.time.milliTimestamp();
        return .{
            .fd = fd,
            .slot = slot,
            .arena = arena,
            .rx = rx,
            .peer = peer,
            .connected_at_ms = now,
            .last_activity_ms = now,
        };
    }

    pub fn deinit(self: *Connection, gpa: Allocator) void {
        self.tx.deinit(self.arena.allocator());
        self.qos2_rx.deinit(gpa);
        gpa.free(self.rx);
        // Single call releases every session allocation at once.
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Connection) Allocator {
        return self.arena.allocator();
    }

    /// Copy freshly-received socket bytes into the reassembly buffer.
    /// Returns `error.Overflow` (-> drop the connection) if the peer sends more
    /// unframed data than the fixed buffer can hold.
    pub fn ingest(self: *Connection, bytes: []const u8) error{Overflow}!void {
        if (self.rx_len + bytes.len > self.rx.len) return error.Overflow;
        @memcpy(self.rx[self.rx_len .. self.rx_len + bytes.len], bytes);
        self.rx_len += bytes.len;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Try to peel one complete frame off the front of the reassembly buffer.
    /// Returns null when more data is needed. On success the frame's bytes are
    /// still owned by `self.rx` and are only valid until `consume` is called.
    pub fn nextFrame(self: *Connection) decoder.Error!?decoder.Frame {
        if (self.rx_len == 0) return null;
        return decoder.splitFrame(self.rx[0..self.rx_len]) catch |e| switch (e) {
            decoder.Error.NeedMoreData => null,
            else => e,
        };
    }

    /// Drop `n` leading bytes after a frame has been handled.
    pub fn consume(self: *Connection, n: usize) void {
        std.debug.assert(n <= self.rx_len);
        const rest = self.rx_len - n;
        if (rest != 0) std.mem.copyForwards(u8, self.rx[0..rest], self.rx[n..self.rx_len]);
        self.rx_len = rest;
    }

    pub fn queueOut(self: *Connection, bytes: []const u8) Allocator.Error!void {
        try self.tx.appendSlice(self.arena.allocator(), bytes);
    }

    /// Non-blocking flush of `tx` to the socket. Returns true when `tx` is empty
    /// afterwards (nothing left to write); false means "re-arm for writable".
    pub fn flush(self: *Connection) posix.WriteError!bool {
        while (self.tx.items.len > 0) {
            const n = posix.write(self.fd, self.tx.items) catch |e| switch (e) {
                error.WouldBlock => return false,
                else => return e,
            };
            if (n == 0) return false;
            std.mem.copyForwards(u8, self.tx.items[0 .. self.tx.items.len - n], self.tx.items[n..]);
            self.tx.items.len -= n;
        }
        return true;
    }

    pub fn idleMillis(self: *const Connection, now_ms: i64) i64 {
        return now_ms - self.last_activity_ms;
    }
};
