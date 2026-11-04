//! Skills lockfile (ACTIVE_PLAN E-05b, DECISIONS K156-158).
//!
//! `.ifnh/skills.lock.json` pins where each installed skill came from:
//!
//!     {"version":1,"skills":{"<name>":{"source":"<url>","ref":"<ref-or-empty>",
//!       "commit":"<40 hex>","installed_at":"<ISO-8601 UTC>"}}}
//!
//! The writer is deterministic: skill names sorted, fields in the order above,
//! 2-space indent, trailing newline, so the file diffs cleanly in review. The
//! reader tolerates unknown fields and keeps `version`. A file that is not
//! valid JSON or has the wrong shape is an error the caller must surface; it
//! is never silently replaced.

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const path = ".ifnh/skills.lock.json";
pub const current_version: i64 = 1;
const max_lock_bytes: usize = 1024 * 1024;

pub const Entry = struct {
    source: []const u8,
    /// Branch or tag given with `--ref`; "" for the remote's default branch.
    ref: []const u8 = "",
    /// Full 40-hex commit that was checked out.
    commit: []const u8,
    /// ISO-8601 UTC.
    installed_at: []const u8 = "",
};

pub const Named = struct { name: []const u8, entry: Entry };

pub const Error = error{InvalidLock};

/// `skills lockfile is not valid JSON: <path>`, for the caller to print.
pub const invalid_message = "skills lockfile is not valid JSON: " ++ path;

pub const Lock = struct {
    version: i64 = current_version,
    entries: std.ArrayListUnmanaged(Named) = .empty,

    pub fn get(self: *const Lock, name: []const u8) ?Entry {
        for (self.entries.items) |n| {
            if (std.mem.eql(u8, n.name, name)) return n.entry;
        }
        return null;
    }

    /// Add or replace `name`. Strings are copied into `arena`.
    pub fn put(self: *Lock, arena: std.mem.Allocator, name: []const u8, entry: Entry) !void {
        const owned = Named{ .name = try arena.dupe(u8, name), .entry = .{
            .source = try arena.dupe(u8, entry.source),
            .ref = try arena.dupe(u8, entry.ref),
            .commit = try arena.dupe(u8, entry.commit),
            .installed_at = try arena.dupe(u8, entry.installed_at),
        } };
        for (self.entries.items) |*n| {
            if (std.mem.eql(u8, n.name, name)) {
                n.* = owned;
                return;
            }
        }
        try self.entries.append(arena, owned);
    }

    /// True when `name` was present.
    pub fn remove(self: *Lock, name: []const u8) bool {
        for (self.entries.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.name, name)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// The deterministic file text.
    pub fn render(self: *const Lock, arena: std.mem.Allocator) ![]u8 {
        const sorted = try arena.dupe(Named, self.entries.items);
        std.mem.sort(Named, sorted, {}, struct {
            fn less(_: void, a: Named, b: Named) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"skills\": {{", .{self.version});
        for (sorted, 0..) |n, i| {
            try w.writeAll(if (i == 0) "\n    " else ",\n    ");
            try std.json.Stringify.value(n.name, .{}, w);
            try w.writeAll(": {\n      \"source\": ");
            try std.json.Stringify.value(n.entry.source, .{}, w);
            try w.writeAll(",\n      \"ref\": ");
            try std.json.Stringify.value(n.entry.ref, .{}, w);
            try w.writeAll(",\n      \"commit\": ");
            try std.json.Stringify.value(n.entry.commit, .{}, w);
            try w.writeAll(",\n      \"installed_at\": ");
            try std.json.Stringify.value(n.entry.installed_at, .{}, w);
            try w.writeAll("\n    }");
        }
        try w.writeAll(if (sorted.len == 0) "}\n}\n" else "\n  }\n}\n");
        return aw.written();
    }

    pub fn write(self: *const Lock, workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) !void {
        const text = try self.render(arena);
        try workspace.createDirPath(io, ".ifnh");
        try fsutil.atomicWriteFile(workspace, io, arena, path, text);
    }
};

/// Parse lockfile text. `error.InvalidLock` for bad JSON or a wrong shape.
pub fn parse(arena: std.mem.Allocator, text: []const u8) (Error || std.mem.Allocator.Error)!Lock {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLock,
    };
    if (v != .object) return error.InvalidLock;
    var lock = Lock{};
    const version = v.object.get("version") orelse return error.InvalidLock;
    if (version != .integer) return error.InvalidLock;
    lock.version = version.integer;
    const skills = v.object.get("skills") orelse return error.InvalidLock;
    if (skills != .object) return error.InvalidLock;
    var it = skills.object.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr.*;
        if (e != .object) return error.InvalidLock;
        const source = stringField(e.object, "source") orelse return error.InvalidLock;
        const commit = stringField(e.object, "commit") orelse return error.InvalidLock;
        try lock.put(arena, kv.key_ptr.*, .{
            .source = source,
            .ref = stringField(e.object, "ref") orelse "",
            .commit = commit,
            .installed_at = stringField(e.object, "installed_at") orelse "",
        });
    }
    return lock;
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const f = o.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

/// Read `.ifnh/skills.lock.json` under `workspace`. A missing file is an empty
/// lock; unreadable or malformed content is `error.InvalidLock`.
pub fn read(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) (Error || std.mem.Allocator.Error)!Lock {
    const text = fsutil.readSmallFile(workspace, io, arena, path, max_lock_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLock,
    };
    return parse(arena, text);
}

/// First seven characters of a commit, or "-" when there is none.
pub fn shortCommit(commit: ?[]const u8) []const u8 {
    const c = commit orelse return "-";
    return if (c.len >= 7) c[0..7] else if (c.len > 0) c else "-";
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "skills lock writer is byte-stable: sorted names, fixed fields, trailing newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lock = Lock{};
    try lock.put(arena, "zeta", .{ .source = "https://example.com/z.git", .commit = "b" ** 40, .installed_at = "2026-11-03T12:00:00Z" });
    try lock.put(arena, "alpha", .{ .source = "git@example.com:o/a.git", .ref = "v1", .commit = "a" ** 40, .installed_at = "2026-11-03T11:00:00Z" });
    const text = try lock.render(arena);
    try testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "skills": {
        \\    "alpha": {
        \\      "source": "git@example.com:o/a.git",
        \\      "ref": "v1",
        \\      "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\      "installed_at": "2026-11-03T11:00:00Z"
        \\    },
        \\    "zeta": {
        \\      "source": "https://example.com/z.git",
        \\      "ref": "",
        \\      "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\      "installed_at": "2026-11-03T12:00:00Z"
        \\    }
        \\  }
        \\}
        \\
    , text);

    // Round trip, and an empty lock renders compactly.
    const back = try parse(arena, text);
    try testing.expectEqualStrings(text, try back.render(arena));
    try testing.expectEqualStrings("{\n  \"version\": 1,\n  \"skills\": {}\n}\n", try (Lock{}).render(arena));
}

test "skills lock reader: missing file is empty, unknown fields are ignored, version is kept" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty = try read(tmp.dir, io, arena);
    try testing.expectEqual(@as(usize, 0), empty.entries.items.len);

    try tmp.dir.createDirPath(io, ".ifnh");
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{\"version\":2,\"extra\":true,\"skills\":{\"s\":{\"source\":\"https://h/s\",\"commit\":\"abc\",\"future\":1}}}" });
    const lock = try read(tmp.dir, io, arena);
    try testing.expectEqual(@as(i64, 2), lock.version);
    try testing.expectEqualStrings("https://h/s", lock.get("s").?.source);
    try testing.expectEqualStrings("", lock.get("s").?.ref);
    try testing.expect(lock.get("t") == null);
    try testing.expect(std.mem.startsWith(u8, try lock.render(arena), "{\n  \"version\": 2,"));
}

test "skills lock reader: malformed JSON or a wrong shape is InvalidLock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "not json",
        "[]",
        "{\"skills\":{}}",
        "{\"version\":\"1\",\"skills\":{}}",
        "{\"version\":1,\"skills\":[]}",
        "{\"version\":1,\"skills\":{\"s\":\"x\"}}",
        "{\"version\":1,\"skills\":{\"s\":{\"source\":\"u\"}}}",
        "{\"version\":1,\"skills\":{\"s\":{\"source\":1,\"commit\":\"c\"}}}",
    }) |text| {
        try testing.expectError(error.InvalidLock, parse(arena, text));
    }
    try testing.expectEqualStrings("skills lockfile is not valid JSON: .ifnh/skills.lock.json", invalid_message);
}

test "skills lock put replaces, remove reports presence, shortCommit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lock = Lock{};
    try lock.put(arena, "s", .{ .source = "u1", .commit = "1" ** 40 });
    try lock.put(arena, "s", .{ .source = "u2", .commit = "2" ** 40 });
    try testing.expectEqual(@as(usize, 1), lock.entries.items.len);
    try testing.expectEqualStrings("u2", lock.get("s").?.source);
    try testing.expect(lock.remove("s"));
    try testing.expect(!lock.remove("s"));
    try testing.expectEqualStrings("2222222", shortCommit("2" ** 40));
    try testing.expectEqualStrings("-", shortCommit(null));
    try testing.expectEqualStrings("-", shortCommit(""));
}
