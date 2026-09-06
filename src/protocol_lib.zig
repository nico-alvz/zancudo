//! Umbrella module for the MQTT protocol layer, so other build artifacts (the
//! fuzz harness, external tools) can depend on just the parser/serializer
//! without pulling in the reactor or the router.
//!
//! Kept in `src/` (not `src/protocol/`) so that, when used as a module root, it
//! still sees `security/limits.zig` inside the module path.

pub const mqtt = @import("protocol/mqtt.zig");
pub const varint = @import("protocol/varint.zig");
pub const reader = @import("protocol/reader.zig");
pub const decoder = @import("protocol/decoder.zig");
pub const encoder = @import("protocol/encoder.zig");
pub const limits = @import("security/limits.zig");
