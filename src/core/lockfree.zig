//! Bounded lock-free queue used to hand messages from the network workers to the
//! central router without ever taking a mutex on the data path.
//!
//! This is Dmitry Vyukov's bounded MPMC algorithm: a power-of-two ring of cells,
//! each carrying a sequence counter. Producers and consumers advance shared
//! `enqueue_pos` / `dequeue_pos` with a CAS and then publish/consume the cell
//! whose sequence matches. No node allocation, no ABA window, wait-free for the
//! uncontended case and lock-free under contention.
//!
//! The broker instantiates it as MPSC (N network workers -> 1 router), which is
//! a strict subset of what the structure supports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cache_line = std.atomic.cache_line;

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            sequence: std.atomic.Value(usize),
            value: T,
        };

        buffer: []Cell,
        mask: usize,

        // Keep the two hot counters on separate cache lines so a producer and a
        // consumer spinning at the same time do not ping-pong one line.
        enqueue_pos: std.atomic.Value(usize) align(cache_line) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) align(cache_line) = std.atomic.Value(usize).init(0),

        pub fn init(gpa: Allocator, capacity: usize) !Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            std.debug.assert(capacity >= 2);
            const buf = try gpa.alloc(Cell, capacity);
            for (buf, 0..) |*cell, i| cell.sequence = std.atomic.Value(usize).init(i);
            return .{ .buffer = buf, .mask = capacity - 1 };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buffer);
        }

        /// Returns false when the ring is full. Safe from any number of threads.
        pub fn tryPush(self: *Self, item: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) -% @as(isize, @bitCast(pos));
                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual; // lost the race, retry with the new position
                    } else {
                        cell.value = item;
                        cell.sequence.store(pos +% 1, .release);
                        return true;
                    }
                } else if (diff < 0) {
                    return false; // full
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        /// Returns null when the ring is empty. Safe from any number of threads
        /// (the broker only ever calls it from the router thread).
        pub fn tryPop(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) -% @as(isize, @bitCast(pos +% 1));
                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                    } else {
                        const value = cell.value;
                        cell.sequence.store(pos +% self.mask +% 1, .release);
                        return value;
                    }
                } else if (diff < 0) {
                    return null; // empty
                } else {
                    pos = self.dequeue_pos.load(.monotonic);
                }
            }
        }

        /// Best-effort count; only exact when quiescent.
        pub fn len(self: *Self) usize {
            const e = self.enqueue_pos.load(.monotonic);
            const d = self.dequeue_pos.load(.monotonic);
            return e -% d;
        }
    };
}

test "single-threaded fifo behaviour and full/empty edges" {
    const Q = BoundedQueue(u32);
    var q = try Q.init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);

    try std.testing.expect(q.tryPop() == null);
    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    try std.testing.expect(q.tryPush(3));
    try std.testing.expect(q.tryPush(4));
    try std.testing.expect(!q.tryPush(5)); // full

    try std.testing.expectEqual(@as(?u32, 1), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), q.tryPop());
    try std.testing.expect(q.tryPush(5));
    try std.testing.expectEqual(@as(?u32, 3), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 4), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 5), q.tryPop());
    try std.testing.expect(q.tryPop() == null);
}

test "concurrent producers, single consumer, nothing lost or duplicated" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Q = BoundedQueue(u64);
    var q = try Q.init(std.testing.allocator, 1024);
    defer q.deinit(std.testing.allocator);

    const producers = 4;
    const per_producer = 10_000;

    const Ctx = struct {
        q: *Q,
        fn run(self: *@This(), base: u64) void {
            var i: u64 = 0;
            while (i < per_producer) {
                if (self.q.tryPush(base + i)) i += 1;
            }
        }
    };
    var ctx = Ctx{ .q = &q };

    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, @as(u64, idx) * 1_000_000 });
    }

    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var count: usize = 0;
    while (count < producers * per_producer) {
        if (q.tryPop()) |v| {
            try std.testing.expect(!seen.contains(v));
            try seen.put(v, {});
            count += 1;
        }
    }
    for (&threads) |*t| t.join();
    try std.testing.expect(q.tryPop() == null);
}
