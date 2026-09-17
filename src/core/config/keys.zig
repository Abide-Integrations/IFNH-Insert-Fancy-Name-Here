//! User-level key/value environment file (`~/.config/ifnh/env`).
//!
//! D022: secrets live in env vars and env-file conventions. This file is
//! the persistent store for provider API keys set via `/provider key`.
//! Format: `KEY=VALUE` lines, `#` comments, blank lines ignored. Written
//! atomically with 0600 permissions.

const std = @import("std");
const fsutil = @import("../fsutil.zig");

pub const Keys = struct {
    map: std.process.Environ.Map,

    pub fn init(alloc: std.mem.Allocator) Keys {
        return .{ .map = std.process.Environ.Map.init(alloc) };
    }

    /// Locate the user env file; allocated in `arena` (null if no HOME).
    pub fn path(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
        const home = if (environ) |e| e.get("HOME") else null;
        if (home == null) return null;
        return std.fmt.allocPrint(arena, "{s}/.config/ifnh/env", .{home.?}) catch null;
    }

    /// Parse KEY=VALUE lines (values may contain '='; trimmed).
    pub fn parse(self: *Keys, arena: std.mem.Allocator, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"'");
            if (key.len == 0) continue;
            try self.map.put(try arena.dupe(u8, key), try arena.dupe(u8, value));
        }
    }

    /// Load the user env file, if present.
    pub fn load(self: *Keys, io: std.Io, arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) void {
        const p = path(arena, environ) orelse return;
        const text = fsutil.readSmallFile(std.Io.Dir.cwd(), io, arena, p, 64 * 1024) catch return;
        self.parse(arena, text) catch {};
    }

    /// Set a key and persist the file atomically (0600).
    pub fn store(self: *Keys, io: std.Io, arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map, key: []const u8, value: []const u8) !void {
        try self.map.put(try arena.dupe(u8, key), try arena.dupe(u8, value));
        const p = path(arena, environ) orelse return error.NoHome;
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| {
            try std.Io.Dir.cwd().createDirPath(io, p[0..slash]);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try out.print(arena, "{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        const cwd = std.Io.Dir.cwd();
        try fsutil.atomicWriteFile(cwd, io, arena, p, out.items);
        // 0600: secrets at rest.
        const f = try cwd.openFile(io, p, .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    }
};

test "parse and persist keys file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var keys = Keys.init(arena);
    try keys.parse(arena,
        \\# comment
        \\OPENROUTER_API_KEY = sk-or-v1-abc
        \\SIMPLE=1
        \\QUOTED="hello world"
        \\
    );
    try std.testing.expectEqualStrings("sk-or-v1-abc", keys.map.get("OPENROUTER_API_KEY").?);
    try std.testing.expectEqualStrings("hello world", keys.map.get("QUOTED").?);
    _ = io;
}
