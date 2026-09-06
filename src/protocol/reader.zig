//! A cursor over an immutable byte slice. Every accessor is bounds-checked and
//! returns `error.Truncated` instead of panicking or reading out of range. This
//! is the single choke point the fuzzers hammer: if a malformed frame can get
//! past `Reader`, it can get into the broker.

const std = @import("std");
const limits = @import("../security/limits.zig");

pub const Error = error{
    /// The frame claimed more bytes than the buffer holds.
    Truncated,
    /// A declared length exceeded a hard protocol limit.
    LengthLimitExceeded,
    /// A u16-prefixed string was not valid UTF-8.
    InvalidUtf8,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn isAtEnd(self: *const Reader) bool {
        return self.pos == self.buf.len;
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.remaining() < 1) return Error.Truncated;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn u16be(self: *Reader) Error!u16 {
        if (self.remaining() < 2) return Error.Truncated;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    pub fn u32be(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return Error.Truncated;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    /// Borrow `n` raw bytes without copying. The slice aliases the frame buffer
    /// and is only valid for the frame's lifetime.
    pub fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.remaining() < n) return Error.Truncated;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// MQTT string: u16 big-endian length prefix, then that many UTF-8 bytes.
    /// The returned slice aliases the frame buffer (zero copy).
    pub fn mqttString(self: *Reader) Error![]const u8 {
        const n = try self.u16be();
        if (n > limits.max_string_len) return Error.LengthLimitExceeded;
        const s = try self.bytes(n);
        if (!std.unicode.utf8ValidateSlice(s)) return Error.InvalidUtf8;
        return s;
    }

    /// MQTT binary data: identical framing to a string, no UTF-8 constraint.
    pub fn mqttBinary(self: *Reader) Error![]const u8 {
        const n = try self.u16be();
        if (n > limits.max_string_len) return Error.LengthLimitExceeded;
        return self.bytes(n);
    }

    /// Skip `n` bytes, checked.
    pub fn skip(self: *Reader, n: usize) Error!void {
        if (self.remaining() < n) return Error.Truncated;
        self.pos += n;
    }
};

test "reader never reads past its buffer" {
    var r = Reader.init(&[_]u8{ 0x00, 0x03, 'a', 'b' }); // says 3 bytes, only 2 present
    try std.testing.expectError(Error.Truncated, r.mqttString());
}

test "reader decodes a well-formed mqtt string" {
    var r = Reader.init(&[_]u8{ 0x00, 0x03, 'a', 'b', 'c', 0xEE });
    const s = try r.mqttString();
    try std.testing.expectEqualStrings("abc", s);
    try std.testing.expectEqual(@as(u8, 0xEE), try r.byte());
    try std.testing.expect(r.isAtEnd());
}
