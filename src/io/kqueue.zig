//! BSD / macOS reactor built on kqueue. Compiled only on those targets
//! (`reactor.zig` selects it through a comptime OS switch), so nothing here is
//! analysed on a Linux build.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const reactor = @import("reactor.zig");
const Event = reactor.Event;
const Interest = reactor.Interest;
const Backend = reactor.Backend;

pub const KqueueReactor = struct {
    gpa: std.mem.Allocator,
    backend: Backend = .kqueue,
    kq: posix.fd_t,
    change_buf: std.ArrayListUnmanaged(posix.Kevent) = .{},
    event_buf: []posix.Kevent,
    events_out: []Event,

    pub fn init(gpa: std.mem.Allocator, max_events: u32, want: Backend) !KqueueReactor {
        _ = want;
        return .{
            .gpa = gpa,
            .kq = try posix.kqueue(),
            .event_buf = try gpa.alloc(posix.Kevent, max_events),
            .events_out = try gpa.alloc(Event, max_events),
        };
    }

    pub fn deinit(self: *KqueueReactor) void {
        posix.close(self.kq);
        self.change_buf.deinit(self.gpa);
        self.gpa.free(self.event_buf);
        self.gpa.free(self.events_out);
    }

    fn queueChange(self: *KqueueReactor, fd: posix.fd_t, filter: i16, flags: u16, token: u64) !void {
        try self.change_buf.append(self.gpa, .{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(token),
        });
    }

    pub fn add(self: *KqueueReactor, fd: posix.fd_t, token: u64, interest: Interest) !void {
        if (interest.read) try self.queueChange(fd, c.EVFILT_READ, c.EV_ADD | c.EV_CLEAR, token);
        if (interest.write) try self.queueChange(fd, c.EVFILT_WRITE, c.EV_ADD | c.EV_CLEAR, token);
    }

    pub fn modify(self: *KqueueReactor, fd: posix.fd_t, token: u64, interest: Interest) !void {
        try self.queueChange(fd, c.EVFILT_READ, if (interest.read) c.EV_ADD | c.EV_CLEAR else c.EV_DELETE, token);
        try self.queueChange(fd, c.EVFILT_WRITE, if (interest.write) c.EV_ADD | c.EV_CLEAR else c.EV_DELETE, token);
    }

    pub fn remove(self: *KqueueReactor, fd: posix.fd_t) !void {
        try self.queueChange(fd, c.EVFILT_READ, c.EV_DELETE, 0);
        try self.queueChange(fd, c.EVFILT_WRITE, c.EV_DELETE, 0);
    }

    pub fn poll(self: *KqueueReactor, timeout_ms: i32) ![]const Event {
        var ts: posix.timespec = undefined;
        const ts_ptr: ?*const posix.timespec = if (timeout_ms < 0) null else blk: {
            ts = .{ .sec = @divFloor(timeout_ms, 1000), .nsec = @rem(timeout_ms, 1000) * std.time.ns_per_ms };
            break :blk &ts;
        };
        const n = try posix.kevent(self.kq, self.change_buf.items, self.event_buf, ts_ptr);
        self.change_buf.clearRetainingCapacity();

        var out: usize = 0;
        for (self.event_buf[0..n]) |ev| {
            const is_eof = (ev.flags & c.EV_EOF) != 0;
            self.events_out[out] = .{
                .token = @intCast(ev.udata),
                .readable = ev.filter == c.EVFILT_READ,
                .writable = ev.filter == c.EVFILT_WRITE,
                .hangup = is_eof,
                .err = (ev.flags & c.EV_ERROR) != 0,
            };
            out += 1;
        }
        return self.events_out[0..out];
    }
};
