//! MQTT "variable byte integer" (a.k.a. remaining-length varint).
//!
//! 1..4 bytes, 7 payload bits each, little-endian, high bit = "more follows".
//! Max encodable value is 268_435_455. A 5th continuation byte is a protocol
//! error and must be rejected before it can overflow anything.

const std = @import("std");
const limits = @import("../security/limits.zig");

pub const DecodeError = error{
    /// Ran out of bytes mid-varint (need more data, not necessarily fatal).
    Incomplete,
    /// A 5th continuation byte, or a value above the protocol ceiling.
    Overlong,
};

pub const Decoded = struct {
    value: u32,
    /// How many bytes the varint occupied (1..4).
    len: u8,
};

/// Decode a varint from the front of `bytes`. Never reads past `bytes.len`.
pub fn decode(bytes: []const u8) DecodeError!Decoded {
    var value: u32 = 0;
    var multiplier: u32 = 1;
    var i: u8 = 0;
    while (i < limits.max_remaining_length_bytes) : (i += 1) {
        if (i >= bytes.len) return DecodeError.Incomplete;
        const byte = bytes[i];
        value += @as(u32, byte & 0x7F) * multiplier;
        if (byte & 0x80 == 0) return .{ .value = value, .len = i + 1 };
        multiplier *= 128;
    }
    // Fell out of the loop -> a 4th byte still had the continuation bit set.
    return DecodeError.Overlong;
}

/// Encode `value` into `out` (must have room for 4 bytes). Returns the slice
/// actually written. Asserts the value is within the protocol ceiling.
pub fn encode(value: u32, out: *[4]u8) []const u8 {
    std.debug.assert(value <= 268_435_455);
    var v = value;
    var i: usize = 0;
    while (true) {
        var byte: u8 = @intCast(v % 128);
        v /= 128;
        if (v > 0) byte |= 0x80;
        out[i] = byte;
        i += 1;
        if (v == 0) break;
    }
    return out[0..i];
}

/// Compile-time size of the varint for a known constant. Handy for building
/// fixed-size response frames without a scratch buffer.
pub fn comptimeLen(comptime value: u32) comptime_int {
    return switch (value) {
        0...127 => 1,
        128...16_383 => 2,
        16_384...2_097_151 => 3,
        else => 4,
    };
}

test "varint round trip" {
    const cases = [_]u32{ 0, 1, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455 };
    for (cases) |c| {
        var buf: [4]u8 = undefined;
        const enc = encode(c, &buf);
        const dec = try decode(enc);
        try std.testing.expectEqual(c, dec.value);
        try std.testing.expectEqual(@as(u8, @intCast(enc.len)), dec.len);
    }
}

test "comptimeLen agrees with the runtime encoder" {
    inline for (.{ 0, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455 }) |c| {
        var buf: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, comptimeLen(c)), encode(c, &buf).len);
    }
}

test "varint rejects a 5-byte sequence" {
    try std.testing.expectError(DecodeError.Overlong, decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F }));
}

test "varint reports incomplete without reading past the slice" {
    try std.testing.expectError(DecodeError.Incomplete, decode(&[_]u8{ 0x80, 0x80 }));
}
