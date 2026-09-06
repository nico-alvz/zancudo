//! Bounds-checked MQTT control-packet decoder for v3.1.1 and v5.0.
//!
//! Design rules:
//!   * No allocation. Parsed views alias the caller's frame buffer.
//!   * Every length comes from `security/limits.zig` before any slicing.
//!   * `splitFrame` tells a streaming caller exactly how many bytes a frame
//!     needs, so the reactor can wait for a whole packet before parsing.

const std = @import("std");
const mqtt = @import("mqtt.zig");
const varint = @import("varint.zig");
const limits = @import("../security/limits.zig");
const Reader = @import("reader.zig").Reader;
const ReaderError = @import("reader.zig").Error;

pub const Error = ReaderError || error{
    NeedMoreData,
    MalformedFixedHeader,
    PacketTooLarge,
    ReservedPacketType,
    InvalidFlags,
    InvalidQos,
    UnsupportedProtocolVersion,
    ProtocolViolation,
};

/// The fixed header plus a slice covering exactly the variable header + payload.
pub const Frame = struct {
    packet_type: mqtt.PacketType,
    flags: u4,
    /// Offset of the first body byte within the original stream buffer.
    body_offset: usize,
    /// Variable header + payload, aliasing the stream buffer.
    body: []const u8,

    pub fn totalLen(self: Frame) usize {
        return self.body_offset + self.body.len;
    }
};

/// Peel one frame off the front of a stream buffer.
///
/// Returns `error.NeedMoreData` (not a failure) when `stream` does not yet hold
/// a complete packet — the caller should read more and retry with the same
/// buffer. Any other error means the connection must be dropped.
pub fn splitFrame(stream: []const u8) Error!Frame {
    if (stream.len < 2) return Error.NeedMoreData;

    const byte0 = stream[0];
    const type_nibble: u4 = @intCast(byte0 >> 4);
    const flag_nibble: u4 = @intCast(byte0 & 0x0F);
    const ptype = mqtt.PacketType.fromNibble(type_nibble);

    if (ptype == .reserved0) return Error.ReservedPacketType;

    // PUBLISH carries meaningful flags; everything else has a mandated pattern.
    if (ptype != .publish and flag_nibble != mqtt.requiredFlags(ptype)) {
        return Error.InvalidFlags;
    }
    if (ptype == .publish) {
        const pf = mqtt.PublishFlags.decode(flag_nibble);
        if (mqtt.Qos.fromBits(pf.qos) == null) return Error.InvalidQos;
    }

    const rl = varint.decode(stream[1..]) catch |e| switch (e) {
        varint.DecodeError.Incomplete => return Error.NeedMoreData,
        varint.DecodeError.Overlong => return Error.MalformedFixedHeader,
    };
    if (rl.value > limits.max_packet_len) return Error.PacketTooLarge;

    const header_len = 1 + @as(usize, rl.len);
    const total = header_len + rl.value;
    if (stream.len < total) return Error.NeedMoreData;

    return .{
        .packet_type = ptype,
        .flags = flag_nibble,
        .body_offset = header_len,
        .body = stream[header_len..total],
    };
}

// ---------------------------------------------------------------------------
// Packet bodies. Each parser takes the `Frame.body` slice and returns a view.
// ---------------------------------------------------------------------------

pub const Connect = struct {
    protocol: mqtt.ProtocolLevel,
    flags: mqtt.ConnectFlags,
    keep_alive: u16,
    client_id: []const u8,
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// v5 properties are validated for framing but not interpreted here.
    properties_len: u32 = 0,
};

pub fn parseConnect(body: []const u8) Error!Connect {
    var r = Reader.init(body);

    const proto_name = try r.mqttString();
    if (!std.mem.eql(u8, proto_name, "MQTT") and !std.mem.eql(u8, proto_name, "MQIsdp")) {
        return Error.ProtocolViolation;
    }
    const level = mqtt.ProtocolLevel.fromByte(try r.byte()) orelse
        return Error.UnsupportedProtocolVersion;

    const cflags = mqtt.ConnectFlags.decode(try r.byte());
    if (cflags.reserved) return Error.ProtocolViolation;
    if (mqtt.Qos.fromBits(cflags.will_qos) == null) return Error.InvalidQos;
    if (!cflags.will_flag and (cflags.will_qos != 0 or cflags.will_retain)) {
        return Error.ProtocolViolation;
    }

    const keep_alive = try r.u16be();

    var props_len: u32 = 0;
    if (level == .v5_0) {
        const p = try readPropertyBlock(&r);
        props_len = p;
    }

    const client_id = try r.mqttString();
    if (client_id.len > limits.max_client_id_len) return Error.LengthLimitExceeded;

    var out = Connect{
        .protocol = level,
        .flags = cflags,
        .keep_alive = keep_alive,
        .client_id = client_id,
        .properties_len = props_len,
    };

    if (cflags.will_flag) {
        if (level == .v5_0) _ = try readPropertyBlock(&r); // will properties
        out.will_topic = try r.mqttString();
        out.will_payload = try r.mqttBinary();
    }
    if (cflags.username_flag) out.username = try r.mqttString();
    if (cflags.password_flag) out.password = try r.mqttBinary();

    return out;
}

pub const Publish = struct {
    topic: []const u8,
    qos: mqtt.Qos,
    retain: bool,
    dup: bool,
    packet_id: ?u16, // present iff qos > 0
    payload: []const u8,
};

pub fn parsePublish(flags: u4, body: []const u8, version: mqtt.ProtocolLevel) Error!Publish {
    const pf = mqtt.PublishFlags.decode(flags);
    const qos = mqtt.Qos.fromBits(pf.qos) orelse return Error.InvalidQos;
    if (pf.dup and qos == .at_most_once) return Error.ProtocolViolation;

    var r = Reader.init(body);
    const topic = try r.mqttString();
    if (topic.len == 0 or topic.len > limits.max_topic_len) return Error.LengthLimitExceeded;
    // A PUBLISH topic name must not contain wildcards.
    if (std.mem.indexOfAny(u8, topic, "+#") != null) return Error.ProtocolViolation;

    var packet_id: ?u16 = null;
    if (qos != .at_most_once) packet_id = try r.u16be();

    if (version == .v5_0) _ = try readPropertyBlock(&r);

    return .{
        .topic = topic,
        .qos = qos,
        .retain = pf.retain,
        .dup = pf.dup,
        .packet_id = packet_id,
        .payload = try r.bytes(r.remaining()),
    };
}

pub const Subscription = struct {
    filter: []const u8,
    qos: mqtt.Qos,
    no_local: bool = false,
    retain_as_published: bool = false,
};

/// Iterator over the (filter, options) pairs in a SUBSCRIBE payload. Bounded by
/// `limits.max_topic_levels` worth of filters implicitly through the frame cap.
pub const SubscribeIterator = struct {
    reader: Reader,
    packet_id: u16,
    version: mqtt.ProtocolLevel,

    pub fn next(self: *SubscribeIterator) Error!?Subscription {
        if (self.reader.isAtEnd()) return null;
        const filter = try self.reader.mqttString();
        if (filter.len == 0 or filter.len > limits.max_topic_len) return Error.LengthLimitExceeded;
        const opts = try self.reader.byte();
        const qos = mqtt.Qos.fromBits(@intCast(opts & 0x03)) orelse return Error.InvalidQos;
        return .{
            .filter = filter,
            .qos = qos,
            .no_local = (opts & 0x04) != 0,
            .retain_as_published = (opts & 0x08) != 0,
        };
    }
};

pub fn parseSubscribe(body: []const u8, version: mqtt.ProtocolLevel) Error!SubscribeIterator {
    var r = Reader.init(body);
    const packet_id = try r.u16be();
    if (packet_id == 0) return Error.ProtocolViolation;
    if (version == .v5_0) _ = try readPropertyBlock(&r);
    return .{ .reader = r, .packet_id = packet_id, .version = version };
}

/// PUBACK / PUBREC / PUBREL / PUBCOMP body: a 2-byte packet id, optionally
/// followed (v5) by a reason code and a property block, both of which we accept
/// but do not need here.
pub fn parsePacketId(body: []const u8) Error!u16 {
    var r = Reader.init(body);
    const pid = try r.u16be();
    if (pid == 0) return Error.ProtocolViolation;
    return pid;
}

/// Read the v5 property block: a varint byte-count followed by that many bytes.
/// We validate the framing (so a lie about the length is caught here) and skip
/// the contents; individual property interpretation lives in higher layers.
fn readPropertyBlock(r: *Reader) Error!u32 {
    const head = r.buf[r.pos..];
    const dec = varint.decode(head) catch |e| switch (e) {
        varint.DecodeError.Incomplete => return Error.Truncated,
        varint.DecodeError.Overlong => return Error.MalformedFixedHeader,
    };
    try r.skip(dec.len);
    if (dec.value > limits.max_packet_len) return Error.PacketTooLarge;
    try r.skip(dec.value);
    return dec.value;
}

test "splitFrame asks for more data on a partial packet" {
    // CONNECT header claims 12 body bytes; supply 3.
    const partial = [_]u8{ 0x10, 0x0C, 0x00, 0x04, 'M' };
    try std.testing.expectError(Error.NeedMoreData, splitFrame(&partial));
}

test "splitFrame rejects a reserved packet type" {
    try std.testing.expectError(Error.ReservedPacketType, splitFrame(&[_]u8{ 0x00, 0x00 }));
}

test "parseConnect reads a minimal v3.1.1 CONNECT" {
    // MQTT / level 4 / flags 0x02 (clean) / keepalive 60 / client-id "cid"
    const body = [_]u8{
        0x00, 0x04, 'M',  'Q',  'T',  'T',
        0x04, 0x02, 0x00, 0x3C, 0x00, 0x03,
        'c',  'i',  'd',
    };
    const c = try parseConnect(&body);
    try std.testing.expectEqual(mqtt.ProtocolLevel.v3_1_1, c.protocol);
    try std.testing.expect(c.flags.clean_start);
    try std.testing.expectEqual(@as(u16, 60), c.keep_alive);
    try std.testing.expectEqualStrings("cid", c.client_id);
}
