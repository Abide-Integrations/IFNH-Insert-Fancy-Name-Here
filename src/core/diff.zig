//! Unified diff of two texts for approval previews (ACTIVE_PLAN C-05).
//!
//! Pure: text in, text out. Lives in `core` (not `ui`) because the write and
//! edit tools build the preview and `tools` may not depend on `ui`.
//!
//! Lines keep their terminator while being compared, so a CRLF file diffed
//! against its LF twin shows every line as changed, and a missing final
//! newline is reported with git's `\ No newline at end of file` marker.

const std = @import("std");

pub const Options = struct {
    context: usize = 3,
    /// Output is cut after this many lines or bytes, then a
    /// `... (<n> more lines)` line is appended.
    max_lines: usize = 40,
    max_bytes: usize = 4096,
    /// Above this many LCS cells the changed middle is shown as one
    /// delete-then-add block instead of a minimal diff.
    max_cells: usize = 4 * 1024 * 1024,
};

const Kind = enum { keep, del, add };
const Op = struct { kind: Kind, line: []const u8 };

/// Unified diff of `before` -> `after` for `path`; "" when they are equal.
/// Result is owned by `arena`.
pub fn unifiedDiff(arena: std.mem.Allocator, path: []const u8, before: []const u8, after: []const u8, opts: Options) ![]const u8 {
    if (std.mem.eql(u8, before, after)) return "";
    const a = try splitLines(arena, before);
    const b = try splitLines(arena, after);
    const ops = try editScript(arena, a, b, opts.max_cells);

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    try lines.append(arena, try std.fmt.allocPrint(arena, "--- a/{s}", .{path}));
    try lines.append(arena, try std.fmt.allocPrint(arena, "+++ b/{s}", .{path}));

    // Walk the script, emitting a hunk per cluster of changes. Two changes
    // belong to one hunk when at most 2 * context unchanged lines separate them.
    var i: usize = 0;
    var old_line: usize = 0; // old lines consumed before ops[i]
    var new_line: usize = 0;
    while (i < ops.len) {
        if (ops[i].kind == .keep) {
            old_line += 1;
            new_line += 1;
            i += 1;
            continue;
        }
        // Hunk start: back up over up to `context` kept lines.
        var start = i;
        var back: usize = 0;
        while (start > 0 and back < opts.context and ops[start - 1].kind == .keep) : (back += 1) start -= 1;
        // Hunk end: extend until `2 * context + 1` kept lines in a row.
        var end = i;
        var last_change = i;
        while (end < ops.len) : (end += 1) {
            if (ops[end].kind != .keep) {
                last_change = end;
            } else if (end - last_change > 2 * opts.context) break;
        }
        const stop = @min(last_change + 1 + opts.context, ops.len);

        var old_count: usize = 0;
        var new_count: usize = 0;
        for (ops[start..stop]) |op| {
            if (op.kind != .add) old_count += 1;
            if (op.kind != .del) new_count += 1;
        }
        const old_start = old_line - back;
        const new_start = new_line - back;
        try lines.append(arena, try std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@", .{
            if (old_count == 0) old_start else old_start + 1, old_count,
            if (new_count == 0) new_start else new_start + 1, new_count,
        }));
        for (ops[start..stop]) |op| {
            const body = if (std.mem.endsWith(u8, op.line, "\n")) op.line[0 .. op.line.len - 1] else op.line;
            const sign: u8 = switch (op.kind) {
                .keep => ' ',
                .del => '-',
                .add => '+',
            };
            try lines.append(arena, try std.fmt.allocPrint(arena, "{c}{s}", .{ sign, body }));
            if (!std.mem.endsWith(u8, op.line, "\n")) try lines.append(arena, "\\ No newline at end of file");
        }
        // Advance the cursors past everything the hunk covered.
        for (ops[i..stop]) |op| {
            if (op.kind != .add) old_line += 1;
            if (op.kind != .del) new_line += 1;
        }
        i = stop;
    }
    return truncate(arena, lines.items, opts);
}

fn truncate(arena: std.mem.Allocator, lines: []const []const u8, opts: Options) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var shown: usize = 0;
    var bytes: usize = 0;
    for (lines) |l| {
        if (shown >= opts.max_lines or bytes + l.len + 1 > opts.max_bytes) break;
        try aw.writer.writeAll(l);
        try aw.writer.writeByte('\n');
        bytes += l.len + 1;
        shown += 1;
    }
    if (shown < lines.len) try aw.writer.print("... ({d} more lines)\n", .{lines.len - shown});
    return aw.written();
}

/// Split keeping each line's terminator; no phantom empty last line.
fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |nl| nl + 1 else text.len;
        try out.append(arena, text[pos..end]);
        pos = end;
    }
    return out.items;
}

/// Shortest edit script via LCS over the lines between the common prefix and
/// suffix. Oversized middles degrade to delete-all-then-add-all.
fn editScript(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8, max_cells: usize) ![]const Op {
    var prefix: usize = 0;
    while (prefix < a.len and prefix < b.len and std.mem.eql(u8, a[prefix], b[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < a.len - prefix and suffix < b.len - prefix and
        std.mem.eql(u8, a[a.len - 1 - suffix], b[b.len - 1 - suffix])) suffix += 1;
    const ma = a[prefix .. a.len - suffix];
    const mb = b[prefix .. b.len - suffix];

    var ops: std.ArrayListUnmanaged(Op) = .empty;
    for (a[0..prefix]) |l| try ops.append(arena, .{ .kind = .keep, .line = l });

    const cells = (ma.len + 1) * (mb.len + 1);
    if (ma.len == 0 or mb.len == 0 or cells > max_cells) {
        for (ma) |l| try ops.append(arena, .{ .kind = .del, .line = l });
        for (mb) |l| try ops.append(arena, .{ .kind = .add, .line = l });
    } else {
        // lcs[i][j] = LCS length of ma[i..] and mb[j..].
        const w = mb.len + 1;
        const lcs = try arena.alloc(u32, cells);
        @memset(lcs, 0);
        var i: usize = ma.len;
        while (i > 0) {
            i -= 1;
            var j: usize = mb.len;
            while (j > 0) {
                j -= 1;
                lcs[i * w + j] = if (std.mem.eql(u8, ma[i], mb[j]))
                    lcs[(i + 1) * w + j + 1] + 1
                else
                    @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
            }
        }
        var x: usize = 0;
        var y: usize = 0;
        while (x < ma.len and y < mb.len) {
            if (std.mem.eql(u8, ma[x], mb[y])) {
                try ops.append(arena, .{ .kind = .keep, .line = ma[x] });
                x += 1;
                y += 1;
            } else if (lcs[(x + 1) * w + y] >= lcs[x * w + y + 1]) {
                try ops.append(arena, .{ .kind = .del, .line = ma[x] });
                x += 1;
            } else {
                try ops.append(arena, .{ .kind = .add, .line = mb[y] });
                y += 1;
            }
        }
        for (ma[x..]) |l| try ops.append(arena, .{ .kind = .del, .line = l });
        for (mb[y..]) |l| try ops.append(arena, .{ .kind = .add, .line = l });
    }
    for (a[a.len - suffix ..]) |l| try ops.append(arena, .{ .kind = .keep, .line = l });
    return ops.items;
}

// ---------------------------------------------------------------- tests

fn diffOf(arena: std.mem.Allocator, before: []const u8, after: []const u8, opts: Options) ![]const u8 {
    return unifiedDiff(arena, "f.txt", before, after, opts);
}

test "diff: new file is all additions" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const got = try diffOf(st.allocator(), "", "one\ntwo\n", .{});
    try std.testing.expectEqualStrings("--- a/f.txt\n+++ b/f.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n", got);
}

test "diff: deleted file is all removals" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const got = try diffOf(st.allocator(), "one\ntwo\n", "", .{});
    try std.testing.expectEqualStrings("--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +0,0 @@\n-one\n-two\n", got);
}

test "diff: single-line change keeps three lines of context" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const before = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
    const after = "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n";
    const got = try diffOf(st.allocator(), before, after, .{});
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+FIVE\n 6\n 7\n 8\n",
        got,
    );
}

test "diff: distant changes make two hunks, near ones merge" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const base = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
    const far = try diffOf(arena, base, "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n", .{});
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, far, "@@ -"));
    const near = try diffOf(arena, base, "A\nb\nc\nd\ne\nF\ng\nh\ni\nj\nk\nl\n", .{});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, near, "@@ -"));
}

test "diff: identical content is empty" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    try std.testing.expectEqualStrings("", try diffOf(st.allocator(), "same\n", "same\n", .{}));
    try std.testing.expectEqualStrings("", try diffOf(st.allocator(), "", "", .{}));
}

test "diff: output is truncated by lines and by bytes" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    var big: std.ArrayListUnmanaged(u8) = .empty;
    for (0..100) |n| try big.print(arena, "line {d}\n", .{n});

    // 2 headers + 1 hunk header + 100 added lines = 103; keep 10, 93 more.
    const by_lines = try diffOf(arena, "", big.items, .{ .max_lines = 10 });
    try std.testing.expect(std.mem.endsWith(u8, by_lines, "... (93 more lines)\n"));
    try std.testing.expectEqual(@as(usize, 11), std.mem.count(u8, by_lines, "\n"));

    const by_bytes = try diffOf(arena, "", big.items, .{ .max_bytes = 64 });
    try std.testing.expect(by_bytes.len < 64 + 32);
    try std.testing.expect(std.mem.indexOf(u8, by_bytes, "more lines)") != null);

    // Default limits: 40 lines.
    const default_cut = try diffOf(arena, "", big.items, .{});
    try std.testing.expectEqual(@as(usize, 41), std.mem.count(u8, default_cut, "\n"));
}

test "diff: CRLF is preserved and differs from LF" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const arena = st.allocator();
    const got = try diffOf(arena, "a\r\nb\r\n", "a\r\nB\r\n", .{});
    try std.testing.expectEqualStrings("--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n", got);
    // Same words, different line endings: every line changes.
    const eol = try diffOf(arena, "a\nb\n", "a\r\nb\r\n", .{});
    try std.testing.expect(std.mem.indexOf(u8, eol, "-a\n-b\n+a\r\n+b\r\n") != null);
}

test "diff: missing final newline is flagged" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const got = try diffOf(st.allocator(), "a\nb", "a\nb\n", .{});
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n",
        got,
    );
}
