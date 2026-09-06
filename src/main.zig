//! Zancudo — an ultra-high-performance, strict-security MQTT broker in Zig.
//! Wire-compatible with MQTT v3.1.1 and v5.0.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const Broker = @import("broker.zig").Broker;

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

var global_broker: ?*Broker = null;

fn handleSignal(_: c_int) callconv(.c) void {
    if (global_broker) |b| b.running = false;
}

pub fn main() !void {
    // A general-purpose allocator with leak detection in Debug; the per-session
    // arenas sit on top of this. Nothing on the data path allocates from it
    // directly once a connection is established.
    var gpa_state = std.heap.GeneralPurposeAllocator(.{
        .safety = (builtin.mode == .Debug),
    }){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const cfg = Config.fromArgs(args) catch |e| switch (e) {
        error.HelpRequested => {
            try std.io.getStdOut().writeAll(Config.usage);
            return;
        },
        else => {
            try std.io.getStdErr().writer().print("argument error: {s}\n\n{s}", .{ @errorName(e), Config.usage });
            std.process.exit(2);
        },
    };

    var broker = try Broker.init(gpa, cfg);
    defer broker.deinit();
    global_broker = &broker;

    if (builtin.os.tag != .windows) {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        // Never let a dead peer's write kill the process.
        const ign = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.empty_sigset, .flags = 0 };
        std.posix.sigaction(std.posix.SIG.PIPE, &ign, null);
    }

    try broker.run();
    std.log.info("shutdown complete", .{});
}
