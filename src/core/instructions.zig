//! Instruction/context assembly (DECISIONS C29-C31, C35).
//!
//! Precedence (low to high): built-in system prompt < repo-root AGENTS.md
//! < repo-root CLAUDE.md (both loaded; AGENTS.md wins conflicts by coming
//! later? no — earlier documents are more general: the assembly order puts
//! more specific sources later) < .ifnh/instructions/*.md (alphabetical).
//! Every loaded source is recorded in an assembly log (C33/C34).

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const max_instruction_bytes: usize = 128 * 1024;

pub const Source = struct {
    path: []const u8,
    layer: []const u8, // "builtin" | "repo" | "project"
};

pub const Assembled = struct {
    text: []const u8,
    sources: []Source,
};

/// Load and assemble project instructions from `workspace`.
/// Missing files are skipped silently; over-long files are truncated.
pub fn assemble(
    workspace: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    builtin: []const u8,
) !Assembled {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    var sources: std.ArrayListUnmanaged(Source) = .empty;

    try parts.appendSlice(arena, builtin);
    try sources.append(arena, .{ .path = "builtin", .layer = "builtin" });

    const repo_files = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
    for (repo_files) |f| {
        if (loadBounded(workspace, io, arena, f)) |content| {
            try parts.appendSlice(arena, "\n\n# Instructions from ");
            try parts.appendSlice(arena, f);
            try parts.appendSlice(arena, "\n\n");
            try parts.appendSlice(arena, content);
            try sources.append(arena, .{ .path = try arena.dupe(u8, f), .layer = "repo" });
        } else |_| {}
    }

    // .ifnh/instructions/*.md in sorted order.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    if (workspace.openDir(io, ".ifnh/instructions", .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
        }
    } else |_| {}
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |name| {
        const rel = std.fmt.allocPrint(arena, ".ifnh/instructions/{s}", .{name}) catch continue;
        if (loadBounded(workspace, io, arena, rel)) |content| {
            try parts.appendSlice(arena, "\n\n# Project instruction: ");
            try parts.appendSlice(arena, rel);
            try parts.appendSlice(arena, "\n\n");
            try parts.appendSlice(arena, content);
            try sources.append(arena, .{ .path = rel, .layer = "project" });
        } else |_| {}
    }

    return .{ .text = parts.items, .sources = sources.items };
}

fn loadBounded(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const data = try fsutil.readSmallFile(workspace, io, arena, path, max_instruction_bytes);
    if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
    return data;
}

test "assemble picks up repo and project instructions in order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });
    try tmp.dir.createDirPath(io, ".ifnh/instructions");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/b.md", .data = "proj b" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/a.md", .data = "proj a" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const assembled = try assemble(tmp.dir, io, a, "builtin prompt");
    try std.testing.expect(std.mem.indexOf(u8, assembled.text, "builtin prompt") != null);
    const repo_pos = std.mem.indexOf(u8, assembled.text, "repo rules").?;
    const proj_a = std.mem.indexOf(u8, assembled.text, "proj a").?;
    const proj_b = std.mem.indexOf(u8, assembled.text, "proj b").?;
    try std.testing.expect(repo_pos < proj_a);
    try std.testing.expect(proj_a < proj_b); // alphabetical
    try std.testing.expectEqual(@as(usize, 4), assembled.sources.len);
}

test "assemble tolerates missing files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const assembled = try assemble(tmp.dir, io, arena_state.allocator(), "only builtin");
    try std.testing.expectEqual(@as(usize, 1), assembled.sources.len);
}
