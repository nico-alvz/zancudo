//! MQTT wire-protocol constants for v3.1.1 (OASIS 3.1.1) and v5.0.
//!
//! Everything here is `comptime`-friendly: the enums, the fixed-header masks and
//! the property-id table are all resolved at compile time, so the hot-path
//! decoder branches on real integer literals with zero runtime lookup tables.

const std = @import("std");

/// Protocol level byte carried in the CONNECT variable header.
pub const ProtocolLevel = enum(u8) {
    v3_1_1 = 4,
    v5_0 = 5,

    pub fn fromByte(b: u8) ?ProtocolLevel {
        return switch (b) {
            4 => .v3_1_1,
            5 => .v5_0,
            else => null,
        };
    }
};

/// The 16 MQTT control-packet types occupy the high nibble of byte 0.
pub const PacketType = enum(u4) {
    reserved0 = 0,
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
    auth = 15, // v5.0 only

    pub fn fromNibble(n: u4) PacketType {
        return @enumFromInt(n);
    }
};

/// Quality-of-Service level. Wire value is 2 bits; `3` is a protocol error.
pub const Qos = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,

    pub fn fromBits(bits: u2) ?Qos {
        return if (bits == 3) null else @enumFromInt(bits);
    }
};

/// Low-nibble flag layout of the fixed header, meaningful only for PUBLISH.
pub const PublishFlags = packed struct(u4) {
    retain: bool,
    qos: u2,
    dup: bool,

    pub fn decode(nibble: u4) PublishFlags {
        return @bitCast(nibble);
    }
};

/// Fixed-header low nibble that the spec mandates for every non-PUBLISH packet.
/// PUBREL, SUBSCRIBE and UNSUBSCRIBE must carry 0b0010; all others 0b0000.
pub fn requiredFlags(t: PacketType) u4 {
    return switch (t) {
        .pubrel, .subscribe, .unsubscribe => 0b0010,
        else => 0b0000,
    };
}

/// CONNECT variable-header flag byte.
pub const ConnectFlags = packed struct(u8) {
    reserved: bool, // must be 0
    clean_start: bool,
    will_flag: bool,
    will_qos: u2,
    will_retain: bool,
    password_flag: bool,
    username_flag: bool,

    pub fn decode(b: u8) ConnectFlags {
        return @bitCast(b);
    }
};

/// Reason / return codes. v3.1.1 defines a small CONNACK set (0..5); v5.0 shares
/// value 0 for success and adds a wide 0x80+ error range. Only the codes the
/// broker actually emits are listed here.
pub const ReasonCode = enum(u8) {
    success = 0x00, // also "normal disconnection" / "granted QoS 0"
    granted_qos1 = 0x01,
    granted_qos2 = 0x02,
    disconnect_with_will = 0x04,
    no_matching_subscribers = 0x10,
    unspecified_error = 0x80,
    malformed_packet = 0x81,
    protocol_error = 0x82,
    implementation_specific_error = 0x83,
    unsupported_protocol_version = 0x84,
    client_identifier_not_valid = 0x85,
    bad_user_name_or_password = 0x86,
    not_authorized = 0x87,
    server_unavailable = 0x88,
    server_busy = 0x89,
    bad_authentication_method = 0x8C,
    topic_filter_invalid = 0x8F,
    topic_name_invalid = 0x90,
    packet_identifier_in_use = 0x91,
    packet_too_large = 0x95,
    quota_exceeded = 0x97,
    payload_format_invalid = 0x99,
    retain_not_supported = 0x9A,
    qos_not_supported = 0x9B,

    /// Collapse a v5 reason code onto the single byte a v3.1.1 CONNACK allows.
    pub fn toV311Connack(self: ReasonCode) u8 {
        return switch (self) {
            .success => 0,
            .unsupported_protocol_version => 1,
            .client_identifier_not_valid => 2,
            .server_unavailable, .server_busy => 3,
            .bad_user_name_or_password => 4,
            .not_authorized => 5,
            else => 3,
        };
    }
};

/// MQTT v5.0 property identifiers (variable-header / payload metadata).
/// Grouped by the packets they may appear in; the decoder validates placement.
pub const PropertyId = enum(u8) {
    payload_format_indicator = 0x01,
    message_expiry_interval = 0x02,
    content_type = 0x03,
    response_topic = 0x08,
    correlation_data = 0x09,
    subscription_identifier = 0x0B,
    session_expiry_interval = 0x11,
    assigned_client_identifier = 0x12,
    server_keep_alive = 0x13,
    authentication_method = 0x15,
    authentication_data = 0x16,
    request_problem_information = 0x17,
    will_delay_interval = 0x18,
    request_response_information = 0x19,
    response_information = 0x1A,
    server_reference = 0x1C,
    reason_string = 0x1F,
    receive_maximum = 0x21,
    topic_alias_maximum = 0x22,
    topic_alias = 0x23,
    maximum_qos = 0x24,
    retain_available = 0x25,
    user_property = 0x26,
    maximum_packet_size = 0x27,
    wildcard_subscription_available = 0x28,
    subscription_identifier_available = 0x29,
    shared_subscription_available = 0x2A,

    pub fn fromByte(b: u8) ?PropertyId {
        return std.meta.intToEnum(PropertyId, b) catch null;
    }
};

/// Topic-level wildcards. These are the only two bytes with structural meaning
/// inside a subscription filter.
pub const level_separator: u8 = '/';
pub const single_level_wildcard: u8 = '+';
pub const multi_level_wildcard: u8 = '#';

/// `$SYS/...` and friends are reserved; a plain `#` subscription must not match
/// them. Callers check the first byte against this.
pub const reserved_prefix: u8 = '$';

comptime {
    // The nibble/enum mapping must be exact, or `fromNibble` silently lies.
    std.debug.assert(@intFromEnum(PacketType.connect) == 1);
    std.debug.assert(@intFromEnum(PacketType.auth) == 15);
    std.debug.assert(@bitSizeOf(ConnectFlags) == 8);
    std.debug.assert(@bitSizeOf(PublishFlags) == 4);
}
