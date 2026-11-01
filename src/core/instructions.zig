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
    layer: []const u8, // "builtin" | "repo" | "project" | "nested"
    /// Bytes this source contributed to `Assembled.text`, header included
    /// (D-08 context x-ray). Sources sum to the total minus `other`.
    bytes: usize = 0,
};

pub const Assembled = struct {
    text: []const u8,
    /// Length of the byte-stable prefix of `text` (B-03): the built-in
    /// prompt plus the project-level sources (AGENTS.md, CLAUDE.md,
    /// .ifnh/instructions). Everything after it is volatile (focus-dir
    /// nested instructions, and whatever the caller appends, e.g. the
    /// skills catalog) and must not invalidate a cached prefix.
    stable_len: usize,
    sources: []Source,
};

/// Load and assemble project instructions from `workspace`.
/// Missing files are skipped silently; over-long files are truncated.
/// `focus_dirs` (C30/C31): for each directory the agent is working in,
/// a nested AGENTS.md applies when present.
pub fn assemble(
    workspace: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    builtin: []const u8,
    focus_dirs: []const []const u8,
) !Assembled {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    var sources: std.ArrayListUnmanaged(Source) = .empty;

    try parts.appendSlice(arena, builtin);
    try sources.append(arena, .{ .path = "builtin", .layer = "builtin", .bytes = parts.items.len });

    const repo_files = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
    for (repo_files) |f| {
        if (loadBounded(workspace, io, arena, f)) |content| {
            const start = parts.items.len;
            try parts.appendSlice(arena, "\n\n# Instructions from ");
            try parts.appendSlice(arena, f);
            try parts.appendSlice(arena, "\n\n");
            try parts.appendSlice(arena, content);
            try sources.append(arena, .{
                .path = try arena.dupe(u8, f),
                .layer = "repo",
                .bytes = parts.items.len - start,
            });
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
            const start = parts.items.len;
            try parts.appendSlice(arena, "\n\n# Project instruction: ");
            try parts.appendSlice(arena, rel);
            try parts.appendSlice(arena, "\n\n");
            try parts.appendSlice(arena, content);
            try sources.append(arena, .{
                .path = rel,
                .layer = "project",
                .bytes = parts.items.len - start,
            });
        } else |_| {}
    }

    // Everything above this point is the byte-stable prefix: it depends
    // only on the repository, never on the turn's focus directories.
    const stable_len = parts.items.len;

    // Nested AGENTS.md for focus directories (deepest path wins duplicates).
    var seen_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (focus_dirs) |dir| {
        if (dir.len == 0 or std.mem.eql(u8, dir, ".")) continue;
        var dup = false;
        for (seen_dirs.items) |sd| {
            if (std.mem.eql(u8, sd, dir)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        seen_dirs.append(arena, dir) catch continue;
        const agents_path = std.fmt.allocPrint(arena, "{s}/AGENTS.md", .{dir}) catch continue;
        if (loadBounded(workspace, io, arena, agents_path)) |content| {
            const start = parts.items.len;
            try parts.appendSlice(arena, "\n\n# Instructions from ");
            try parts.appendSlice(arena, agents_path);
            try parts.appendSlice(arena, "\n\n");
            try parts.appendSlice(arena, content);
            try sources.append(arena, .{
                .path = agents_path,
                .layer = "nested",
                .bytes = parts.items.len - start,
            });
        } else |_| {}
    }

    return .{ .text = parts.items, .stable_len = stable_len, .sources = sources.items };
}

/// Append a caller-owned fragment (e.g. `profiles.<name>.prompt`, D-03) to
/// an assembled prompt. The fragment is volatile by construction, so
/// `stable_len` does not move.
pub fn appendFragment(arena: std.mem.Allocator, base: Assembled, fragment: []const u8) !Assembled {
    const extra = std.mem.trimEnd(u8, fragment, " \t\r\n");
    if (extra.len == 0) return base;
    const text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base.text, extra });
    return .{ .text = text, .stable_len = base.stable_len, .sources = base.sources };
}

/// Rough token estimate for a byte count (D-08): ~4 bytes per token.
/// Labelled "est." wherever it is shown; no tokenizer is bundled.
pub fn estimateTokens(bytes: usize) usize {
    return (bytes + 3) / 4;
}

/// `/context` report (D-08): per-source byte counts plus an estimate, as
/// text or as JSON. Everything the caller appended after assembly (skills
/// catalog, profile fragment, attachments) shows up as `other`.
pub fn contextReport(arena: std.mem.Allocator, assembled: Assembled, json: bool) ![]u8 {
    const total = assembled.text.len;
    var attributed: usize = 0;
    for (assembled.sources) |s| attributed += s.bytes;
    const other = total - @min(total, attributed);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (json) {
        try w.print("{{\"total_bytes\":{d},\"estimated_tokens\":{d},\"sources\":[", .{ total, estimateTokens(total) });
        for (assembled.sources, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"path\":");
            try std.json.Stringify.value(s.path, .{}, w);
            try w.writeAll(",\"layer\":");
            try std.json.Stringify.value(s.layer, .{}, w);
            try w.print(",\"bytes\":{d},\"estimated_tokens\":{d}}}", .{ s.bytes, estimateTokens(s.bytes) });
        }
        try w.print("],\"other_bytes\":{d},\"other_estimated_tokens\":{d}}}", .{ other, estimateTokens(other) });
        return aw.written();
    }

    try w.print("context: {d} bytes (~{d} tokens, est.)\n", .{ total, estimateTokens(total) });
    for (assembled.sources) |s| {
        try w.print("  {d:>8} B  ~{d:>6} tok  [{s}] {s}\n", .{ s.bytes, estimateTokens(s.bytes), s.layer, s.path });
    }
    if (other > 0) {
        try w.print("  {d:>8} B  ~{d:>6} tok  [other] appended after assembly (skills, fragments)\n", .{ other, estimateTokens(other) });
    }
    return aw.written();
}

/// Extract the directories referenced by tool calls in the history
/// (read/edit/write/grep targets), used to focus nested instructions.
pub fn focusDirsFromHistory(arena: std.mem.Allocator, history: []const @import("types.zig").ChatMessage, max: usize) []const []const u8 {
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = history.len;
    while (i > 0 and dirs.items.len < max) {
        i -= 1;
        const msg = history[i];
        const tcj = msg.tool_calls_json orelse continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{}) catch continue;
        if (v != .array) continue;
        for (v.array.items) |item| {
            if (dirs.items.len >= max) break;
            if (item != .object) continue;
            const args_s = item.object.get("arguments_json") orelse continue;
            if (args_s != .string) continue;
            const args = std.json.parseFromSliceLeaky(std.json.Value, arena, args_s.string, .{}) catch continue;
            if (args != .object) continue;
            const path_v = args.object.get("path") orelse continue;
            if (path_v != .string) continue;
            const dir = std.fs.path.dirname(path_v.string) orelse continue;
            if (dir.len == 0) continue;
            var dup = false;
            for (dirs.items) |d| {
                if (std.mem.eql(u8, d, dir)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) dirs.append(arena, arena.dupe(u8, dir) catch continue) catch {};
        }
    }
    return dirs.items;
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

    const assembled = try assemble(tmp.dir, io, a, "builtin prompt", &.{});
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
    const assembled = try assemble(tmp.dir, io, arena_state.allocator(), "only builtin", &.{});
    try std.testing.expectEqual(@as(usize, 1), assembled.sources.len);
}

test "focus dirs pull in nested AGENTS.md" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/core");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/AGENTS.md", .data = "core rules" });
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const asm2 = try assemble(tmp.dir, io, arena_state.allocator(), "builtin", &.{"src/core"});
    try std.testing.expect(std.mem.indexOf(u8, asm2.text, "core rules") != null);
    try std.testing.expectEqual(@as(usize, 3), asm2.sources.len);

    // The stable prefix is the same with and without focus dirs: only the
    // volatile tail changes (B-03).
    const plain = try assemble(tmp.dir, io, arena_state.allocator(), "builtin", &.{});
    try std.testing.expectEqual(plain.stable_len, asm2.stable_len);
    try std.testing.expectEqual(plain.text.len, plain.stable_len);
    try std.testing.expect(asm2.text.len > asm2.stable_len);
    try std.testing.expectEqualStrings(plain.text, asm2.text[0..asm2.stable_len]);
    try std.testing.expect(std.mem.indexOf(u8, asm2.text[0..asm2.stable_len], "core rules") == null);
}
test "appendFragment keeps the stable prefix and trims the tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = Assembled{ .text = "builtin", .stable_len = 7, .sources = &.{} };
    const same = try appendFragment(arena, base, "  \n\t");
    try std.testing.expectEqualStrings("builtin", same.text);
    try std.testing.expectEqual(@as(usize, 7), same.stable_len);

    const with_prompt = try appendFragment(arena, base, "be terse  \n");
    try std.testing.expectEqualStrings("builtin\n\nbe terse", with_prompt.text);
    try std.testing.expectEqual(@as(usize, 7), with_prompt.stable_len);
}

test "context report attributes bytes to every source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });
    try tmp.dir.createDirPath(io, ".ifnh/instructions");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/a.md", .data = "proj a" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const assembled = try assemble(tmp.dir, io, a, "builtin prompt", &.{});
    var attributed: usize = 0;
    for (assembled.sources) |s| {
        try std.testing.expect(s.bytes > 0);
        attributed += s.bytes;
    }
    // Sources account for every byte of the assembly.
    try std.testing.expectEqual(assembled.text.len, attributed);

    const text = try contextReport(a, assembled, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "est.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[builtin] builtin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[repo] AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[project] .ifnh/instructions/a.md") != null);
    // Nothing was appended after assembly.
    try std.testing.expect(std.mem.indexOf(u8, text, "[other]") == null);

    const json = try contextReport(a, assembled, true);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try std.testing.expect(parsed == .object);
    const total = parsed.object.get("total_bytes").?;
    try std.testing.expectEqual(@as(i64, @intCast(assembled.text.len)), total.integer);
    try std.testing.expectEqual(@as(i64, @intCast(estimateTokens(assembled.text.len))), parsed.object.get("estimated_tokens").?.integer);
    try std.testing.expectEqual(@as(usize, 3), parsed.object.get("sources").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), parsed.object.get("other_bytes").?.integer);
}

test "context report counts bytes appended after assembly as other" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const assembled = Assembled{
        .text = "builtin" ++ "\n\nskills catalog",
        .stable_len = 7,
        .sources = try a.dupe(Source, &.{.{ .path = "builtin", .layer = "builtin", .bytes = 7 }}),
    };

    const report = try contextReport(a, assembled, true);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, report, .{});
    const total = parsed.object.get("total_bytes").?.integer;
    const other = parsed.object.get("other_bytes").?.integer;
    try std.testing.expectEqual(total, parsed.object.get("sources").?.array.items[0].object.get("bytes").?.integer + other);
    try std.testing.expectEqual(@as(i64, @intCast(assembled.text.len - 7)), other);

    const plain = try contextReport(a, assembled, false);
    try std.testing.expect(std.mem.indexOf(u8, plain, "[other]") != null);
}
