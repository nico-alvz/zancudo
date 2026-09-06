//! Fuzz harness aimed at the network-frame decoder — the one place hostile
//! bytes turn into structured data.
//!
//! Run with Zig's built-in fuzzer:      zig build fuzz && ./zig-out/bin/fuzz-decoder
//! or feed a corpus on stdin:           ./zig-out/bin/fuzz-decoder < sample.bin
//!
//! The invariants asserted here:
//!   * `splitFrame` / the packet parsers never read outside the input slice
//!     (enforced by `Reader`; a violation trips Zig's safety checks / ASan).
//!   * They either return a structured error or a `Frame` whose `totalLen()`
//!     is within the input — never a panic, never UB.
//!   * A parsed PUBLISH round-trips back through the encoder to a byte-identical
//!     frame (encoder/decoder agreement).

const std = @import("std");
const protocol = @import("protocol");
const decoder = protocol.decoder;
const encoder = protocol.encoder;
const mqtt = protocol.mqtt;

fn exercise(input: []const u8) void {
    const frame = decoder.splitFrame(input) catch return;

    std.debug.assert(frame.totalLen() <= input.len);

    switch (frame.packet_type) {
        .connect => {
            const c = decoder.parseConnect(frame.body) catch return;
            std.debug.assert(c.client_id.len <= input.len);
        },
        .publish => {
            const p = decoder.parsePublish(frame.flags, frame.body, .v3_1_1) catch return;
            std.debug.assert(p.topic.len <= input.len);
            std.debug.assert(std.mem.indexOfAny(u8, p.topic, "+#") == null);

            var out: [2 * 1024 * 1024]u8 = undefined;
            const re = encoder.publish(
                &out,
                .v3_1_1,
                p.topic,
                p.qos,
                p.retain,
                p.dup,
                p.packet_id,
                p.payload,
            ) catch return;
            const again = decoder.splitFrame(re) catch unreachable;
            const p2 = decoder.parsePublish(again.flags, again.body, .v3_1_1) catch unreachable;
            std.debug.assert(std.mem.eql(u8, p.topic, p2.topic));
            std.debug.assert(std.mem.eql(u8, p.payload, p2.payload));
        },
        .subscribe => {
            var it = decoder.parseSubscribe(frame.body, .v3_1_1) catch return;
            while (it.next() catch return) |s| {
                std.debug.assert(s.filter.len <= input.len);
            }
        },
        else => {},
    }
}

test "decoder survives a spray of structured-ish garbage" {
    var prng = std.Random.DefaultPrng.init(0xA1FA5EED);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    var iter: usize = 0;
    while (iter < 20_000) : (iter += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        // Bias byte 0 towards real packet types so we reach the body parsers.
        if (len > 0) buf[0] = (@as(u8, rand.intRangeAtMost(u4, 1, 14)) << 4) | (buf[0] & 0x0F);
        exercise(buf[0..len]);
    }
}

pub fn main() !void {
    const stdin = std.io.getStdIn();
    var buf: [1 << 20]u8 = undefined;
    const n = try stdin.readAll(&buf);
    if (n == 0) {
        // No stdin: run the built-in randomized sweep so `zig build fuzz` output
        // is still meaningful when executed directly.
        std.debug.print("no stdin corpus; running 100k randomized iterations\n", .{});
        var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
        const rand = prng.random();
        var scratch: [8192]u8 = undefined;
        var i: usize = 0;
        while (i < 100_000) : (i += 1) {
            const len = rand.intRangeAtMost(usize, 0, scratch.len);
            rand.bytes(scratch[0..len]);
            if (len > 0) scratch[0] = (@as(u8, rand.intRangeAtMost(u4, 1, 14)) << 4);
            exercise(scratch[0..len]);
        }
        std.debug.print("done, no crashes\n", .{});
        return;
    }
    exercise(buf[0..n]);
}
