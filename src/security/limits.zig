//! Hard, compile-time limits used everywhere a network-controlled length is
//! parsed. Every one of these is enforced by the decoder before a single byte
//! is copied, so a hostile peer cannot steer an allocation or an index past a
//! known ceiling. Keeping them in one file makes the trusted surface auditable.

const std = @import("std");

/// MQTT control-packet fixed header allows a 4-byte "remaining length" varint,
/// which tops out at 268_435_455. We cap well below that: a broker that must
/// stay predictable has no business buffering a quarter-gigabyte frame.
pub const max_packet_len: u32 = 1 * 1024 * 1024;

/// Upper bound for the "remaining length" varint itself (4 continuation bytes).
pub const max_remaining_length_bytes: u8 = 4;

/// MQTT string is a u16-prefixed UTF-8 blob; the protocol ceiling is 65_535.
pub const max_string_len: u16 = std.math.maxInt(u16);

/// Longest topic name / filter we will index in the radix tree.
pub const max_topic_len: u16 = 4096;

/// Longest client identifier we accept. Spec minimum is 23; we allow more but
/// bound it so the session table entry stays a fixed size.
pub const max_client_id_len: u16 = 128;

/// Maximum number of topic levels ("a/b/c" -> 3). Bounds recursion and the
/// per-parse level cursor stack.
pub const max_topic_levels: u16 = 128;

/// Per-session arena reservation. The whole arena is released in one call when
/// the connection drops, so this is the maximum a misbehaving client can pin.
pub const session_arena_reserve: usize = 256 * 1024;

/// Bytes of receive buffer held per connection while a frame is still partial.
pub const connection_read_buffer: usize = 64 * 1024;

/// Inflight QoS 1/2 messages a single session may have unacknowledged before we
/// stop delivering to it (back-pressure, not disconnect).
pub const max_inflight_per_session: u16 = 1024;

/// Cross-thread hand-off queue depth between a network worker and the router.
/// Power of two so the ring can mask instead of divide.
pub const router_queue_capacity: usize = 8192;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(router_queue_capacity));
    std.debug.assert(max_packet_len <= 268_435_455);
    std.debug.assert(max_remaining_length_bytes == 4);
}
