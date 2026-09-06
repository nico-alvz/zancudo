//! Minimal MQTT control-packet encoder. Only the frames the broker emits are
//! here (CONNACK, SUBACK, PUBACK/PUBREC/PUBREL/PUBCOMP, PINGRESP, PUBLISH).
//! Every function writes into a caller-provided buffer and returns the written
//! slice — no allocation, no hidden growth.

const std = @import("std");
const mqtt = @import("mqtt.zig");
const varint = @import("varint.zig");

pub const Error = error{BufferTooSmall};

fn writeFixedHeader(out: []u8, t: mqtt.PacketType, flags: u4, remaining_len: u32) Error!usize {
    if (out.len < 1) return Error.BufferTooSmall;
    out[0] = (@as(u8, @intFromEnum(t)) << 4) | @as(u8, flags);
    var vbuf: [4]u8 = undefined;
    const vlen = varint.encode(remaining_len, &vbuf);
    if (out.len < 1 + vlen.len) return Error.BufferTooSmall;
    @memcpy(out[1 .. 1 + vlen.len], vlen);
    return 1 + vlen.len;
}

/// v3.1.1: [session_present byte][return code].
/// v5.0:   [session_present byte][reason code][properties length = 0].
pub fn connack(
    out: []u8,
    version: mqtt.ProtocolLevel,
    session_present: bool,
    reason: mqtt.ReasonCode,
) Error![]const u8 {
    const body_len: u32 = if (version == .v5_0) 3 else 2;
    const hdr = try writeFixedHeader(out, .connack, 0, body_len);
    if (out.len < hdr + body_len) return Error.BufferTooSmall;
    out[hdr] = if (session_present) 1 else 0;
    switch (version) {
        .v3_1_1 => out[hdr + 1] = reason.toV311Connack(),
        .v5_0 => {
            out[hdr + 1] = @intFromEnum(reason);
            out[hdr + 2] = 0; // no properties
        },
    }
    return out[0 .. hdr + body_len];
}

/// A short packet-id-only ack: PUBACK / PUBREC / PUBREL / PUBCOMP / UNSUBACK.
pub fn packetIdAck(out: []u8, t: mqtt.PacketType, packet_id: u16) Error![]const u8 {
    const flags: u4 = mqtt.requiredFlags(t);
    const hdr = try writeFixedHeader(out, t, flags, 2);
    if (out.len < hdr + 2) return Error.BufferTooSmall;
    std.mem.writeInt(u16, out[hdr..][0..2], packet_id, .big);
    return out[0 .. hdr + 2];
}

/// SUBACK: [packet id][granted qos per subscription...].
pub fn suback(out: []u8, packet_id: u16, granted: []const u8) Error![]const u8 {
    const body_len: u32 = @intCast(2 + granted.len);
    const hdr = try writeFixedHeader(out, .suback, 0, body_len);
    if (out.len < hdr + body_len) return Error.BufferTooSmall;
    std.mem.writeInt(u16, out[hdr..][0..2], packet_id, .big);
    @memcpy(out[hdr + 2 .. hdr + 2 + granted.len], granted);
    return out[0 .. hdr + body_len];
}

pub fn pingresp(out: []u8) Error![]const u8 {
    const hdr = try writeFixedHeader(out, .pingresp, 0, 0);
    return out[0..hdr];
}

/// PUBLISH for delivery to a subscriber. `packet_id` must be non-null iff qos>0.
pub fn publish(
    out: []u8,
    version: mqtt.ProtocolLevel,
    topic: []const u8,
    qos: mqtt.Qos,
    retain: bool,
    dup: bool,
    packet_id: ?u16,
    payload: []const u8,
) Error![]const u8 {
    const id_len: u32 = if (qos == .at_most_once) 0 else 2;
    const props_len: u32 = if (version == .v5_0) 1 else 0; // single 0 byte
    const body_len: u32 = @intCast(2 + topic.len + id_len + props_len + payload.len);

    const pf = mqtt.PublishFlags{
        .retain = retain,
        .qos = @intFromEnum(qos),
        .dup = dup,
    };
    const hdr = try writeFixedHeader(out, .publish, @bitCast(pf), body_len);
    if (out.len < hdr + body_len) return Error.BufferTooSmall;

    var p = hdr;
    std.mem.writeInt(u16, out[p..][0..2], @intCast(topic.len), .big);
    p += 2;
    @memcpy(out[p .. p + topic.len], topic);
    p += topic.len;
    if (qos != .at_most_once) {
        std.mem.writeInt(u16, out[p..][0..2], packet_id.?, .big);
        p += 2;
    }
    if (version == .v5_0) {
        out[p] = 0; // no properties
        p += 1;
    }
    @memcpy(out[p .. p + payload.len], payload);
    p += payload.len;
    return out[0..p];
}

test "connack encodes v3.1.1 and v5.0 shapes" {
    var buf: [8]u8 = undefined;
    const v3 = try connack(&buf, .v3_1_1, false, .success);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x02, 0x00, 0x00 }, v3);

    const v5 = try connack(&buf, .v5_0, true, .success);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x03, 0x01, 0x00, 0x00 }, v5);
}

test "publish round-trips through the decoder" {
    const decoder = @import("decoder.zig");
    var buf: [64]u8 = undefined;
    const frame = try publish(&buf, .v3_1_1, "a/b", .at_least_once, false, false, 7, "hi");
    const split = try decoder.splitFrame(frame);
    try std.testing.expectEqual(mqtt.PacketType.publish, split.packet_type);
    const pp = try decoder.parsePublish(split.flags, split.body, .v3_1_1);
    try std.testing.expectEqualStrings("a/b", pp.topic);
    try std.testing.expectEqual(@as(?u16, 7), pp.packet_id);
    try std.testing.expectEqualStrings("hi", pp.payload);
}
