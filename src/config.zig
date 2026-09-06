//! Broker configuration. Every field has a deterministic default; the CLI
//! parser only overrides. No config file format is imposed here.

const std = @import("std");
const limits = @import("security/limits.zig");

pub const Config = struct {
    listen_addr: []const u8 = "0.0.0.0",
    listen_port: u16 = 1883,
    /// Max simultaneous client connections (sizes the connection table).
    max_connections: u32 = 16_384,
    /// Grace period for a fresh TCP connection to send a valid CONNECT.
    connect_timeout_ms: i64 = 10_000,
    /// Reactor readiness batch size.
    max_events_per_poll: u32 = 1024,
    /// WAL file path and size.
    wal_path: []const u8 = "zancudo.wal",
    wal_capacity: usize = 64 * 1024 * 1024,
    /// Router hand-off queue depth (power of two).
    router_queue_capacity: usize = limits.router_queue_capacity,
    /// Enable the local-first mesh layer (single-node when false).
    mesh_enabled: bool = false,
    node_id: u64 = 1,

    pub fn fromArgs(args: []const [:0]const u8) !Config {
        var cfg = Config{};
        var i: usize = 1; // skip argv[0]
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--bind")) {
                cfg.listen_addr = try nextValue(args, &i);
            } else if (std.mem.eql(u8, a, "--port")) {
                cfg.listen_port = try std.fmt.parseInt(u16, try nextValue(args, &i), 10);
            } else if (std.mem.eql(u8, a, "--max-connections")) {
                cfg.max_connections = try std.fmt.parseInt(u32, try nextValue(args, &i), 10);
            } else if (std.mem.eql(u8, a, "--wal")) {
                cfg.wal_path = try nextValue(args, &i);
            } else if (std.mem.eql(u8, a, "--mesh")) {
                cfg.mesh_enabled = true;
            } else if (std.mem.eql(u8, a, "--node-id")) {
                cfg.node_id = try std.fmt.parseInt(u64, try nextValue(args, &i), 10);
            } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                return error.HelpRequested;
            } else {
                return error.UnknownArgument;
            }
        }
        std.debug.assert(std.math.isPowerOfTwo(cfg.router_queue_capacity));
        return cfg;
    }

    fn nextValue(args: []const [:0]const u8, i: *usize) ![]const u8 {
        if (i.* + 1 >= args.len) return error.MissingValue;
        i.* += 1;
        return args[i.*];
    }

    pub const usage =
        \\zancudo - ultra-high-performance MQTT broker (v3.1.1 + v5.0)
        \\
        \\Usage: zancudo [options]
        \\  --bind <addr>              listen address (default 0.0.0.0)
        \\  --port <port>              listen port (default 1883)
        \\  --max-connections <n>      connection table size (default 16384)
        \\  --wal <path>              write-ahead log file (default zancudo.wal)
        \\  --mesh                     enable the local-first mesh layer
        \\  --node-id <n>             this node's id in the mesh
        \\  -h, --help                show this help
        \\
    ;
};

test "arg parser overrides defaults" {
    const args = [_][:0]const u8{ "zancudo", "--port", "8883", "--mesh" };
    const cfg = try Config.fromArgs(&args);
    try std.testing.expectEqual(@as(u16, 8883), cfg.listen_port);
    try std.testing.expect(cfg.mesh_enabled);
}
