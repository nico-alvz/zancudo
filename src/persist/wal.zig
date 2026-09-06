//! Write-Ahead Log: an append-only, mmap-backed record file used for retained
//! messages and for QoS 1/2 state of persistent sessions.
//!
//! Shape (inspired by the "small, boring, recoverable" persistence in Thread /
//! Matter stacks rather than a full embedded DB):
//!
//!   file = [ header ] [ record ]*
//!   header  = magic:u32 le | version:u16 | flags:u16 | write_offset:u64
//!   record  = len:u32 le | kind:u8 | crc32:u32 | payload:[len]u8
//!
//! The region is mapped `MAP_SHARED`; appends memcpy into the tail and bump
//! `write_offset` in the header. `sync()` issues `msync`. Recovery walks records
//! from the header offset backwards is unnecessary — we replay forward from the
//! first record and stop at the first bad CRC or at `write_offset`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const magic: u32 = 0x5A_57_41_4C; // "ZWAL"
pub const format_version: u16 = 1;
pub const header_size: usize = 16;

pub const RecordKind = enum(u8) {
    retained_set = 1, // topic + payload; empty payload clears the retained slot
    session_snapshot = 2, // serialized subscriptions for a persistent session
    inflight_publish = 3, // QoS 1/2 message awaiting completion
    inflight_release = 4, // matching completion marker
    _,
};

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    Full,
    Corrupt,
};

pub const Wal = struct {
    file: std.fs.File,
    region: []align(std.heap.page_size_min) u8,
    capacity: usize,

    pub fn open(path: []const u8, capacity: usize) !Wal {
        std.debug.assert(capacity > header_size);
        const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();

        const stat = try file.stat();
        const fresh = stat.size == 0;
        if (fresh) try file.setEndPos(capacity);

        const region = try posix.mmap(
            null,
            capacity,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer posix.munmap(region);

        const wal = Wal{ .file = file, .region = region, .capacity = capacity };
        if (fresh) {
            std.mem.writeInt(u32, region[0..4], magic, .little);
            std.mem.writeInt(u16, region[4..6], format_version, .little);
            std.mem.writeInt(u16, region[6..8], 0, .little);
            std.mem.writeInt(u64, region[8..16], header_size, .little);
        } else {
            if (std.mem.readInt(u32, region[0..4], .little) != magic) return Error.BadMagic;
            if (std.mem.readInt(u16, region[4..6], .little) != format_version) return Error.UnsupportedVersion;
        }
        return wal;
    }

    pub fn close(self: *Wal) void {
        self.sync() catch {};
        posix.munmap(self.region);
        self.file.close();
        self.* = undefined;
    }

    fn writeOffset(self: *const Wal) u64 {
        return std.mem.readInt(u64, self.region[8..16], .little);
    }
    fn setWriteOffset(self: *Wal, v: u64) void {
        std.mem.writeInt(u64, self.region[8..16], v, .little);
    }

    /// Append one record. Returns the byte offset the record was written at,
    /// which callers store as `payload_wal_offset` for later lookup.
    pub fn append(self: *Wal, kind: RecordKind, payload: []const u8) Error!u64 {
        const need = 4 + 1 + 4 + payload.len;
        const at = self.writeOffset();
        if (at + need > self.capacity) return Error.Full;

        var p = at;
        std.mem.writeInt(u32, self.region[p..][0..4], @intCast(payload.len), .little);
        p += 4;
        self.region[p] = @intFromEnum(kind);
        p += 1;
        const crc = std.hash.Crc32.hash(payload);
        std.mem.writeInt(u32, self.region[p..][0..4], crc, .little);
        p += 4;
        @memcpy(self.region[p .. p + payload.len], payload);
        p += payload.len;

        self.setWriteOffset(p);
        return at;
    }

    pub fn sync(self: *Wal) !void {
        try posix.msync(self.region, posix.MSF.SYNC);
    }

    pub const Record = struct { kind: RecordKind, offset: u64, payload: []const u8 };

    /// Forward iterator over committed records. Stops at `write_offset` or at
    /// the first record whose CRC does not verify (treated as end-of-log).
    pub const Iterator = struct {
        wal: *const Wal,
        pos: u64 = header_size,

        pub fn next(self: *Iterator) ?Record {
            const end = self.wal.writeOffset();
            if (self.pos + 9 > end) return null;
            const len = std.mem.readInt(u32, self.wal.region[self.pos..][0..4], .little);
            const kind: RecordKind = @enumFromInt(self.wal.region[self.pos + 4]);
            const crc = std.mem.readInt(u32, self.wal.region[self.pos + 5 ..][0..4], .little);
            const body_at = self.pos + 9;
            if (body_at + len > end) return null;
            const body = self.wal.region[body_at .. body_at + len];
            if (std.hash.Crc32.hash(body) != crc) return null;
            const rec = Record{ .kind = kind, .offset = self.pos, .payload = body };
            self.pos = body_at + len;
            return rec;
        }
    };

    pub fn iterator(self: *const Wal) Iterator {
        return .{ .wal = self };
    }
};

test "append then replay round-trips records and rejects tampering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&full_buf, "{s}/test.wal", .{path});

    var wal = try Wal.open(wal_path, 64 * 1024);
    const off_a = try wal.append(.retained_set, "hello");
    _ = try wal.append(.session_snapshot, "world!!");
    try std.testing.expectEqual(@as(u64, header_size), off_a);

    var it = wal.iterator();
    const r0 = it.next().?;
    try std.testing.expectEqual(RecordKind.retained_set, r0.kind);
    try std.testing.expectEqualStrings("hello", r0.payload);
    const r1 = it.next().?;
    try std.testing.expectEqualStrings("world!!", r1.payload);
    try std.testing.expect(it.next() == null);

    // Flip a payload byte -> the iterator must treat it as end-of-log.
    wal.region[header_size + 9] ^= 0xFF;
    var it2 = wal.iterator();
    try std.testing.expect(it2.next() == null);
    wal.close();
}
