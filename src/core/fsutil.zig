//! Filesystem utilities: atomic durable writes, path checks.
//!
//! Durability semantics (DECISIONS U282): write temp file in the target
//! directory, fsync the file, rename over the destination. Rename is atomic
//! on POSIX. Directory fsync is a hardening TODO tracked in the master
//! tracker (M0-T02 follow-up).

const std = @import("std");

/// Atomically replace `sub_path` inside `dir` with `data`.
/// The destination is never observed partially written.
pub fn atomicWriteFile(
    dir: std.Io.Dir,
    io: std.Io,
    alloc: std.mem.Allocator,
    sub_path: []const u8,
    data: []const u8,
) !void {
    return atomicWriteFilePerm(dir, io, alloc, sub_path, data, .default_file);
}

/// `atomicWriteFile` with explicit permissions on the temp file, so a private
/// file (0600) is never observable with wider access.
pub fn atomicWriteFilePerm(
    dir: std.Io.Dir,
    io: std.Io,
    alloc: std.mem.Allocator,
    sub_path: []const u8,
    data: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    var name_buf: [64]u8 = undefined;
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const suffix = std.fmt.bufPrint(&name_buf, ".ifnh-tmp-{x}", .{std.mem.readInt(u64, &rand_bytes, .little)}) catch unreachable;
    const tmp_path = try std.mem.concat(alloc, u8, &.{ sub_path, suffix });
    defer alloc.free(tmp_path);

    const file = try dir.createFile(io, tmp_path, .{ .truncate = true, .permissions = permissions });
    var closed = false;
    defer if (!closed) file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    file.close(io);
    closed = true;
    try dir.rename(tmp_path, dir, sub_path, io);
}

/// `2026-11-03T12:00:00Z` for `secs` since the Unix epoch, written into `buf`.
pub fn isoUtc(buf: *[20]u8, secs: u64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,             md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Current wall-clock time in seconds since the Unix epoch.
pub fn nowSecs(io: std.Io) u64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub fn fileExists(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

/// Read a file known to be small (configuration, markdown).
/// `max_bytes` guards against unbounded reads (error.TooLarge or StreamTooLong).
pub fn readSmallFile(
    dir: std.Io.Dir,
    io: std.Io,
    alloc: std.mem.Allocator,
    sub_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = try dir.statFile(io, sub_path, .{});
    if (stat.kind == .directory) return error.FileNotFound;
    if (stat.size > max_bytes) return error.TooLarge;
    return dir.readFileAlloc(io, sub_path, alloc, .limited(max_bytes));
}

/// mkdir -p relative to `dir`.
pub fn ensureDirPath(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) std.Io.Dir.CreateDirPathError!void {
    try dir.createDirPath(io, sub_path);
}

test "atomicWriteFile replaces destination atomically" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    try atomicWriteFile(tmp.dir, io, alloc, "state.json", "{\"a\":1}");
    const first = try readSmallFile(tmp.dir, io, alloc, "state.json", 1024);
    defer alloc.free(first);
    try std.testing.expectEqualStrings("{\"a\":1}", first);

    try atomicWriteFile(tmp.dir, io, alloc, "state.json", "{\"a\":2}");
    const second = try readSmallFile(tmp.dir, io, alloc, "state.json", 1024);
    defer alloc.free(second);
    try std.testing.expectEqualStrings("{\"a\":2}", second);

    try std.testing.expect(fileExists(tmp.dir, io, "state.json"));
    try std.testing.expect(!fileExists(tmp.dir, io, "missing.json"));
}

test "readSmallFile enforces size cap" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = "x" ** 64 });
    const ok = try readSmallFile(tmp.dir, io, alloc, "big.txt", 1024);
    defer alloc.free(ok);
    try std.testing.expectEqual(@as(usize, 64), ok.len);

    try std.testing.expectError(error.TooLarge, readSmallFile(tmp.dir, io, alloc, "big.txt", 8));
}

test "ensureDirPath creates nested directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    try ensureDirPath(tmp.dir, io, "a/b/c");
    try std.testing.expect(fileExists(tmp.dir, io, "a/b/c"));
    try ensureDirPath(tmp.dir, io, "a/b/c"); // idempotent
}

test "isoUtc formats epoch seconds" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", isoUtc(&buf, 0));
    try std.testing.expectEqualStrings("2026-11-03T12:34:56Z", isoUtc(&buf, 1793709296));
}
