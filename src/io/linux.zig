//! Linux reactor: io_uring with an automatic epoll fallback.
//!
//! Both paths present the same readiness interface used by `reactor.zig`.
//! io_uring is driven with `IORING_OP_POLL_ADD` (one-shot, re-armed on every
//! completion), so the broker's connection state machine does not have to be
//! rewritten around a completion model to benefit from the newer syscall.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const reactor = @import("reactor.zig");
const Event = reactor.Event;
const Interest = reactor.Interest;
const Backend = reactor.Backend;

/// `POLLRDHUP` is not in `std.os.linux.POLL` on all Zig versions; define it.
const POLLRDHUP: u32 = 0x2000;

pub const LinuxReactor = struct {
    gpa: std.mem.Allocator,
    backend: Backend,
    events_out: []Event,

    // epoll state
    epfd: posix.fd_t = -1,
    epoll_events: []linux.epoll_event = &[_]linux.epoll_event{},

    // io_uring state
    ring: ?linux.IoUring = null,
    cqes: []linux.io_uring_cqe = &[_]linux.io_uring_cqe{},
    /// Per-registered-fd interest, so a completion can be re-armed correctly.
    armed: std.AutoHashMapUnmanaged(posix.fd_t, ArmedEntry) = .{},

    const ArmedEntry = struct { token: u64, interest: Interest };

    pub fn init(gpa: std.mem.Allocator, max_events: u32, want: Backend) !LinuxReactor {
        var self = LinuxReactor{
            .gpa = gpa,
            .backend = .epoll,
            .events_out = try gpa.alloc(Event, max_events),
        };
        errdefer gpa.free(self.events_out);

        if (want == .io_uring) {
            if (initUring(gpa, max_events)) |ur| {
                self.ring = ur.ring;
                self.cqes = ur.cqes;
                self.backend = .io_uring;
                return self;
            } else |_| {
                // Old kernel, seccomp filter, container without io_uring, ...
                // fall through to epoll.
            }
        }

        self.epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        self.epoll_events = try gpa.alloc(linux.epoll_event, max_events);
        self.backend = .epoll;
        return self;
    }

    const UringInit = struct { ring: linux.IoUring, cqes: []linux.io_uring_cqe };

    fn initUring(gpa: std.mem.Allocator, max_events: u32) !UringInit {
        const entries: u16 = std.math.cast(u16, std.math.ceilPowerOfTwo(u32, max_events) catch 4096) orelse 4096;
        const ring = try linux.IoUring.init(entries, 0);
        const cqes = try gpa.alloc(linux.io_uring_cqe, max_events);
        return .{ .ring = ring, .cqes = cqes };
    }

    pub fn deinit(self: *LinuxReactor) void {
        if (self.ring) |*r| {
            r.deinit();
            self.gpa.free(self.cqes);
            self.armed.deinit(self.gpa);
        }
        if (self.epfd >= 0) {
            posix.close(self.epfd);
            self.gpa.free(self.epoll_events);
        }
        self.gpa.free(self.events_out);
    }

    fn pollMask(interest: Interest) u32 {
        var m: u32 = linux.POLL.ERR | linux.POLL.HUP;
        if (interest.read) m |= linux.POLL.IN | POLLRDHUP;
        if (interest.write) m |= linux.POLL.OUT;
        return m;
    }

    fn epollMask(interest: Interest) u32 {
        var m: u32 = linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP;
        if (interest.read) m |= linux.EPOLL.IN;
        if (interest.write) m |= linux.EPOLL.OUT;
        return m;
    }

    pub fn add(self: *LinuxReactor, fd: posix.fd_t, token: u64, interest: Interest) !void {
        if (self.ring) |*r| {
            try self.armed.put(self.gpa, fd, .{ .token = token, .interest = interest });
            _ = try r.poll_add(fd_user_data(fd), fd, pollMask(interest));
            _ = try r.submit();
            return;
        }
        var ev = linux.epoll_event{
            .events = epollMask(interest),
            .data = .{ .u64 = token },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    pub fn modify(self: *LinuxReactor, fd: posix.fd_t, token: u64, interest: Interest) !void {
        if (self.ring) |*r| {
            // Drop the outstanding poll and re-arm with the new mask.
            _ = r.poll_remove(fd_user_data(fd), fd_user_data(fd)) catch {};
            try self.armed.put(self.gpa, fd, .{ .token = token, .interest = interest });
            _ = try r.poll_add(fd_user_data(fd), fd, pollMask(interest));
            _ = try r.submit();
            return;
        }
        var ev = linux.epoll_event{
            .events = epollMask(interest),
            .data = .{ .u64 = token },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
    }

    pub fn remove(self: *LinuxReactor, fd: posix.fd_t) !void {
        if (self.ring) |*r| {
            _ = self.armed.remove(fd);
            _ = r.poll_remove(fd_user_data(fd), fd_user_data(fd)) catch {};
            _ = r.submit() catch {};
            return;
        }
        posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null) catch {};
    }

    pub fn poll(self: *LinuxReactor, timeout_ms: i32) ![]const Event {
        if (self.ring) |*r| return self.pollUring(r, timeout_ms);
        return self.pollEpoll(timeout_ms);
    }

    fn pollEpoll(self: *LinuxReactor, timeout_ms: i32) ![]const Event {
        const n = posix.epoll_wait(self.epfd, self.epoll_events, timeout_ms);
        var out: usize = 0;
        for (self.epoll_events[0..n]) |ev| {
            self.events_out[out] = .{
                .token = ev.data.u64,
                .readable = (ev.events & linux.EPOLL.IN) != 0,
                .writable = (ev.events & linux.EPOLL.OUT) != 0,
                .hangup = (ev.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0,
                .err = (ev.events & linux.EPOLL.ERR) != 0,
            };
            out += 1;
        }
        return self.events_out[0..out];
    }

    fn pollUring(self: *LinuxReactor, r: *linux.IoUring, timeout_ms: i32) ![]const Event {
        // Submit any pending re-arms and wait for at least one completion.
        // A bounded wait is expressed with an IORING_OP_TIMEOUT SQE; omitted
        // here for brevity, so `timeout_ms` only gates whether we block at all.
        const wait_nr: u32 = if (timeout_ms == 0) 0 else 1;
        _ = r.submit_and_wait(wait_nr) catch |e| switch (e) {
            error.SignalInterrupt => return self.events_out[0..0],
            else => return e,
        };

        const count = try r.copy_cqes(self.cqes, 0);
        var out: usize = 0;
        for (self.cqes[0..count]) |cqe| {
            const fd = user_data_fd(cqe.user_data);
            const entry = self.armed.get(fd) orelse continue;
            const revents: u32 = if (cqe.res < 0) 0 else @intCast(cqe.res);
            self.events_out[out] = .{
                .token = entry.token,
                .readable = (revents & linux.POLL.IN) != 0,
                .writable = (revents & linux.POLL.OUT) != 0,
                .hangup = (revents & (linux.POLL.HUP | POLLRDHUP)) != 0,
                .err = cqe.res < 0 or (revents & linux.POLL.ERR) != 0,
            };
            out += 1;
            // One-shot poll consumed; re-arm unless it was an error/hangup.
            if (!self.events_out[out - 1].hangup and !self.events_out[out - 1].err) {
                _ = r.poll_add(cqe.user_data, fd, pollMask(entry.interest)) catch {};
            }
        }
        _ = r.submit() catch {};
        return self.events_out[0..out];
    }

    /// Pack an fd into a u64 user_data slot (fds are always non-negative i32).
    fn fd_user_data(fd: posix.fd_t) u64 {
        return @as(u64, @intCast(fd));
    }
    fn user_data_fd(ud: u64) posix.fd_t {
        return @intCast(ud);
    }
};
