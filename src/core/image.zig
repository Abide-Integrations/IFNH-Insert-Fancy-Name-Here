//! Image attachments for user turns (ACTIVE_PLAN E-01c).
//!
//! One loader shared by `ifnh ask --image` and the REPL `/image`: it maps the
//! file extension to a media type, enforces the size cap, and base64-encodes
//! the bytes into the neutral `ImagePart`. Failures are returned as a
//! message (without the `error: ` prefix) for the driver to print.

const std = @import("std");
const core_types = @import("types.zig");

/// Largest accepted file.
pub const max_bytes: u64 = 5 * 1024 * 1024;
/// Most images one turn may carry.
pub const max_per_turn: usize = 8;

pub const Loaded = union(enum) {
    ok: core_types.ImagePart,
    /// Human-readable failure, arena-owned.
    err: []const u8,
};

const supported = "png, jpg, gif, webp";

/// Media type for the extension of `path` (case-insensitive), or null.
pub fn mediaTypeFor(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { ext: []const u8, media: []const u8 }{
        .{ .ext = ".png", .media = "image/png" },
        .{ .ext = ".jpg", .media = "image/jpeg" },
        .{ .ext = ".jpeg", .media = "image/jpeg" },
        .{ .ext = ".gif", .media = "image/gif" },
        .{ .ext = ".webp", .media = "image/webp" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.media;
    }
    return null;
}

/// Read `path` (relative to `dir`) and encode it. The type is checked before
/// the file is opened, the size before it is read.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Loaded {
    const media_type = mediaTypeFor(path) orelse return .{ .err = try std.fmt.allocPrint(
        arena,
        "unsupported image type '{s}' ({s})",
        .{ std.fs.path.extension(path), supported },
    ) };
    const file = dir.openFile(io, path, .{}) catch |err| return .{ .err = try readError(arena, path, err) };
    defer file.close(io);
    const st = file.stat(io) catch |err| return .{ .err = try readError(arena, path, err) };
    if (st.kind == .directory) return .{ .err = try std.fmt.allocPrint(arena, "cannot read image '{s}': is a directory", .{path}) };
    if (st.size > max_bytes) return .{ .err = try std.fmt.allocPrint(
        arena,
        "image too large: {s} ({d} bytes > {d})",
        .{ path, st.size, max_bytes },
    ) };

    const raw = try arena.alloc(u8, @intCast(st.size));
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const got = reader.interface.readSliceShort(raw) catch |err| return .{ .err = try readError(arena, path, err) };

    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(got));
    return .{ .ok = .{ .media_type = media_type, .data_base64 = encoder.encode(out, raw[0..got]) } };
}

fn readError(arena: std.mem.Allocator, path: []const u8, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(arena, "cannot read image '{s}': {s}", .{ path, @errorName(err) });
}

/// Images queued by the REPL for the next user turn, in the order added.
pub const Queue = struct {
    items: std.ArrayListUnmanaged(core_types.ImagePart) = .empty,

    /// False when the turn already carries `max_per_turn` images.
    pub fn add(self: *Queue, arena: std.mem.Allocator, part: core_types.ImagePart) !bool {
        if (self.items.items.len >= max_per_turn) return false;
        try self.items.append(arena, part);
        return true;
    }

    /// The queued images; the queue is empty afterwards. The slice stays
    /// valid (arena-owned) after `take` empties the queue.
    pub fn take(self: *Queue) []const core_types.ImagePart {
        const out = self.items.items;
        self.items = .empty;
        return out;
    }

    pub fn clear(self: *Queue) void {
        self.items.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------- tests

/// 1x1 transparent PNG, base64.
const tiny_png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

fn tinyPng(arena: std.mem.Allocator) ![]u8 {
    const out = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(tiny_png_b64));
    try std.base64.standard.Decoder.decode(out, tiny_png_b64);
    return out;
}

test "media type follows the extension, case-insensitively" {
    try std.testing.expectEqualStrings("image/png", mediaTypeFor("a.png").?);
    try std.testing.expectEqualStrings("image/png", mediaTypeFor("dir/A.PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", mediaTypeFor("a.jpg").?);
    try std.testing.expectEqualStrings("image/jpeg", mediaTypeFor("a.jpeg").?);
    try std.testing.expectEqualStrings("image/gif", mediaTypeFor("a.gif").?);
    try std.testing.expectEqualStrings("image/webp", mediaTypeFor("a.webp").?);
    try std.testing.expect(mediaTypeFor("a.bmp") == null);
    try std.testing.expect(mediaTypeFor("png") == null);
}

test "load encodes a file as unbroken base64" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const png = try tinyPng(arena);
    try tmp.dir.writeFile(io, .{ .sub_path = "pic.png", .data = png });
    const got = try load(arena, io, tmp.dir, "pic.png");
    try std.testing.expectEqualStrings("image/png", got.ok.media_type);
    try std.testing.expect(std.mem.indexOfAny(u8, got.ok.data_base64, "\r\n ") == null);

    const decoded = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(got.ok.data_base64));
    try std.base64.standard.Decoder.decode(decoded, got.ok.data_base64);
    try std.testing.expectEqualSlices(u8, png, decoded);
    try std.testing.expectEqualStrings(tiny_png_b64, got.ok.data_base64);
}

test "load rejects unsupported types, oversize files and missing files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "pic.bmp", .data = "x" });
    const bmp = try load(arena, io, tmp.dir, "pic.bmp");
    try std.testing.expectEqualStrings("unsupported image type '.bmp' (png, jpg, gif, webp)", bmp.err);

    const big = try arena.alloc(u8, max_bytes + 1);
    @memset(big, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.png", .data = big });
    const too_big = try load(arena, io, tmp.dir, "big.png");
    try std.testing.expectEqualStrings("image too large: big.png (5242881 bytes > 5242880)", too_big.err);

    // Exactly at the cap is accepted.
    try tmp.dir.writeFile(io, .{ .sub_path = "edge.png", .data = big[0..max_bytes] });
    try std.testing.expect((try load(arena, io, tmp.dir, "edge.png")) == .ok);

    const missing = try load(arena, io, tmp.dir, "nope.png");
    try std.testing.expect(std.mem.startsWith(u8, missing.err, "cannot read image 'nope.png': "));
}

test "queue keeps order, drains on take and caps at max_per_turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var q = Queue{};
    try std.testing.expect(try q.add(arena, .{ .media_type = "image/png", .data_base64 = "a" }));
    try std.testing.expect(try q.add(arena, .{ .media_type = "image/gif", .data_base64 = "b" }));
    const taken = q.take();
    try std.testing.expectEqual(@as(usize, 2), taken.len);
    try std.testing.expectEqualStrings("a", taken[0].data_base64);
    try std.testing.expectEqualStrings("b", taken[1].data_base64);
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);

    for (0..max_per_turn) |_| try std.testing.expect(try q.add(arena, .{ .media_type = "image/png", .data_base64 = "x" }));
    try std.testing.expect(!(try q.add(arena, .{ .media_type = "image/png", .data_base64 = "y" })));
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);
}
