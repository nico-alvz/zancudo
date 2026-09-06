//! Broker orchestration: the reactor loop, the connection table, and the
//! translation between decoded MQTT packets and router `Command`s.
//!
//! Threading model as shipped: one reactor thread that also drains the router
//! queue each iteration. The lock-free queue is still on the hot path, so
//! splitting the router onto its own core later is a scheduling change, not a
//! rewrite. `net_worker`-per-core with `SO_REUSEPORT` listeners is the intended
//! scale-out shape.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Config = @import("config.zig").Config;
const Listener = @import("net/listener.zig").Listener;
const Connection = @import("net/connection.zig").Connection;
const reactor_mod = @import("io/reactor.zig");
const Reactor = reactor_mod.Reactor;
const Interest = reactor_mod.Interest;
const mqtt = @import("protocol/mqtt.zig");
const decoder = @import("protocol/decoder.zig");
const encoder = @import("protocol/encoder.zig");
const router_mod = @import("core/router.zig");
const Router = router_mod.Router;
const CommandQueue = router_mod.CommandQueue;
const Session = @import("core/session.zig").Session;
const Wal = @import("persist/wal.zig").Wal;
const Mesh = @import("cluster/mesh.zig").Mesh;
const limits = @import("security/limits.zig");

const listener_token: u64 = std.math.maxInt(u64);

/// Build a router `publish` command from a decoded inbound PUBLISH. The topic
/// and payload slices alias the connection's receive buffer and stay valid
/// until the router drains the queue in the same reactor iteration.
fn fwd(from: u64, p: decoder.Publish) router_mod.PublishCmd {
    return .{
        .from = from,
        .topic = p.topic,
        .qos = p.qos,
        .retain = p.retain,
        .payload = p.payload,
    };
}

pub const Broker = struct {
    gpa: Allocator,
    cfg: Config,
    listener: Listener,
    reactor: Reactor,
    conns: []?*Connection,
    next_session_id: u64 = 1,

    queue: *CommandQueue,
    router: *Router,
    wal: ?*Wal,
    mesh: *Mesh,

    running: bool = true,

    pub fn init(gpa: Allocator, cfg: Config) !Broker {
        var listener = try Listener.bind(cfg.listen_addr, cfg.listen_port);
        errdefer listener.close();

        var reactor = try Reactor.init(gpa, cfg.max_events_per_poll);
        errdefer reactor.deinit();
        try reactor.add(listener.fd, listener_token, .{ .read = true });

        const conns = try gpa.alloc(?*Connection, cfg.max_connections);
        @memset(conns, null);
        errdefer gpa.free(conns);

        const mesh = try gpa.create(Mesh);
        mesh.* = Mesh.init(gpa, cfg.node_id);
        mesh.enabled = cfg.mesh_enabled;

        var wal: ?*Wal = null;
        if (cfg.wal_path.len > 0) {
            const w = try gpa.create(Wal);
            w.* = try Wal.open(cfg.wal_path, cfg.wal_capacity);
            wal = w;
        }

        const queue = try gpa.create(CommandQueue);
        queue.* = try CommandQueue.init(gpa, cfg.router_queue_capacity);

        const router = try gpa.create(Router);
        router.* = Router.init(gpa, queue, wal, mesh);

        return .{
            .gpa = gpa,
            .cfg = cfg,
            .listener = listener,
            .reactor = reactor,
            .conns = conns,
            .queue = queue,
            .router = router,
            .wal = wal,
            .mesh = mesh,
        };
    }

    pub fn deinit(self: *Broker) void {
        for (self.conns) |maybe| if (maybe) |c| {
            c.deinit(self.gpa);
            self.gpa.destroy(c);
        };
        self.gpa.free(self.conns);
        self.router.deinit();
        self.gpa.destroy(self.router);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self.queue);
        if (self.wal) |w| {
            w.close();
            self.gpa.destroy(w);
        }
        self.mesh.deinit();
        self.gpa.destroy(self.mesh);
        self.reactor.deinit();
        self.listener.close();
    }

    pub fn run(self: *Broker) !void {
        const log = std.log.scoped(.broker);
        log.info("listening on {s}:{d} via {s}", .{
            self.cfg.listen_addr,
            self.cfg.listen_port,
            @tagName(self.reactor.activeBackend()),
        });

        var delivery_sink = DeliverySink{ .broker = self };

        while (self.running) {
            const events = try self.reactor.poll(1000);
            for (events) |ev| {
                if (ev.token == listener_token) {
                    self.acceptBatch() catch |e| log.warn("accept: {s}", .{@errorName(e)});
                    continue;
                }
                const slot: u32 = @intCast(ev.token);
                const conn = self.conns[slot] orelse continue;
                if (ev.err) {
                    self.closeConn(slot);
                    continue;
                }
                if (ev.readable) self.onReadable(slot, conn) catch {
                    self.closeConn(slot);
                    continue;
                };
                if (ev.writable) _ = conn.flush() catch {
                    self.closeConn(slot);
                    continue;
                };
                if (ev.hangup and conn.tx.items.len == 0) self.closeConn(slot);
            }

            // Drain router work produced by this iteration's reads.
            _ = self.router.drain(self.router_sink(&delivery_sink), 4096);
            self.reapIdle();
        }
    }

    fn router_sink(self: *Broker, ds: *DeliverySink) Router.DeliverySink {
        _ = self;
        return .{ .ctx = ds, .emit = DeliverySink.emit };
    }

    const DeliverySink = struct {
        broker: *Broker,
        fn emit(ctx: *anyopaque, d: router_mod.Delivery) void {
            const self: *DeliverySink = @ptrCast(@alignCast(ctx));
            self.broker.writeDelivery(d);
        }
    };

    fn writeDelivery(self: *Broker, d: router_mod.Delivery) void {
        // Map session id -> connection slot. Small table; linear scan is fine
        // for the scaffold, a reverse index replaces it under load.
        for (self.conns) |maybe| {
            const c = maybe orelse continue;
            const sess = c.session_id orelse continue;
            if (sess != d.to) continue;

            var buf: [limits.max_packet_len]u8 = undefined;
            const frame = switch (d.kind) {
                .pubrel => encoder.packetIdAck(&buf, .pubrel, d.packet_id.?) catch return,
                .publish => encoder.publish(
                    &buf,
                    c.version,
                    d.topic,
                    d.qos,
                    d.retain,
                    false,
                    d.packet_id,
                    d.payload,
                ) catch return,
            };
            c.queueOut(frame) catch return;
            _ = c.flush() catch {};
            if (c.tx.items.len > 0)
                self.reactor.modify(c.fd, c.slot, .{ .read = true, .write = true }) catch {};
            return;
        }
    }

    fn acceptBatch(self: *Broker) !void {
        var accepted: usize = 0;
        while (accepted < 256) : (accepted += 1) {
            const a = (try self.listener.accept()) orelse break;
            const slot = self.freeSlot() orelse {
                posix.close(a.fd);
                continue;
            };
            const c = try self.gpa.create(Connection);
            c.* = try Connection.init(self.gpa, a.fd, slot, a.peer);
            self.conns[slot] = c;
            try self.reactor.add(a.fd, slot, .{ .read = true });
        }
    }

    fn onReadable(self: *Broker, slot: u32, conn: *Connection) !void {
        var buf: [limits.connection_read_buffer]u8 = undefined;
        while (true) {
            const n = posix.read(conn.fd, &buf) catch |e| switch (e) {
                error.WouldBlock => break,
                else => return e,
            };
            if (n == 0) return error.PeerClosed;
            try conn.ingest(buf[0..n]);

            while (try conn.nextFrame()) |frame| {
                try self.handleFrame(slot, conn, frame);
                conn.consume(frame.totalLen());
            }
        }
    }

    fn handleFrame(self: *Broker, slot: u32, conn: *Connection, frame: decoder.Frame) !void {
        var scratch: [512]u8 = undefined;
        switch (frame.packet_type) {
            .connect => {
                const c = try decoder.parseConnect(frame.body);
                conn.version = c.protocol;
                conn.keep_alive_s = c.keep_alive;
                conn.state = .established;

                const sess = try self.gpa.create(Session);
                const sid = self.next_session_id;
                self.next_session_id += 1;
                sess.* = try Session.init(self.gpa, sid, c.client_id, c.protocol, !c.flags.clean_start);
                sess.conn_slot = slot;
                conn.session_id = sid;
                _ = self.queue.tryPush(.{ .attach_session = .{ .session = sess } });

                const reply = try encoder.connack(&scratch, c.protocol, false, .success);
                try conn.queueOut(reply);
            },
            .publish => {
                const p = try decoder.parsePublish(frame.flags, frame.body, conn.version);
                const sid = conn.session_id orelse return error.ProtocolViolation;

                switch (p.qos) {
                    .at_most_once => {
                        _ = self.queue.tryPush(.{ .publish = fwd(sid, p) });
                    },
                    .at_least_once => {
                        _ = self.queue.tryPush(.{ .publish = fwd(sid, p) });
                        const ack = try encoder.packetIdAck(&scratch, .puback, p.packet_id.?);
                        try conn.queueOut(ack);
                    },
                    .exactly_once => {
                        // Deliver at most once even if the client retransmits
                        // the PUBLISH before its PUBREL: dedup on packet id.
                        const pid = p.packet_id.?;
                        const gop = try conn.qos2_rx.getOrPut(self.gpa, pid);
                        if (!gop.found_existing) {
                            _ = self.queue.tryPush(.{ .publish = fwd(sid, p) });
                        }
                        const ack = try encoder.packetIdAck(&scratch, .pubrec, pid);
                        try conn.queueOut(ack);
                    },
                }
            },
            .subscribe => {
                var it = try decoder.parseSubscribe(frame.body, conn.version);
                var granted: [64]u8 = undefined;
                var gi: usize = 0;
                while (try it.next()) |s| {
                    if (gi == granted.len) break;
                    if (conn.session_id) |sid| {
                        _ = self.queue.tryPush(.{ .subscribe = .{
                            .id = sid,
                            .filter = s.filter,
                            .qos = s.qos,
                            .no_local = s.no_local,
                        } });
                    }
                    granted[gi] = @intFromEnum(s.qos);
                    gi += 1;
                }
                const ack = try encoder.suback(&scratch, it.packet_id, granted[0..gi]);
                try conn.queueOut(ack);
            },
            .unsubscribe => {
                var r = @import("protocol/reader.zig").Reader.init(frame.body);
                const pid = try r.u16be();
                if (conn.version == .v5_0) _ = try r.mqttBinary(); // skip props (best-effort)
                while (!r.isAtEnd()) {
                    const filter = try r.mqttString();
                    if (conn.session_id) |sid|
                        _ = self.queue.tryPush(.{ .unsubscribe = .{ .id = sid, .filter = filter } });
                }
                const ack = try encoder.packetIdAck(&scratch, .unsuback, pid);
                try conn.queueOut(ack);
            },
            .pingreq => {
                const pong = try encoder.pingresp(&scratch);
                try conn.queueOut(pong);
            },
            .pubrel => {
                // QoS 2 step 3->4 for an inbound message: release the dedup
                // entry and confirm with PUBCOMP.
                const pid = try decoder.parsePacketId(frame.body);
                _ = conn.qos2_rx.remove(pid);
                const ack = try encoder.packetIdAck(&scratch, .pubcomp, pid);
                try conn.queueOut(ack);
            },
            .puback => {
                if (conn.session_id) |sid|
                    _ = self.queue.tryPush(.{ .pub_ack = .{ .id = sid, .packet_id = try decoder.parsePacketId(frame.body) } });
            },
            .pubrec => {
                if (conn.session_id) |sid|
                    _ = self.queue.tryPush(.{ .pub_rec = .{ .id = sid, .packet_id = try decoder.parsePacketId(frame.body) } });
            },
            .pubcomp => {
                if (conn.session_id) |sid|
                    _ = self.queue.tryPush(.{ .pub_comp = .{ .id = sid, .packet_id = try decoder.parsePacketId(frame.body) } });
            },
            .disconnect => {
                conn.state = .draining;
                if (conn.session_id) |sid|
                    _ = self.queue.tryPush(.{ .detach_session = .{ .id = sid, .clean = true } });
            },
            else => return error.ProtocolViolation,
        }

        _ = conn.flush() catch {};
        if (conn.tx.items.len > 0)
            try self.reactor.modify(conn.fd, slot, .{ .read = true, .write = true });
    }

    fn reapIdle(self: *Broker) void {
        const now = std.time.milliTimestamp();
        for (self.conns, 0..) |maybe, i| {
            const c = maybe orelse continue;
            const limit_ms: i64 = if (c.state == .awaiting_connect)
                self.cfg.connect_timeout_ms
            else if (c.keep_alive_s > 0)
                @as(i64, c.keep_alive_s) * 1500 // 1.5x keep-alive per spec
            else
                0;
            if (limit_ms > 0 and c.idleMillis(now) > limit_ms) self.closeConn(@intCast(i));
        }
    }

    fn closeConn(self: *Broker, slot: u32) void {
        const c = self.conns[slot] orelse return;
        if (c.session_id) |sid|
            _ = self.queue.tryPush(.{ .detach_session = .{ .id = sid, .clean = true } });
        self.reactor.remove(c.fd) catch {};
        posix.close(c.fd);
        c.deinit(self.gpa);
        self.gpa.destroy(c);
        self.conns[slot] = null;
    }

    fn freeSlot(self: *Broker) ?u32 {
        for (self.conns, 0..) |maybe, i| {
            if (maybe == null) return @intCast(i);
        }
        return null;
    }
};
