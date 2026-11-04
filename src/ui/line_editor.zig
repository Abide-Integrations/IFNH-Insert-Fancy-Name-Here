//! Interactive line editor for the REPL (ACTIVE_PLAN C-03).
//!
//! Used only when stdin and stderr are terminals and TERM is not dumb; every
//! other case keeps the plain line reader. Raw mode is entered per `readLine`
//! call and left again before it returns, so turns, approval prompts and `!`
//! commands run with an ordinary cooked terminal and working Ctrl-C.
//!
//! All drawing goes to stderr (stdout stays the assistant's text). The module
//! has no file-scope state: the terminal state to restore lives in `Editor`.
//!
//! Layout of this file: pure pieces first (history, `@file` expansion, `!cmd`
//! classification, key decoding, line buffer, layout, completion), then the
//! `Editor` that wires them to the terminal. Everything above `Editor` is
//! unit-tested without a TTY.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../core/fsutil.zig");

pub const max_history = 500;
const max_history_bytes = 1024 * 1024;
const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

// ---------------------------------------------------------------- history

/// Lines typed at the prompt, oldest first. Persisted one entry per line with
/// `\` and newline escaped, so a multi-line entry stays one entry.
pub const History = struct {
    entries: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Whether a submitted line belongs in the history file. Blank lines are
    /// dropped, and so is anything carrying a secret typed at the prompt.
    pub fn recordable(line: []const u8) bool {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) return false;
        return !std.mem.startsWith(u8, t, "/provider key");
    }

    /// Append `line` (copied into `arena`). Consecutive duplicates collapse
    /// and the oldest entries fall off beyond `max_history`.
    pub fn push(self: *History, arena: std.mem.Allocator, line: []const u8) !void {
        if (!recordable(line)) return;
        const t = std.mem.trimEnd(u8, line, " \t\r\n");
        if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], t)) return;
        try self.entries.append(arena, try arena.dupe(u8, t));
        self.bound();
    }

    fn bound(self: *History) void {
        const n = self.entries.items.len;
        if (n <= max_history) return;
        const drop = n - max_history;
        std.mem.copyForwards([]const u8, self.entries.items[0..max_history], self.entries.items[drop..]);
        self.entries.shrinkRetainingCapacity(max_history);
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !History {
        var h = History{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (raw.len == 0) continue;
            var entry: std.ArrayListUnmanaged(u8) = .empty;
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == '\\' and i + 1 < raw.len and (raw[i + 1] == 'n' or raw[i + 1] == '\\')) {
                    try entry.append(arena, if (raw[i + 1] == 'n') '\n' else '\\');
                    i += 1;
                } else try entry.append(arena, raw[i]);
            }
            try h.entries.append(arena, entry.items);
        }
        h.bound();
        return h;
    }

    pub fn serialize(self: *const History, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (self.entries.items) |e| {
            for (e) |c| switch (c) {
                '\\' => try out.appendSlice(arena, "\\\\"),
                '\n' => try out.appendSlice(arena, "\\n"),
                '\r' => {},
                else => try out.append(arena, c),
            };
            try out.append(arena, '\n');
        }
        return out.items;
    }

    /// Index of the newest entry strictly before `before` containing `query`.
    pub fn searchBack(self: *const History, query: []const u8, before: usize) ?usize {
        if (query.len == 0) return null;
        var i = @min(before, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, self.entries.items[i], query) != null) return i;
        }
        return null;
    }
};

/// Up/Down walking. The line being typed is kept as the draft and comes back
/// when the walk passes the newest entry.
pub const HistoryNav = struct {
    pos: ?usize = null,
    draft: []const u8 = "",

    /// Older entry, or null when there is nothing older (or no history).
    pub fn older(self: *HistoryNav, h: *const History, current: []const u8) ?[]const u8 {
        const n = h.entries.items.len;
        if (n == 0) return null;
        if (self.pos) |p| {
            if (p == 0) return null;
            self.pos = p - 1;
        } else {
            self.draft = current;
            self.pos = n - 1;
        }
        return h.entries.items[self.pos.?];
    }

    /// Newer entry, or the draft after the newest one; null when not walking.
    pub fn newer(self: *HistoryNav, h: *const History) ?[]const u8 {
        const p = self.pos orelse return null;
        if (p + 1 >= h.entries.items.len) {
            self.pos = null;
            return self.draft;
        }
        self.pos = p + 1;
        return h.entries.items[p + 1];
    }
};

// ---------------------------------------------------------------- `!cmd`

/// The shell command of a `!cmd` buffer, or null when the buffer is a normal
/// message. A bare `!` yields "" so the caller can show usage. A multi-line
/// buffer yields everything after the `!` as one command.
pub fn parseShellEscape(buffer: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, buffer, " \t\r\n");
    if (t.len == 0 or t[0] != '!') return null;
    return std.mem.trim(u8, t[1..], " \t\r\n");
}

// ---------------------------------------------------------------- `@file`

pub const Attach = union(enum) {
    /// Text to submit.
    ok: []const u8,
    /// A mentioned file could not be attached; nothing should be submitted.
    failed: struct { path: []const u8, reason: []const u8 },
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Replace each `@path` token (at a word boundary, naming a file) with the
/// bare path and append the file contents after the text:
///
///     <file path="src/a.zig">
///     ...contents...
///     </file>
///
/// Contents over `max_bytes` are cut (on a UTF-8 boundary) and marked with
/// `... (truncated)`. A token is a file mention only when it contains `/` or
/// `.` or names an existing file; a bare `@` and `@word` are left alone. A
/// missing, unreadable, binary or directory mention fails the whole line.
pub fn expandAtMentions(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, line: []const u8, max_bytes: usize) !Attach {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    var blocks: std.ArrayListUnmanaged(u8) = .empty;
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    while (i < line.len) {
        const at_boundary = line[i] == '@' and (i == 0 or isSpace(line[i - 1]));
        if (!at_boundary) {
            try text.append(arena, line[i]);
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < line.len and !isSpace(line[end])) end += 1;
        // Sentence punctuation after the path is not part of it.
        var path_end = end;
        while (path_end > i + 1 and std.mem.indexOfScalar(u8, ",;:!?)]}'\".", line[path_end - 1]) != null) path_end -= 1;
        const path = line[i + 1 .. path_end];

        const looks_like_path = std.mem.indexOfAny(u8, path, "/.") != null;
        const exists = path.len > 0 and !looks_like_path and (cwd.statFile(io, path, .{}) catch null) != null;
        if (path.len == 0 or !(looks_like_path or exists)) {
            try text.appendSlice(arena, line[i..end]);
            i = end;
            continue;
        }

        const data = switch (try readAttachment(arena, io, cwd, path, max_bytes)) {
            .ok => |d| d,
            .failed => |reason| return .{ .failed = .{ .path = path, .reason = reason } },
        };
        try text.appendSlice(arena, path);
        try text.appendSlice(arena, line[path_end..end]);
        i = end;

        const dup = for (seen.items) |s| {
            if (std.mem.eql(u8, s, path)) break true;
        } else false;
        if (dup) continue;
        try seen.append(arena, path);
        try blocks.print(arena, "\n<file path=\"{s}\">\n{s}\n</file>", .{ path, data });
    }
    if (blocks.items.len == 0) return .{ .ok = text.items };
    return .{ .ok = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ text.items, blocks.items }) };
}

const ReadResult = union(enum) { ok: []const u8, failed: []const u8 };

fn readAttachment(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8, max_bytes: usize) !ReadResult {
    const file = cwd.openFile(io, path, .{}) catch |err| return .{ .failed = @errorName(err) };
    defer file.close(io);
    const st = file.stat(io) catch |err| return .{ .failed = @errorName(err) };
    if (st.kind == .directory) return .{ .failed = "is a directory" };
    const want: usize = @intCast(@min(st.size, @as(u64, max_bytes) + 1));
    const dest = try arena.alloc(u8, want);
    var rbuf: [4096]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const got = reader.interface.readSliceShort(dest) catch |err| return .{ .failed = @errorName(err) };
    var data = dest[0..got];
    if (std.mem.indexOfScalar(u8, data, 0) != null) return .{ .failed = "binary file" };
    if (data.len > max_bytes) {
        var cut = max_bytes;
        while (cut > 0 and (data[cut] & 0xC0) == 0x80) cut -= 1;
        data = try std.fmt.allocPrint(arena, "{s}\n... (truncated)", .{data[0..cut]});
    }
    return .{ .ok = data };
}

// ---------------------------------------------------------------- key decoding

pub const Key = union(enum) {
    char: u21,
    /// Submit (or continue after a trailing backslash).
    enter,
    /// A newline typed with Alt+Enter, or pasted without bracketed-paste markers.
    newline,
    tab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    esc,
    /// Ctrl+letter, as the lower-case letter.
    ctrl: u8,
    /// Bracketed paste payload, verbatim.
    paste: []const u8,
    other,
};

/// Decode one key from `src`. `src` provides:
///   `byte(wait) !?u8`  next byte; `.short` waits ~50 ms and returns null on timeout
///   `buffered() usize` bytes already read but not consumed
///   `burst: bool`      a newline was seen in the middle of this read (paste without markers)
/// A lone ESC (nothing follows within the short wait) is `.esc`. Unknown
/// sequences decode to `.other` and are consumed whole.
pub fn decodeKey(arena: std.mem.Allocator, src: anytype) !?Key {
    const b = (try src.byte(.block)) orelse return null;
    switch (b) {
        0x1b => return try decodeEscape(arena, src),
        '\r', '\n' => {
            // CRLF is one newline.
            if (b == '\r' and src.buffered() > 0) _ = src.dropIfNext('\n');
            if (src.burst or src.buffered() > 0) {
                src.burst = true;
                return .newline;
            }
            return .enter;
        },
        '\t' => return .tab,
        0x7f, 0x08 => return .backspace,
        0x01...0x07, 0x0b...0x0c, 0x0e...0x1a => return .{ .ctrl = b + 'a' - 1 },
        0x20...0x7e => return .{ .char = b },
        0xc2...0xf4 => {
            const need: usize = if (b >= 0xf0) 3 else if (b >= 0xe0) 2 else 1;
            var seq: [4]u8 = undefined;
            seq[0] = b;
            for (0..need) |k| seq[k + 1] = (try src.byte(.short)) orelse return .other;
            const cp = std.unicode.utf8Decode(seq[0 .. need + 1]) catch return .other;
            return .{ .char = cp };
        },
        else => return .other,
    }
}

fn decodeEscape(arena: std.mem.Allocator, src: anytype) !Key {
    const b = (try src.byte(.short)) orelse return .esc;
    switch (b) {
        '[' => {
            var params: [16]u8 = undefined;
            var n: usize = 0;
            while (true) {
                const c = (try src.byte(.short)) orelse return .other;
                if (c >= 0x40 and c <= 0x7e) {
                    const p = params[0..n];
                    return switch (c) {
                        'A' => .up,
                        'B' => .down,
                        'C' => .right,
                        'D' => .left,
                        'H' => .home,
                        'F' => .end,
                        '~' => csiTilde(arena, src, p),
                        else => .other,
                    };
                }
                if (n < params.len) {
                    params[n] = c;
                    n += 1;
                }
            }
        },
        'O' => {
            const c = (try src.byte(.short)) orelse return .other;
            return switch (c) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'M' => .enter,
                else => .other,
            };
        },
        '\r', '\n' => return .newline,
        else => return .other,
    }
}

fn csiTilde(arena: std.mem.Allocator, src: anytype, params: []const u8) !Key {
    const num = std.fmt.parseInt(u32, params, 10) catch return .other;
    switch (num) {
        1, 7 => return .home,
        4, 8 => return .end,
        3 => return .delete,
        200 => return .{ .paste = try readPaste(arena, src) },
        else => return .other,
    }
}

/// Everything up to the closing marker, verbatim (the opening one is consumed).
fn readPaste(arena: std.mem.Allocator, src: anytype) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    while (try src.byte(.block)) |b| {
        try out.append(arena, b);
        if (std.mem.endsWith(u8, out.items, paste_end)) {
            out.shrinkRetainingCapacity(out.items.len - paste_end.len);
            break;
        }
    }
    return out.items;
}

/// Pasted text as it enters the buffer: CR/CRLF become LF; control bytes
/// (escape sequences in particular) are dropped so a paste cannot drive the
/// terminal. Tabs and newlines survive.
pub fn sanitizePaste(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\r') {
            if (i + 1 < raw.len and raw[i + 1] == '\n') continue;
            try out.append(arena, '\n');
        } else if (c == '\n' or c == '\t' or (c >= 0x20 and c != 0x7f)) {
            try out.append(arena, c);
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- line buffer

/// The text being edited and the cursor (a byte offset on a code point boundary).
pub const Line = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,

    const gpa = std.heap.page_allocator;

    pub fn deinit(self: *Line) void {
        self.buf.deinit(gpa);
    }

    pub fn text(self: *const Line) []const u8 {
        return self.buf.items;
    }

    pub fn set(self: *Line, s: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(gpa, s);
        self.cursor = s.len;
    }

    pub fn insert(self: *Line, s: []const u8) !void {
        try self.buf.insertSlice(gpa, self.cursor, s);
        self.cursor += s.len;
    }

    fn prevBoundary(self: *const Line, from: usize) usize {
        var i = from;
        while (i > 0) {
            i -= 1;
            if ((self.buf.items[i] & 0xC0) != 0x80) break;
        }
        return i;
    }

    fn nextBoundary(self: *const Line, from: usize) usize {
        var i = from + 1;
        while (i < self.buf.items.len and (self.buf.items[i] & 0xC0) == 0x80) i += 1;
        return @min(i, self.buf.items.len);
    }

    pub fn left(self: *Line) void {
        if (self.cursor > 0) self.cursor = self.prevBoundary(self.cursor);
    }

    pub fn right(self: *Line) void {
        if (self.cursor < self.buf.items.len) self.cursor = self.nextBoundary(self.cursor);
    }

    pub fn backspace(self: *Line) void {
        if (self.cursor == 0) return;
        const start = self.prevBoundary(self.cursor);
        self.buf.replaceRangeAssumeCapacity(start, self.cursor - start, "");
        self.cursor = start;
    }

    pub fn delete(self: *Line) void {
        if (self.cursor >= self.buf.items.len) return;
        const stop = self.nextBoundary(self.cursor);
        self.buf.replaceRangeAssumeCapacity(self.cursor, stop - self.cursor, "");
    }

    fn lineStart(self: *const Line) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n')) |nl| nl + 1 else 0;
    }

    fn lineEnd(self: *const Line) usize {
        return if (std.mem.indexOfScalarPos(u8, self.buf.items, self.cursor, '\n')) |nl| nl else self.buf.items.len;
    }

    pub fn home(self: *Line) void {
        self.cursor = self.lineStart();
    }

    pub fn end(self: *Line) void {
        self.cursor = self.lineEnd();
    }

    /// Ctrl-K: to the end of the logical line; at its end, join the next line.
    pub fn killToEnd(self: *Line) void {
        const e = self.lineEnd();
        const stop = if (e == self.cursor and e < self.buf.items.len) e + 1 else e;
        self.buf.replaceRangeAssumeCapacity(self.cursor, stop - self.cursor, "");
    }

    /// Ctrl-U: back to the start of the logical line.
    pub fn killToStart(self: *Line) void {
        const s = self.lineStart();
        self.buf.replaceRangeAssumeCapacity(s, self.cursor - s, "");
        self.cursor = s;
    }

    /// Ctrl-W: the word before the cursor (whitespace-delimited).
    pub fn killWord(self: *Line) void {
        var i = self.cursor;
        while (i > 0 and isSpace(self.buf.items[i - 1])) i -= 1;
        while (i > 0 and !isSpace(self.buf.items[i - 1])) i -= 1;
        self.buf.replaceRangeAssumeCapacity(i, self.cursor - i, "");
        self.cursor = i;
    }

    /// A trailing backslash means "continue on the next line": drop it and
    /// start a new line. False when the buffer does not end with one.
    pub fn continueAfterBackslash(self: *Line) !bool {
        const items = self.buf.items;
        if (items.len == 0 or items[items.len - 1] != '\\') return false;
        self.buf.shrinkRetainingCapacity(items.len - 1);
        try self.buf.append(gpa, '\n');
        self.cursor = self.buf.items.len;
        return true;
    }
};

// ---------------------------------------------------------------- layout

pub fn displayWidth(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}

pub const Layout = struct {
    /// Rows below the first one where the output ends / where the cursor goes.
    end_row: usize = 0,
    end_col: usize = 0,
    cur_row: usize = 0,
    cur_col: usize = 0,
};

/// Append the bytes that draw `prompt` + `text` (continuation lines indented
/// to the prompt's width) and return where the output ends and where the
/// cursor belongs. Every wrap is made explicit (" \r" after the last column)
/// so the terminal's deferred-wrap state never makes the row count ambiguous.
/// Tabs draw as four spaces. Wide (CJK) glyphs are counted as one column.
pub fn drawText(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), prompt: []const u8, text: []const u8, cursor: usize, width: usize) !Layout {
    const w = @max(width, 8);
    const pw = displayWidth(prompt);
    var l = Layout{};
    var row: usize = 0;
    var col: usize = 0;
    try out.appendSlice(a, prompt);
    col = pw % w;
    row = pw / w;

    var i: usize = 0;
    while (i < text.len) {
        if (i == cursor) {
            l.cur_row = row;
            l.cur_col = col;
        }
        const c = text[i];
        if (c == '\n') {
            try out.appendSlice(a, "\r\n");
            row += 1;
            try out.appendNTimes(a, ' ', pw);
            col = pw % w;
            row += pw / w;
            i += 1;
            continue;
        }
        const seq_len: usize = if (c < 0x80) 1 else if (c >= 0xf0) 4 else if (c >= 0xe0) 3 else if (c >= 0xc0) 2 else 1;
        const take = @min(seq_len, text.len - i);
        const cells: usize = if (c == '\t') 4 else 1;
        for (0..cells) |_| {
            if (c == '\t') try out.append(a, ' ') else try out.appendSlice(a, text[i .. i + take]);
            col += 1;
            if (col == w) {
                try out.appendSlice(a, " \r");
                row += 1;
                col = 0;
            }
        }
        i += take;
    }
    if (cursor >= text.len) {
        l.cur_row = row;
        l.cur_col = col;
    }
    l.end_row = row;
    l.end_col = col;
    return l;
}

// ---------------------------------------------------------------- completion

/// Longest common prefix of `items`.
pub fn commonPrefix(items: []const []const u8) []const u8 {
    if (items.len == 0) return "";
    var n = items[0].len;
    for (items[1..]) |s| {
        var k: usize = 0;
        while (k < n and k < s.len and s[k] == items[0][k]) k += 1;
        n = k;
    }
    return items[0][0..n];
}

/// Slash-command names (with the leading `/`) that start with `token`.
pub fn completeCommand(arena: std.mem.Allocator, commands: []const []const u8, token: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (token.len == 0 or token[0] != '/') return out.items;
    for (commands) |name| {
        if (std.mem.startsWith(u8, name, token[1..])) try out.append(arena, try std.fmt.allocPrint(arena, "/{s}", .{name}));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const skip_dirs = [_][]const u8{ ".git", "zig-out", "zig-cache", ".zig-cache" };
const max_complete_depth = 6;
const max_candidates = 200;

/// Entries of the directory named by `path_prefix` (the text after `@`) whose
/// names start with the last component. Directories end with `/`. Only the one
/// directory is read, never deeper than six levels, never `.git` or build
/// output, and dot-files only when the prefix itself starts with a dot.
pub fn completePath(arena: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path_prefix: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.mem.startsWith(u8, path_prefix, "/") or std.mem.indexOf(u8, path_prefix, "..") != null) return out.items;
    const slash = std.mem.lastIndexOfScalar(u8, path_prefix, '/');
    const dir_part = if (slash) |s| path_prefix[0 .. s + 1] else "";
    const leaf = if (slash) |s| path_prefix[s + 1 ..] else path_prefix;
    if (std.mem.count(u8, dir_part, "/") > max_complete_depth) return out.items;

    var dir = cwd.openDir(io, if (dir_part.len == 0) "." else dir_part, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, leaf)) continue;
        if (entry.name[0] == '.' and !(leaf.len > 0 and leaf[0] == '.')) continue;
        const skipped = for (skip_dirs) |s| {
            if (std.mem.eql(u8, s, entry.name)) break true;
        } else false;
        if (skipped) continue;
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir_part, entry.name, suffix }));
        if (out.items.len >= max_candidates) break;
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// Start of the whitespace-delimited token that ends at `cursor`.
pub fn tokenStart(text: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0 and !isSpace(text[i - 1])) i -= 1;
    return i;
}

// ---------------------------------------------------------------- terminal editor

pub const Completions = struct {
    /// Slash-command names without the slash (the REPL's `commands`).
    commands: []const []const u8 = &.{},
};

/// May the editor be used? A real terminal on stdin and stderr, and a TERM
/// that understands the escapes. Otherwise the caller keeps its line reader.
pub fn usable(io: std.Io, environ: *const std.process.Environ.Map) bool {
    if (builtin.os.tag == .windows) return false;
    const term = environ.get("TERM") orelse return false;
    if (term.len == 0 or std.mem.eql(u8, term, "dumb")) return false;
    const in_tty = std.Io.File.stdin().isTty(io) catch false;
    const err_tty = std.Io.File.stderr().isTty(io) catch false;
    return in_tty and err_tty;
}

const Wait = enum { block, short };

/// Bytes from fd 0, one read at a time, with the lookahead the decoder needs.
const Input = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    /// A newline was seen with more bytes behind it in the same read.
    burst: bool = false,

    fn buffered(self: *const Input) usize {
        return self.len - self.pos;
    }

    fn dropIfNext(self: *Input, c: u8) bool {
        if (self.pos < self.len and self.buf[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn byte(self: *Input, wait: Wait) !?u8 {
        if (self.pos >= self.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, if (wait == .short) 50 else -1) catch return error.ReadFailed;
            if (ready == 0) return null;
            const n = std.posix.read(0, &self.buf) catch return error.ReadFailed;
            if (n == 0) return error.EndOfStream;
            self.len = n;
            self.pos = 0;
            self.burst = false;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }
};

pub const Editor = struct {
    io: std.Io,
    /// Owns returned lines and history entries.
    arena: std.mem.Allocator,
    history: History = .{},
    history_path: ?[]const u8,
    completions: Completions,
    line: Line = .{},
    input: Input = .{},
    nav: HistoryNav = .{},
    saved_termios: ?std.posix.termios = null,
    old_sigint: ?std.posix.Sigaction = null,
    /// Cursor row of the last frame, relative to the prompt's first row.
    prev_cursor_row: usize = 0,
    last_layout: Layout = .{},
    frame: std.ArrayListUnmanaged(u8) = .empty,

    const gpa = std.heap.page_allocator;

    pub fn init(io: std.Io, arena: std.mem.Allocator, history_path: ?[]const u8, completions: Completions) Editor {
        var e = Editor{ .io = io, .arena = arena, .history_path = history_path, .completions = completions };
        if (history_path) |p| {
            if (fsutil.readSmallFile(std.Io.Dir.cwd(), io, arena, p, max_history_bytes)) |text| {
                e.history = History.parse(arena, text) catch .{};
            } else |_| {}
        }
        return e;
    }

    pub fn deinit(self: *Editor) void {
        self.leave();
        self.line.deinit();
        self.frame.deinit(gpa);
    }

    // ---- terminal state ----

    fn write(self: *Editor, bytes: []const u8) void {
        std.Io.File.stderr().writeStreamingAll(self.io, bytes) catch {};
    }

    /// Raw mode on, SIGINT ignored (Ctrl-C arrives as a key), bracketed paste on.
    fn enter(self: *Editor) !void {
        if (self.saved_termios != null) return;
        const t = std.posix.tcgetattr(0) catch return error.NotATerminal;
        var raw = t;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(0, .NOW, raw) catch return error.NotATerminal;
        self.saved_termios = t;

        var old: std.posix.Sigaction = undefined;
        const ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &ignore, &old);
        self.old_sigint = old;
        self.write("\x1b[?2004h");
    }

    /// Undo everything `enter` did. Safe to call twice.
    fn leave(self: *Editor) void {
        const t = self.saved_termios orelse return;
        self.write("\x1b[?2004l\x1b[?25h");
        std.posix.tcsetattr(0, .NOW, t) catch {};
        if (self.old_sigint) |old| std.posix.sigaction(.INT, &old, null);
        self.old_sigint = null;
        self.saved_termios = null;
    }

    fn termWidth(self: *const Editor) usize {
        _ = self;
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(2, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.col == 0) return 80;
        return ws.col;
    }

    // ---- drawing ----

    /// Redraw `prompt` + `text` with the cursor at `cursor`, replacing the
    /// previous frame. One write per frame.
    fn draw(self: *Editor, prompt: []const u8, text: []const u8, cursor: usize) void {
        self.frame.clearRetainingCapacity();
        if (self.prev_cursor_row > 0) self.frame.print(gpa, "\x1b[{d}A", .{self.prev_cursor_row}) catch return;
        self.frame.appendSlice(gpa, "\r\x1b[J") catch return;
        const l = drawText(gpa, &self.frame, prompt, text, cursor, self.termWidth()) catch return;
        if (l.end_row > l.cur_row) self.frame.print(gpa, "\x1b[{d}A", .{l.end_row - l.cur_row}) catch return;
        self.frame.append(gpa, '\r') catch return;
        if (l.cur_col > 0) self.frame.print(gpa, "\x1b[{d}C", .{l.cur_col}) catch return;
        self.write(self.frame.items);
        self.prev_cursor_row = l.cur_row;
        self.last_layout = l;
    }

    /// Park the cursor after the text and start a fresh line.
    fn finishFrame(self: *Editor) void {
        var buf: [32]u8 = undefined;
        const down = self.last_layout.end_row - self.last_layout.cur_row;
        if (down > 0) self.write(std.fmt.bufPrint(&buf, "\x1b[{d}B", .{down}) catch "");
        self.write("\r\n");
        self.prev_cursor_row = 0;
    }

    // ---- the prompt ----

    /// Read one (possibly multi-line) entry. Null on end of input (Ctrl-D on
    /// an empty line, or stdin closed). The result is owned by the arena.
    /// Ctrl-C on an empty line restores the terminal and exits 130.
    pub fn readLine(self: *Editor, prompt: []const u8) !?[]const u8 {
        try self.enter();
        defer self.leave();
        self.line.buf.clearRetainingCapacity();
        self.line.cursor = 0;
        self.nav = .{};
        self.prev_cursor_row = 0;
        self.draw(prompt, self.line.text(), self.line.cursor);

        while (true) {
            const maybe_key = decodeKey(self.arena, &self.input) catch |err| switch (err) {
                error.EndOfStream => {
                    self.finishFrame();
                    return null;
                },
                else => return err,
            };
            const key = maybe_key orelse continue;

            switch (key) {
                .enter => {
                    if (try self.line.continueAfterBackslash()) {} else {
                        self.finishFrame();
                        const result = try self.arena.dupe(u8, self.line.text());
                        self.remember(result);
                        return result;
                    }
                },
                .newline => try self.line.insert("\n"),
                .char => |cp| {
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch continue;
                    try self.line.insert(enc[0..n]);
                },
                .paste => |raw| try self.line.insert(try sanitizePaste(self.arena, raw)),
                .backspace => self.line.backspace(),
                .delete => self.line.delete(),
                .left => self.line.left(),
                .right => self.line.right(),
                .home => self.line.home(),
                .end => self.line.end(),
                .up => if (self.nav.older(&self.history, self.line.text())) |t| try self.line.set(t),
                .down => if (self.nav.newer(&self.history)) |t| try self.line.set(t),
                .tab => try self.complete(prompt),
                .esc, .other => {},
                .ctrl => |c| switch (c) {
                    'a' => self.line.home(),
                    'e' => self.line.end(),
                    'b' => self.line.left(),
                    'f' => self.line.right(),
                    'k' => self.line.killToEnd(),
                    'u' => self.line.killToStart(),
                    'w' => self.line.killWord(),
                    'l' => {
                        self.write("\x1b[H\x1b[2J");
                        self.prev_cursor_row = 0;
                    },
                    'd' => {
                        if (self.line.text().len == 0) {
                            self.finishFrame();
                            return null;
                        }
                        self.line.delete();
                    },
                    'c' => {
                        if (self.line.text().len == 0) {
                            self.finishFrame();
                            self.leave();
                            std.process.exit(130);
                        }
                        self.write("^C");
                        self.line.buf.clearRetainingCapacity();
                        self.line.cursor = 0;
                        self.nav = .{};
                    },
                    'r' => if (try self.reverseSearch(prompt)) |k| {
                        // A key that ended the search and still needs handling
                        // is rare (arrows); drop it, the line is already accepted.
                        _ = k;
                    },
                    else => {},
                },
            }
            self.draw(prompt, self.line.text(), self.line.cursor);
        }
    }

    fn remember(self: *Editor, line: []const u8) void {
        if (!History.recordable(line)) return;
        self.history.push(self.arena, line) catch return;
        self.saveHistory();
    }

    /// Atomic write, mode 0600. Failure is silent: history is a convenience.
    fn saveHistory(self: *Editor) void {
        const path = self.history_path orelse return;
        const cwd = std.Io.Dir.cwd();
        const text = self.history.serialize(self.arena) catch return;
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| cwd.createDirPath(self.io, path[0..slash]) catch return;
        fsutil.atomicWriteFile(cwd, self.io, self.arena, path, text) catch return;
        const f = cwd.openFile(self.io, path, .{ .mode = .read_write }) catch return;
        defer f.close(self.io);
        f.setPermissions(self.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    }

    // ---- Ctrl-R ----

    /// Incremental reverse search. Enter accepts the match into the line;
    /// Ctrl-C or ESC puts the original line back. Returns a key that ended
    /// the search without being consumed by it.
    fn reverseSearch(self: *Editor, normal_prompt: []const u8) !?Key {
        const original = try self.arena.dupe(u8, self.line.text());
        const original_cursor = self.line.cursor;
        var query: std.ArrayListUnmanaged(u8) = .empty;
        defer query.deinit(gpa);
        var found: ?usize = null;
        var ended: ?Key = null;

        while (true) {
            const shown = if (found) |i| self.history.entries.items[i] else "";
            const hit_at = if (found != null) std.mem.indexOf(u8, shown, query.items) orelse 0 else 0;
            const label = try std.fmt.allocPrint(self.arena, "({s}reverse-i-search)`{s}': ", .{ if (found == null and query.items.len > 0) "failing " else "", query.items });
            self.draw(label, shown, hit_at);

            const key = (decodeKey(self.arena, &self.input) catch break) orelse continue;
            switch (key) {
                .enter => {
                    if (found) |i| try self.line.set(self.history.entries.items[i]);
                    break;
                },
                .ctrl => |c| switch (c) {
                    'r' => found = self.history.searchBack(query.items, found orelse self.history.entries.items.len) orelse found,
                    'c', 'g' => {
                        try self.line.set(original);
                        self.line.cursor = original_cursor;
                        break;
                    },
                    else => {
                        if (found) |i| try self.line.set(self.history.entries.items[i]);
                        ended = key;
                        break;
                    },
                },
                .esc => {
                    try self.line.set(original);
                    self.line.cursor = original_cursor;
                    break;
                },
                .char => |cp| {
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch continue;
                    try query.appendSlice(gpa, enc[0..n]);
                    found = self.history.searchBack(query.items, self.history.entries.items.len);
                },
                .backspace => {
                    if (query.items.len > 0) {
                        var k = query.items.len - 1;
                        while (k > 0 and (query.items[k] & 0xC0) == 0x80) k -= 1;
                        query.shrinkRetainingCapacity(k);
                        found = self.history.searchBack(query.items, self.history.entries.items.len);
                    }
                },
                else => {
                    if (found) |i| try self.line.set(self.history.entries.items[i]);
                    ended = key;
                    break;
                },
            }
        }
        self.draw(normal_prompt, self.line.text(), self.line.cursor);
        return ended;
    }

    // ---- Tab ----

    /// Complete `/command` (first token) or `@path` (any token). Anything
    /// else, including `!` lines, is left alone and reads no files.
    fn complete(self: *Editor, prompt: []const u8) !void {
        const text = self.line.text();
        if (text.len > 0 and text[0] == '!') return;
        const start = tokenStart(text, self.line.cursor);
        const token = text[start..self.line.cursor];

        var candidates: []const []const u8 = &.{};
        var prefix_len: usize = 0; // bytes of `token` kept in front of the candidates
        if (start == 0 and token.len > 0 and token[0] == '/') {
            candidates = try completeCommand(self.arena, self.completions.commands, token);
        } else if (token.len > 0 and token[0] == '@') {
            candidates = try completePath(self.arena, self.io, std.Io.Dir.cwd(), token[1..]);
            prefix_len = 1;
        } else return;
        if (candidates.len == 0) return;

        const common = commonPrefix(candidates);
        const replacement = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ token[0..prefix_len], common });
        if (replacement.len > token.len) {
            self.line.cursor = start;
            self.line.buf.replaceRangeAssumeCapacity(start, token.len, "");
            try self.line.insert(replacement);
        }
        if (candidates.len > 1) {
            self.draw(prompt, self.line.text(), self.line.cursor);
            self.finishFrame();
            var list: std.ArrayListUnmanaged(u8) = .empty;
            for (candidates) |c| try list.print(self.arena, "{s}  ", .{c});
            try list.appendSlice(self.arena, "\r\n");
            self.write(list.items);
        }
    }
};

// ---------------------------------------------------------------- tests

const ts = std.testing;

/// A byte source over a fixed slice for key-decoding tests. A timeout (`.short`
/// at the end of the data) returns null, as a real quiet terminal would.
const FakeInput = struct {
    data: []const u8,
    pos: usize = 0,
    burst: bool = false,

    fn byte(self: *FakeInput, wait: Wait) !?u8 {
        if (self.pos >= self.data.len) {
            if (wait == .short) return null;
            return error.EndOfStream;
        }
        defer self.pos += 1;
        return self.data[self.pos];
    }

    fn buffered(self: *const FakeInput) usize {
        return self.data.len - self.pos;
    }

    fn dropIfNext(self: *FakeInput, c: u8) bool {
        if (self.pos < self.data.len and self.data[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

fn keyOf(arena: std.mem.Allocator, bytes: []const u8) !Key {
    var src = FakeInput{ .data = bytes };
    return (try decodeKey(arena, &src)).?;
}

test "editor: CSI and SS3 sequences decode to keys" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try ts.expectEqual(Key.up, try keyOf(a, "\x1b[A"));
    try ts.expectEqual(Key.down, try keyOf(a, "\x1b[B"));
    try ts.expectEqual(Key.right, try keyOf(a, "\x1b[C"));
    try ts.expectEqual(Key.left, try keyOf(a, "\x1b[D"));
    try ts.expectEqual(Key.home, try keyOf(a, "\x1b[H"));
    try ts.expectEqual(Key.end, try keyOf(a, "\x1b[F"));
    try ts.expectEqual(Key.home, try keyOf(a, "\x1b[1~"));
    try ts.expectEqual(Key.end, try keyOf(a, "\x1b[4~"));
    try ts.expectEqual(Key.delete, try keyOf(a, "\x1b[3~"));
    // Modifier parameters do not change the direction.
    try ts.expectEqual(Key.right, try keyOf(a, "\x1b[1;5C"));
    // SS3 (application cursor mode).
    try ts.expectEqual(Key.up, try keyOf(a, "\x1bOA"));
    try ts.expectEqual(Key.home, try keyOf(a, "\x1bOH"));
    try ts.expectEqual(Key.end, try keyOf(a, "\x1bOF"));
    // Unknown sequences are swallowed whole.
    var src = FakeInput{ .data = "\x1b[99Zx" };
    try ts.expectEqual(Key.other, (try decodeKey(a, &src)).?);
    try ts.expectEqual(Key{ .char = 'x' }, (try decodeKey(a, &src)).?);
}

test "editor: a lone ESC times out as ESC, ESC CR is Alt+Enter" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try ts.expectEqual(Key.esc, try keyOf(a, "\x1b"));
    try ts.expectEqual(Key.newline, try keyOf(a, "\x1b\r"));
}

test "editor: plain keys, control keys and UTF-8" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try ts.expectEqual(Key{ .char = 'a' }, try keyOf(a, "a"));
    try ts.expectEqual(Key{ .char = 0xe9 }, try keyOf(a, "\xc3\xa9"));
    try ts.expectEqual(Key{ .char = 0x20ac }, try keyOf(a, "\xe2\x82\xac"));
    try ts.expectEqual(Key{ .ctrl = 'a' }, try keyOf(a, "\x01"));
    try ts.expectEqual(Key{ .ctrl = 'r' }, try keyOf(a, "\x12"));
    try ts.expectEqual(Key.backspace, try keyOf(a, "\x7f"));
    try ts.expectEqual(Key.tab, try keyOf(a, "\t"));
    try ts.expectEqual(Key.enter, try keyOf(a, "\r"));
    try ts.expectEqual(Key.enter, try keyOf(a, "\n"));
}

test "editor: bracketed paste is verbatim, a burst with a newline inserts newlines" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    // Keys inside the markers are not interpreted: \x1b[A and \r stay text.
    const k = try keyOf(a, "\x1b[200~line1\r\nline2\x1b[A\x03\x1b[201~");
    try ts.expectEqualStrings("line1\r\nline2\x1b[A\x03", k.paste);
    try ts.expectEqualStrings("line1\nline2", try sanitizePaste(a, "line1\r\nline2\x1b[A\x03"[0..12]));
    try ts.expectEqualStrings("a\nb\tc", try sanitizePaste(a, "a\rb\tc"));
    try ts.expectEqualStrings("[31mred", try sanitizePaste(a, "\x1b[31mred"));

    // Without markers: "a\nb\n" arriving in one read. The first newline has
    // bytes behind it, so the burst is a paste and the final newline stays text.
    var src = FakeInput{ .data = "a\nb\n" };
    try ts.expectEqual(Key{ .char = 'a' }, (try decodeKey(a, &src)).?);
    try ts.expectEqual(Key.newline, (try decodeKey(a, &src)).?);
    try ts.expectEqual(Key{ .char = 'b' }, (try decodeKey(a, &src)).?);
    try ts.expectEqual(Key.newline, (try decodeKey(a, &src)).?);
    // "echo hi\r" in one read still submits: nothing follows the newline.
    var typed = FakeInput{ .data = "hi\r" };
    _ = try decodeKey(a, &typed);
    _ = try decodeKey(a, &typed);
    try ts.expectEqual(Key.enter, (try decodeKey(a, &typed)).?);
}

test "editor: line buffer edits at code point boundaries" {
    var l = Line{};
    defer l.deinit();
    try l.insert("h\xc3\xa9llo");
    try ts.expectEqual(@as(usize, 6), l.cursor);
    l.left();
    l.left();
    l.left();
    l.left(); // before "é"
    try ts.expectEqual(@as(usize, 1), l.cursor);
    l.right(); // over the two-byte é
    try ts.expectEqual(@as(usize, 3), l.cursor);
    l.backspace(); // removes é whole
    try ts.expectEqualStrings("hllo", l.text());
    l.delete();
    try ts.expectEqualStrings("hlo", l.text());
    l.home();
    try ts.expectEqual(@as(usize, 0), l.cursor);
    l.backspace(); // no-op at the start
    l.end();
    l.delete(); // no-op at the end
    try ts.expectEqualStrings("hlo", l.text());
}

test "editor: kill commands work on words and logical lines" {
    var l = Line{};
    defer l.deinit();
    try l.insert("one two  three");
    l.killWord();
    try ts.expectEqualStrings("one two  ", l.text());
    l.killWord();
    try ts.expectEqualStrings("one ", l.text());

    try l.set("first\nsecond line");
    l.cursor = 9; // inside "second"
    l.killToEnd();
    try ts.expectEqualStrings("first\nsec", l.text());
    l.killToStart();
    try ts.expectEqualStrings("first\n", l.text());
    l.cursor = 5; // end of "first": Ctrl-K joins the next line
    try l.set("ab\ncd");
    l.cursor = 2;
    l.killToEnd();
    try ts.expectEqualStrings("abcd", l.text());
}

test "editor: home and end act on the logical line" {
    var l = Line{};
    defer l.deinit();
    try l.set("aa\nbbb\ncc");
    l.cursor = 5;
    l.home();
    try ts.expectEqual(@as(usize, 3), l.cursor);
    l.end();
    try ts.expectEqual(@as(usize, 6), l.cursor);
}

test "editor: trailing backslash continues the line and is removed" {
    var l = Line{};
    defer l.deinit();
    try l.insert("echo a \\");
    try ts.expect(try l.continueAfterBackslash());
    try ts.expectEqualStrings("echo a \n", l.text());
    try ts.expectEqual(@as(usize, 8), l.cursor);
    try ts.expect(!(try l.continueAfterBackslash()));
}

test "editor: layout indents continuation lines and wraps at the width" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ts.allocator);
    const l = try drawText(ts.allocator, &out, "> ", "ab\ncd", 5, 80);
    try ts.expectEqualStrings("> ab\r\n  cd", out.items);
    try ts.expectEqual(@as(usize, 1), l.end_row);
    try ts.expectEqual(@as(usize, 4), l.end_col);
    try ts.expectEqual(@as(usize, 1), l.cur_row);
    try ts.expectEqual(@as(usize, 4), l.cur_col);

    // Cursor in the middle of the first line.
    out.clearRetainingCapacity();
    const m = try drawText(ts.allocator, &out, "> ", "ab\ncd", 1, 80);
    try ts.expectEqual(@as(usize, 0), m.cur_row);
    try ts.expectEqual(@as(usize, 3), m.cur_col);
    try ts.expectEqual(@as(usize, 1), m.end_row);

    // 8 columns: "> " + 6 chars fills the row; the wrap is explicit.
    out.clearRetainingCapacity();
    const w = try drawText(ts.allocator, &out, "> ", "abcdefgh", 8, 8);
    try ts.expectEqualStrings("> abcdef \rgh", out.items);
    try ts.expectEqual(@as(usize, 1), w.end_row);
    try ts.expectEqual(@as(usize, 2), w.end_col);
}

test "editor: history walk keeps the unedited draft" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    var h = History{};
    try h.push(a, "first");
    try h.push(a, "second");
    var nav = HistoryNav{};
    try ts.expectEqualStrings("second", nav.older(&h, "draft text").?);
    try ts.expectEqualStrings("first", nav.older(&h, "ignored").?);
    try ts.expect(nav.older(&h, "ignored") == null); // oldest reached
    try ts.expectEqualStrings("second", nav.newer(&h).?);
    try ts.expectEqualStrings("draft text", nav.newer(&h).?); // back to the draft
    try ts.expect(nav.newer(&h) == null);
    var empty = HistoryNav{};
    try ts.expect(empty.older(&History{}, "x") == null);
}

test "editor: reverse search walks further back on each repeat" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    var h = History{};
    for ([_][]const u8{ "zig build", "ls", "zig test", "git status" }) |e| try h.push(a, e);
    const first = h.searchBack("zig", h.entries.items.len).?;
    try ts.expectEqualStrings("zig test", h.entries.items[first]);
    const second = h.searchBack("zig", first).?;
    try ts.expectEqualStrings("zig build", h.entries.items[second]);
    try ts.expect(h.searchBack("zig", second) == null);
    try ts.expect(h.searchBack("nomatch", 4) == null);
    try ts.expect(h.searchBack("", 4) == null);
}

test "editor: completion helpers" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try ts.expectEqualStrings("us", commonPrefix(&.{ "usage", "user" }));
    try ts.expectEqualStrings("", commonPrefix(&.{}));
    try ts.expectEqualStrings("only", commonPrefix(&.{"only"}));
    try ts.expectEqual(@as(usize, 3), tokenStart("ab cd", 5));
    try ts.expectEqual(@as(usize, 0), tokenStart("@src/ma", 7));

    const cmds = [_][]const u8{ "usage", "undo", "help", "quit" };
    const u = try completeCommand(a, &cmds, "/u");
    try ts.expectEqual(@as(usize, 2), u.len);
    try ts.expectEqualStrings("/undo", u[0]);
    try ts.expectEqualStrings("/usage", u[1]);
    const one = try completeCommand(a, &cmds, "/us");
    try ts.expectEqual(@as(usize, 1), one.len);
    try ts.expectEqualStrings("/usage", one[0]);
    try ts.expectEqual(@as(usize, 0), (try completeCommand(a, &cmds, "us")).len); // no slash: not a command
    try ts.expectEqual(@as(usize, 4), (try completeCommand(a, &cmds, "/")).len);
}

test "editor: @ path completion reads one directory, skips build dirs and hidden files" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try tmp.dir.createDirPath(io, "src/core");
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/make.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.hidden", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "" });

    const ma = try completePath(a, io, tmp.dir, "src/ma");
    try ts.expectEqual(@as(usize, 2), ma.len);
    try ts.expectEqualStrings("src/main.zig", ma[0]);
    try ts.expectEqualStrings("src/make.zig", ma[1]);

    const dirs = try completePath(a, io, tmp.dir, "sr");
    try ts.expectEqual(@as(usize, 1), dirs.len);
    try ts.expectEqualStrings("src/", dirs[0]); // directories end with a slash

    const all = try completePath(a, io, tmp.dir, "");
    for (all) |name| {
        try ts.expect(!std.mem.startsWith(u8, name, ".git"));
        try ts.expect(!std.mem.startsWith(u8, name, "zig-out"));
    }
    try ts.expectEqual(@as(usize, 2), all.len); // README.md and src/

    try ts.expectEqual(@as(usize, 1), (try completePath(a, io, tmp.dir, "src/.h")).len);
    try ts.expectEqual(@as(usize, 0), (try completePath(a, io, tmp.dir, "../")).len);
    try ts.expectEqual(@as(usize, 0), (try completePath(a, io, tmp.dir, "/etc/")).len);
    try ts.expectEqual(@as(usize, 0), (try completePath(a, io, tmp.dir, "a/b/c/d/e/f/g/h")).len); // too deep
}

test "history: serialize and parse round-trip, escapes and the 500 bound" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    var h = History{};
    try h.push(a, "plain");
    try h.push(a, "multi\nline\\ with backslash");
    try h.push(a, "plain");
    const text = try h.serialize(a);
    try ts.expectEqualStrings("plain\nmulti\\nline\\\\ with backslash\nplain\n", text);
    const back = try History.parse(a, text);
    try ts.expectEqual(@as(usize, 3), back.entries.items.len);
    try ts.expectEqualStrings("multi\nline\\ with backslash", back.entries.items[1]);

    // Bound: only the newest 500 survive, in order.
    var big = History{};
    for (0..650) |n| try big.push(a, try std.fmt.allocPrint(a, "cmd {d}", .{n}));
    try ts.expectEqual(@as(usize, max_history), big.entries.items.len);
    try ts.expectEqualStrings("cmd 150", big.entries.items[0]);
    try ts.expectEqualStrings("cmd 649", big.entries.items[max_history - 1]);
    const reread = try History.parse(a, try big.serialize(a));
    try ts.expectEqual(@as(usize, max_history), reread.entries.items.len);
    // A longer file on disk is cut to the bound on load too.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    for (0..700) |n| try long.print(a, "line {d}\n", .{n});
    const cut = try History.parse(a, long.items);
    try ts.expectEqual(@as(usize, max_history), cut.entries.items.len);
    try ts.expectEqualStrings("line 200", cut.entries.items[0]);
}

test "history: duplicates collapse, blanks and secrets are not recorded" {
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    var h = History{};
    try h.push(a, "ls");
    try h.push(a, "ls");
    try h.push(a, "   ");
    try h.push(a, "");
    try h.push(a, "/provider key OPENAI_API_KEY sk-secret");
    try h.push(a, "pwd");
    try h.push(a, "ls");
    try ts.expectEqual(@as(usize, 3), h.entries.items.len);
    try ts.expectEqualStrings("ls", h.entries.items[0]);
    try ts.expectEqualStrings("pwd", h.entries.items[1]);
    try ts.expectEqualStrings("ls", h.entries.items[2]);
}

test "history: file is written 0600 and reloaded" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    var e = Editor.init(io, a, null, .{});
    defer e.line.deinit();
    // saveHistory targets an absolute path; build one inside the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const path = try std.fmt.allocPrint(a, "{s}/state/history", .{path_buf[0..dir_len]});
    e.history_path = path;
    e.remember("first command");
    e.remember("second\nline");
    const st_file = try tmp.dir.statFile(io, "state/history", .{});
    try ts.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st_file.permissions.toMode() & 0o777)));
    var reloaded = Editor.init(io, a, path, .{});
    defer reloaded.line.deinit();
    try ts.expectEqual(@as(usize, 2), reloaded.history.entries.items.len);
    try ts.expectEqualStrings("second\nline", reloaded.history.entries.items[1]);
}

test "shell escape: classification of bang lines" {
    try ts.expectEqualStrings("echo hi", parseShellEscape("!echo hi").?);
    try ts.expectEqualStrings("echo hi", parseShellEscape("  ! echo hi \n").?);
    try ts.expectEqualStrings("ls -la", parseShellEscape("!ls -la").?);
    try ts.expect(parseShellEscape("echo !hi") == null);
    try ts.expect(parseShellEscape("hello world") == null);
    try ts.expect(parseShellEscape("") == null);
    try ts.expect(parseShellEscape("/help") == null);
    try ts.expect(parseShellEscape("@file !x") == null);
    // Bare bang: still a shell line, with nothing to run.
    try ts.expectEqualStrings("", parseShellEscape("!").?);
    // A multi-line buffer runs everything after the bang as one command.
    try ts.expectEqualStrings("echo a\necho b", parseShellEscape("!echo a\necho b").?);
}

fn expandOk(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, line: []const u8, max: usize) ![]const u8 {
    return switch (try expandAtMentions(arena, io, dir, line, max)) {
        .ok => |s| s,
        .failed => |f| {
            std.debug.print("unexpected failure: {s}: {s}\n", .{ f.path, f.reason });
            return error.TestUnexpectedResult;
        },
    };
}

test "expandAt: attaches a mentioned file after the text" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes", .data = "n" });

    const got = try expandOk(a, io, tmp.dir, "explain @src/a.zig, please", 1000);
    try ts.expectEqualStrings("explain src/a.zig, please\n\n<file path=\"src/a.zig\">\nconst a = 1;\n\n</file>", got);

    // Two files, in order of mention; a repeated mention attaches once.
    const two = try expandOk(a, io, tmp.dir, "@src/a.zig vs @notes and @src/a.zig", 1000);
    try ts.expect(std.mem.startsWith(u8, two, "src/a.zig vs notes and src/a.zig\n"));
    try ts.expectEqual(@as(usize, 2), std.mem.count(u8, two, "<file path="));
    try ts.expect(std.mem.indexOf(u8, two, "<file path=\"src/a.zig\">").? < std.mem.indexOf(u8, two, "<file path=\"notes\">").?);
}

test "expandAt: bare at-signs, plain words and mid-word at-signs are left alone" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try ts.expectEqualStrings("a @ b", try expandOk(a, io, tmp.dir, "a @ b", 100));
    try ts.expectEqualStrings("hi @alice", try expandOk(a, io, tmp.dir, "hi @alice", 100));
    try ts.expectEqualStrings("mail me@example.com", try expandOk(a, io, tmp.dir, "mail me@example.com", 100));
    try ts.expectEqualStrings("@", try expandOk(a, io, tmp.dir, "@", 100));
    // A word with no dot or slash attaches only when the file exists.
    try tmp.dir.writeFile(io, .{ .sub_path = "Makefile", .data = "all:\n" });
    const mk = try expandOk(a, io, tmp.dir, "see @Makefile", 100);
    try ts.expect(std.mem.indexOf(u8, mk, "<file path=\"Makefile\">\nall:\n\n</file>") != null);
}

test "expandAt: missing files fail with the reason and path" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    const r = try expandAtMentions(a, io, tmp.dir, "look at @nope/missing.zig now", 100);
    try ts.expectEqualStrings("nope/missing.zig", r.failed.path);
    try ts.expectEqualStrings("FileNotFound", r.failed.reason);

    try tmp.dir.createDirPath(io, "dir.d");
    const d = try expandAtMentions(a, io, tmp.dir, "@dir.d", 100);
    try ts.expectEqualStrings("is a directory", d.failed.reason);

    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "ab\x00cd" });
    const b = try expandAtMentions(a, io, tmp.dir, "@bin.dat", 100);
    try ts.expectEqualStrings("binary file", b.failed.reason);
}

test "expandAt: contents are truncated at max_bytes on a UTF-8 boundary" {
    const io = ts.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var st = std.heap.ArenaAllocator.init(ts.allocator);
    defer st.deinit();
    const a = st.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = "0123456789" });
    const got = try expandOk(a, io, tmp.dir, "@big.txt", 4);
    try ts.expect(std.mem.indexOf(u8, got, "<file path=\"big.txt\">\n0123\n... (truncated)\n</file>") != null);

    // Exactly at the limit: not truncated.
    const exact = try expandOk(a, io, tmp.dir, "@big.txt", 10);
    try ts.expect(std.mem.indexOf(u8, exact, "truncated") == null);

    // A cut that would split "é" backs off to the character boundary.
    try tmp.dir.writeFile(io, .{ .sub_path = "u.txt", .data = "ab\xc3\xa9cd" });
    const u = try expandOk(a, io, tmp.dir, "@u.txt", 3);
    try ts.expect(std.mem.indexOf(u8, u, "\nab\n... (truncated)") != null);
    try ts.expect(std.unicode.utf8ValidateSlice(u));
}
