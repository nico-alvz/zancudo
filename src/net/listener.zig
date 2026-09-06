//! Non-blocking TCP listener setup. Kept separate so the socket options that
//! matter for a high-connection-rate broker live in one auditable place.

const std = @import("std");
const posix = std.posix;

pub const Listener = struct {
    fd: posix.fd_t,
    addr: std.net.Address,

    pub fn bind(addr_str: []const u8, port: u16) !Listener {
        const addr = try std.net.Address.parseIp(addr_str, port);

        const fd = try posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);

        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        // REUSEPORT lets multiple acceptor threads share the same port with the
        // kernel spreading new connections across them.
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};

        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 1024);

        return .{ .fd = fd, .addr = addr };
    }

    pub fn close(self: *Listener) void {
        posix.close(self.fd);
        self.* = undefined;
    }

    pub const Accepted = struct { fd: posix.fd_t, peer: std.net.Address };

    /// Accept one pending connection, or null if the backlog is momentarily
    /// empty (`EAGAIN`). The returned fd is already non-blocking.
    pub fn accept(self: *Listener) !?Accepted {
        var peer: std.net.Address = undefined;
        var len: posix.socklen_t = @sizeOf(std.net.Address);
        const cfd = posix.accept(self.fd, &peer.any, &len, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |e| switch (e) {
            error.WouldBlock => return null,
            error.ConnectionAborted, error.ConnectionResetByPeer => return null,
            else => return e,
        };
        // TCP_NODELAY: MQTT control packets are small and latency-sensitive.
        posix.setsockopt(cfd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        return .{ .fd = cfd, .peer = peer };
    }
};
