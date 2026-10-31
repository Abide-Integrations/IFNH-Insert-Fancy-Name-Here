//! Per-project permission grants (ACTIVE_PLAN C-05): `.ifnh/permissions.local.json`.
//!
//! Written when the user answers `p` ("always for this project") at an
//! approval prompt, read back at startup as engine grants with scope
//! `.project`. This is a grants store, not policy:
//!   - a grant only turns `ask` into `allow` for the exact pattern the user
//!     saw; protected paths, deny rules and git ceilings are checked first;
//!   - the file is gitignored, so a cloned repository cannot ship grants, and
//!     it is a protected path, so an agent cannot write it;
//!   - it is excluded from the policy hash (`turn_cache.policyHash`), so
//!     answering `p` mid-session does not trip the fail-closed check (G99).
//!
//! Shape: `{"version":1,"command_prefix":["npm test"],"path_write":["src/a.zig"]}`.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const engine_mod = @import("engine.zig");

pub const path = ".ifnh/permissions.local.json";
pub const gitignore_line = "permissions.local.json";
const max_bytes = 256 * 1024;

pub const Grants = struct {
    command_prefix: []const []const u8 = &.{},
    path_write: []const []const u8 = &.{},
};

pub const Kind = enum { command_prefix, path_write };

pub const Loaded = union(enum) {
    /// No file: nothing granted.
    absent,
    grants: Grants,
    /// The file exists but is unusable; the text is a one-line reason.
    invalid: []const u8,
};

/// Parse file text. Empty patterns are dropped; any other deviation from the
/// documented shape is an error so the file is never half-trusted.
pub fn parse(arena: std.mem.Allocator, text: []const u8) !Grants {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.InvalidJson;
    if (root != .object) return error.InvalidShape;
    const version = root.object.get("version") orelse return error.InvalidShape;
    if (version != .integer or version.integer != 1) return error.UnsupportedVersion;
    return .{
        .command_prefix = try stringList(arena, root.object.get("command_prefix")),
        .path_write = try stringList(arena, root.object.get("path_write")),
    };
}

fn stringList(arena: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    const value = v orelse return &.{};
    if (value != .array) return error.InvalidShape;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidShape;
        const s = std.mem.trim(u8, item.string, " \t\r\n");
        if (s.len > 0) try out.append(arena, s);
    }
    return out.items;
}

/// Pretty-printed, sorted, de-duplicated, newline-terminated.
pub fn serialize(arena: std.mem.Allocator, g: Grants) ![]const u8 {
    const clean = Grants{
        .command_prefix = try sortedUnique(arena, g.command_prefix),
        .path_write = try sortedUnique(arena, g.path_write),
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .version = @as(u32, 1),
        .command_prefix = clean.command_prefix,
        .path_write = clean.path_write,
    }, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

fn sortedUnique(arena: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const copy = try arena.dupe([]const u8, items);
    std.mem.sort([]const u8, copy, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var n: usize = 0;
    for (copy) |s| {
        if (n > 0 and std.mem.eql(u8, copy[n - 1], s)) continue;
        copy[n] = s;
        n += 1;
    }
    return copy[0..n];
}

pub fn load(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) Loaded {
    const text = fsutil.readSmallFile(cwd, io, arena, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return .{ .invalid = @errorName(err) },
    };
    const g = parse(arena, text) catch |err| return .{ .invalid = @errorName(err) };
    return .{ .grants = g };
}

/// Register every entry as a `.project` grant on the engine.
pub fn apply(engine: *engine_mod.Engine, g: Grants) !void {
    for (g.command_prefix) |p| try engine.commandPrefixGrant(p, .project);
    for (g.path_write) |p| try engine.pathWriteGrant(p, .project);
}

/// Add one pattern to the file (read, merge, atomic write). An unusable
/// existing file is never overwritten: the caller gets `error.InvalidGrantsFile`
/// and the grant stays session-only.
pub fn add(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, kind: Kind, pattern: []const u8) !void {
    var g = switch (load(arena, io, cwd)) {
        .absent => Grants{},
        .grants => |existing| existing,
        .invalid => return error.InvalidGrantsFile,
    };
    switch (kind) {
        .command_prefix => g.command_prefix = try appendOne(arena, g.command_prefix, pattern),
        .path_write => g.path_write = try appendOne(arena, g.path_write, pattern),
    }
    try cwd.createDirPath(io, ".ifnh");
    try fsutil.atomicWriteFile(cwd, io, arena, path, try serialize(arena, g));
}

fn appendOne(arena: std.mem.Allocator, list: []const []const u8, item: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = item;
    return out;
}

/// Content for `.ifnh/.gitignore` that also ignores the grants file: `current`
/// is the existing text (null when the file does not exist yet). Returns null
/// when nothing needs to change.
pub fn gitignoreUpdate(arena: std.mem.Allocator, current: ?[]const u8, defaults: []const u8) !?[]const u8 {
    const text = current orelse return try std.fmt.allocPrint(arena, "{s}{s}\n", .{ defaults, gitignore_line });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), gitignore_line)) return null;
    }
    const sep: []const u8 = if (text.len == 0 or text[text.len - 1] == '\n') "" else "\n";
    return try std.fmt.allocPrint(arena, "{s}{s}{s}\n", .{ text, sep, gitignore_line });
}

// ---------------------------------------------------------------- tests

test "local grants: serialize is sorted, unique and round-trips" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const text = try serialize(arena, .{
        .command_prefix = &.{ "npm test", "make", "npm test" },
        .path_write = &.{ "src/b.zig", "src/a.zig" },
    });
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "command_prefix": [
        \\    "make",
        \\    "npm test"
        \\  ],
        \\  "path_write": [
        \\    "src/a.zig",
        \\    "src/b.zig"
        \\  ]
        \\}
        \\
    , text);
    const back = try parse(arena, text);
    try std.testing.expectEqual(@as(usize, 2), back.command_prefix.len);
    try std.testing.expectEqualStrings("src/a.zig", back.path_write[0]);
}

test "local grants: bad files are rejected, not half-read" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    try std.testing.expectError(error.InvalidJson, parse(arena, "{nope"));
    try std.testing.expectError(error.InvalidShape, parse(arena, "[]"));
    try std.testing.expectError(error.InvalidShape, parse(arena, "{\"version\":1,\"path_write\":\"src/**\"}"));
    try std.testing.expectError(error.InvalidShape, parse(arena, "{\"version\":1,\"path_write\":[1]}"));
    try std.testing.expectError(error.UnsupportedVersion, parse(arena, "{\"version\":2}"));
    try std.testing.expectError(error.InvalidShape, parse(arena, "{}"));
    // Empty patterns are dropped rather than becoming match-everything.
    const g = try parse(arena, "{\"version\":1,\"command_prefix\":[\"\",\"  \",\"ls\"]}");
    try std.testing.expectEqual(@as(usize, 1), g.command_prefix.len);
}

test "local grants: add merges on disk and never overwrites a bad file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();

    try std.testing.expect(load(arena, io, tmp.dir) == .absent);
    try add(arena, io, tmp.dir, .path_write, "src/b.zig");
    try add(arena, io, tmp.dir, .path_write, "src/a.zig");
    try add(arena, io, tmp.dir, .path_write, "src/a.zig");
    try add(arena, io, tmp.dir, .command_prefix, "npm test");
    const g = load(arena, io, tmp.dir).grants;
    try std.testing.expectEqual(@as(usize, 2), g.path_write.len);
    try std.testing.expectEqualStrings("src/a.zig", g.path_write[0]);
    try std.testing.expectEqualStrings("npm test", g.command_prefix[0]);

    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "{broken" });
    try std.testing.expect(load(arena, io, tmp.dir) == .invalid);
    try std.testing.expectError(error.InvalidGrantsFile, add(arena, io, tmp.dir, .path_write, "x"));
    const still = try tmp.dir.readFileAlloc(io, path, arena, .limited(1024));
    try std.testing.expectEqualStrings("{broken", still);
}

test "local grants: apply widens ask to allow, but not past protection or deny" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var e = engine_mod.Engine.init(st.allocator(), .ask);
    try apply(&e, .{
        .command_prefix = &.{"npm test"},
        .path_write = &.{ "src/a.zig", ".ifnh/config.json", ".ifnh/permissions.local.json" },
    });
    try std.testing.expectEqual(engine_mod.Decision.allow, e.decidePath(.write, "src/a.zig"));
    try std.testing.expectEqual(engine_mod.Decision.ask, e.decidePath(.write, "src/other.zig"));
    try std.testing.expectEqual(engine_mod.Decision.deny, e.decidePath(.write, ".ifnh/config.json"));
    try std.testing.expectEqual(engine_mod.Decision.deny, e.decidePath(.write, ".ifnh/permissions.local.json"));
    try std.testing.expectEqual(engine_mod.Decision.allow, e.decideCommand("npm test -- -u"));
    e.command_deny = &.{"npm"};
    try std.testing.expectEqual(engine_mod.Decision.deny, e.decideCommand("npm test"));
}

test "local grants: gitignore gains the line once" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const defaults = "sessions/\ncache/\n";
    try std.testing.expectEqualStrings("sessions/\ncache/\npermissions.local.json\n", (try gitignoreUpdate(arena, null, defaults)).?);
    try std.testing.expectEqualStrings("a\npermissions.local.json\n", (try gitignoreUpdate(arena, "a", defaults)).?);
    try std.testing.expectEqualStrings("a\npermissions.local.json\n", (try gitignoreUpdate(arena, "a\n", defaults)).?);
    try std.testing.expect((try gitignoreUpdate(arena, "a\npermissions.local.json\n", defaults)) == null);
}
