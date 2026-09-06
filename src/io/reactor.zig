//! Kernel-event-loop abstraction (the "reactor").
//!
//! One uniform readiness interface, three backends chosen at compile time:
//!   * Linux  -> io_uring when the kernel provides it, else epoll.
//!   * *BSD / macOS -> kqueue.
//!
//! The interface is deliberately a *readiness* model (`poll` returns which fds
//! can be read/written now) rather than a completion model, because it maps
//! cleanly onto epoll/kqueue and onto io_uring's `IORING_OP_POLL_ADD`, and it
//! keeps the connection state machine in one place (`net/connection.zig`)
//! instead of smeared across backend callbacks.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Interest = packed struct {
    read: bool = false,
    write: bool = false,
};

/// A ready fd. `token` is whatever u64 the caller registered (the broker uses
/// the connection slot index).
pub const Event = struct {
    token: u64,
    readable: bool = false,
    writable: bool = false,
    /// Peer closed or half-closed; drain then release.
    hangup: bool = false,
    /// Socket error; release without draining.
    err: bool = false,
};

pub const Backend = enum { io_uring, epoll, kqueue };

/// Compile-time backend selection, overridable with `-Dio-backend=`.
pub fn selected() Backend {
    const forced = build_options.io_backend;
    if (std.mem.eql(u8, forced, "io_uring")) return .io_uring;
    if (std.mem.eql(u8, forced, "epoll")) return .epoll;
    if (std.mem.eql(u8, forced, "kqueue")) return .kqueue;
    // auto
    return switch (builtin.os.tag) {
        .linux => .io_uring, // LinuxReactor falls back to epoll at runtime
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => .kqueue,
        else => @compileError("unsupported OS for the reactor"),
    };
}

const Impl = switch (builtin.os.tag) {
    .linux => @import("linux.zig").LinuxReactor,
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => @import("kqueue.zig").KqueueReactor,
    else => @compileError("unsupported OS for the reactor"),
};

pub const Reactor = struct {
    impl: Impl,

    pub fn init(gpa: std.mem.Allocator, max_events: u32) !Reactor {
        return .{ .impl = try Impl.init(gpa, max_events, selected()) };
    }

    pub fn deinit(self: *Reactor) void {
        self.impl.deinit();
    }

    pub fn add(self: *Reactor, fd: std.posix.fd_t, token: u64, interest: Interest) !void {
        return self.impl.add(fd, token, interest);
    }

    pub fn modify(self: *Reactor, fd: std.posix.fd_t, token: u64, interest: Interest) !void {
        return self.impl.modify(fd, token, interest);
    }

    pub fn remove(self: *Reactor, fd: std.posix.fd_t) !void {
        return self.impl.remove(fd);
    }

    /// Block up to `timeout_ms` (-1 = forever) and return the ready events.
    /// The returned slice is owned by the reactor and valid until the next call.
    pub fn poll(self: *Reactor, timeout_ms: i32) ![]const Event {
        return self.impl.poll(timeout_ms);
    }

    pub fn activeBackend(self: *const Reactor) Backend {
        return self.impl.backend;
    }
};
