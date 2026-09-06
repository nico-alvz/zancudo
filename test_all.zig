//! Aggregate test root (kept at the project root so it can import both `src/`
//! and `tests/`). `zig build test` compiles this; every module with `test`
//! blocks is pulled in so nothing escapes the suite.

const std = @import("std");

test {
    _ = @import("src/security/limits.zig");
    _ = @import("src/protocol/mqtt.zig");
    _ = @import("src/protocol/varint.zig");
    _ = @import("src/protocol/reader.zig");
    _ = @import("src/protocol/decoder.zig");
    _ = @import("src/protocol/encoder.zig");
    _ = @import("src/core/radix_tree.zig");
    _ = @import("src/core/lockfree.zig");
    _ = @import("src/core/session.zig");
    _ = @import("src/core/router.zig");
    _ = @import("src/persist/wal.zig");
    _ = @import("src/cluster/mesh.zig");
    _ = @import("src/config.zig");
    _ = @import("tests/radix_tree_test.zig");

    std.testing.refAllDeclsRecursive(@import("src/core/radix_tree.zig"));
    std.testing.refAllDeclsRecursive(@import("src/protocol/decoder.zig"));
    std.testing.refAllDeclsRecursive(@import("src/protocol/encoder.zig"));
}
