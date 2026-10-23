//! Streaming-safe markdown rendering for assistant text (C-07).
//!
//! The renderer takes the raw markdown source and only emits complete lines:
//! a partial line stays buffered, so a chunk that splits `**bold**`, a code
//! fence, or a heading never corrupts the output. Fenced code is held until
//! the fence line itself is complete, then highlighted lightly.
//!
//! Width is the visible terminal columns. A width change re-renders the
//! current assistant message and repaints it (ANSI cursor-up + clear) when
//! colour/TTY output is enabled. Non-TTY output stays plain and unwrapped.
//! `--json`/headless callers never use this module.

const std = @import("std");
const style_mod = @import("style.zig");

const Style = enum {
    none,
    bold,
    inline_code,
    heading,
    bullet,
    comment,
    string,
    keyword,
    number,
    dim,
};

const Cell = struct {
    text: []const u8,
    style: Style,
};

/// Render `source` into display lines without trailing newlines. When
/// `final` is false the incomplete trailing line is ignored. Each returned
/// line already contains ANSI styling when the palette is enabled.
pub fn render(
    arena: std.mem.Allocator,
    source: []const u8,
    width: usize,
    palette: style_mod.Palette,
    final: bool,
) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var fence: ?[]const u8 = null;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, start, '\n')) |nl| {
        try renderSourceLine(arena, &lines, source[start..nl], width, palette, &fence);
        start = nl + 1;
    }
    if (final and start < source.len) {
        try renderSourceLine(arena, &lines, source[start..], width, palette, &fence);
    }
    return lines.toOwnedSlice(arena);
}

fn renderSourceLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    line: []const u8,
    width: usize,
    palette: style_mod.Palette,
    fence: *?[]const u8,
) !void {
    if (fence.* != null) {
        if (fenceLang(line) != null) {
            fence.* = null;
            return;
        }
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        try appendText(arena, &cells, "  ", .none);
        try highlight(arena, &cells, line);
        try pushWrapped(arena, lines, cells.items, width, "  ", palette);
        return;
    }

    if (fenceLang(line)) |lang| {
        fence.* = lang;
        return;
    }

    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (headingText(trimmed)) |text| {
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        try inlineCells(arena, &cells, text);
        for (cells.items) |*cell| cell.style = .heading;
        try pushWrapped(arena, lines, cells.items, width, "", palette);
        return;
    }
    if (bulletText(trimmed)) |item| {
        var cells: std.ArrayListUnmanaged(Cell) = .empty;
        try appendText(arena, &cells, "• ", .bullet);
        try inlineCells(arena, &cells, item.body);
        try pushWrapped(arena, lines, cells.items, width, item.indent, palette);
        return;
    }

    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    try inlineCells(arena, &cells, line);
    try pushWrapped(arena, lines, cells.items, width, "", palette);
}

const ListItem = struct { body: []const u8, indent: []const u8 };

fn headingText(trimmed: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n == trimmed.len) return "";
    if (trimmed[n] != ' ' and trimmed[n] != '\t') return null;
    return std.mem.trimStart(u8, trimmed[n..], " \t");
}

fn bulletText(trimmed: []const u8) ?ListItem {
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and
        (trimmed[1] == ' ' or trimmed[1] == '\t'))
    {
        return .{ .body = std.mem.trimStart(u8, trimmed[2..], " \t"), .indent = "  " };
    }
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i > 0 and i + 1 < trimmed.len and trimmed[i] == '.' and
        (trimmed[i + 1] == ' ' or trimmed[i + 1] == '\t'))
    {
        return .{ .body = std.mem.trimStart(u8, trimmed[i + 2 ..], " \t"), .indent = "   " };
    }
    return null;
}

fn fenceLang(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    const marker = if (std.mem.startsWith(u8, t, "```")) "```" else if (std.mem.startsWith(u8, t, "~~~")) "~~~" else return null;
    return std.mem.trim(u8, t[marker.len..], " \t");
}

fn inlineCells(arena: std.mem.Allocator, cells: *std.ArrayListUnmanaged(Cell), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try appendText(arena, cells, text[i + 2 .. end], .bold);
                i = end + 2;
                continue;
            }
        }
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try appendText(arena, cells, text[i + 1 .. end], .inline_code);
                i = end + 1;
                continue;
            }
        }
        var j = i + 1;
        while (j < text.len and text[j] != '*' and text[j] != '`') j += 1;
        try appendText(arena, cells, text[i..j], .none);
        i = j;
    }
}

fn highlight(arena: std.mem.Allocator, cells: *std.ArrayListUnmanaged(Cell), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "//") or
            (line[i] == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')))
        {
            try appendText(arena, cells, line[i..], .comment);
            return;
        }
        const c = line[i];
        if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (line[j] == c) {
                    j += 1;
                    break;
                }
            }
            try appendText(arena, cells, line[i..@min(j, line.len)], .string);
            i = @min(j, line.len);
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or line[j] == '_')) j += 1;
            try appendText(arena, cells, line[i..j], .number);
            i = j;
            continue;
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < line.len and isIdent(line[j])) j += 1;
            const word = line[i..j];
            try appendText(arena, cells, word, if (isKeyword(word)) .keyword else .none);
            i = j;
            continue;
        }
        try appendText(arena, cells, line[i .. i + 1], .none);
        i += 1;
    }
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isKeyword(word: []const u8) bool {
    const words = [_][]const u8{
        "fn",   "const",     "var",      "pub",    "return", "if",    "else",
        "for",  "while",     "switch",   "struct", "enum",   "test",  "import",
        "use",  "let",       "function", "def",    "class",  "func",  "package",
        "type", "interface", "async",    "await",  "true",   "false", "null",
        "and",  "or",        "not",      "in",     "match",  "case",  "break",
    };
    for (words) |w| {
        if (std.mem.eql(u8, word, w)) return true;
    }
    return false;
}

fn appendText(arena: std.mem.Allocator, cells: *std.ArrayListUnmanaged(Cell), text: []const u8, style: Style) !void {
    var i: usize = 0;
    while (i < text.len) {
        const n = utf8Len(text[i]);
        const end = @min(i + n, text.len);
        try cells.append(arena, .{ .text = text[i..end], .style = style });
        i = end;
    }
}

fn utf8Len(first: u8) usize {
    if (first < 0x80) return 1;
    if (first & 0xE0 == 0xC0) return 2;
    if (first & 0xF0 == 0xE0) return 3;
    if (first & 0xF8 == 0xF0) return 4;
    return 1;
}

fn pushWrapped(
    arena: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
    cells: []const Cell,
    width: usize,
    cont: []const u8,
    palette: style_mod.Palette,
) !void {
    const wrapped = try wrapCells(arena, cells, width, cont);
    for (wrapped) |line_cells| {
        try lines.append(arena, try renderCells(arena, line_cells, palette));
    }
}

fn wrapCells(arena: std.mem.Allocator, cells: []const Cell, width: usize, cont: []const u8) ![]const []const Cell {
    var out: std.ArrayListUnmanaged([]const Cell) = .empty;
    if (cells.len == 0) {
        try out.append(arena, &.{});
        return out.toOwnedSlice(arena);
    }
    if (width == 0) {
        try out.append(arena, try arena.dupe(Cell, cells));
        return out.toOwnedSlice(arena);
    }

    var pos: usize = 0;
    var first = true;
    while (pos < cells.len) {
        const prefix = if (first) "" else cont;
        var line: std.ArrayListUnmanaged(Cell) = .empty;
        try appendText(arena, &line, prefix, .dim);
        const prefix_len = line.items.len;
        const avail = @max(width -| prefix_len, 1);
        var count: usize = 0;
        while (pos < cells.len and count < avail) {
            try line.append(arena, cells[pos]);
            pos += 1;
            count += 1;
        }
        if (pos < cells.len and count == avail) {
            var break_at: ?usize = null;
            var k = line.items.len;
            while (k > prefix_len) {
                k -= 1;
                if (std.mem.eql(u8, line.items[k].text, " ")) {
                    break_at = k;
                    break;
                }
            }
            if (break_at) |b| {
                const consumed = b - prefix_len;
                pos = pos - (count - consumed) + 1;
                while (pos < cells.len and std.mem.eql(u8, cells[pos].text, " ")) pos += 1;
                line.shrinkRetainingCapacity(b);
            }
        }
        try out.append(arena, try line.toOwnedSlice(arena));
        first = false;
    }
    return out.toOwnedSlice(arena);
}

fn renderCells(arena: std.mem.Allocator, cells: []const Cell, palette: style_mod.Palette) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var current: ?Style = null;
    for (cells) |cell| {
        if (cell.style != current) {
            if (palette.enabled) {
                if (current != null) try w.writeAll("\x1b[0m");
                if (styleCode(cell.style)) |code| try w.print("\x1b[{s}m", .{code});
            }
            current = cell.style;
        }
        try w.writeAll(cell.text);
    }
    if (palette.enabled and current != null and current.? != .none) try w.writeAll("\x1b[0m");
    return aw.written();
}

fn styleCode(style: Style) ?[]const u8 {
    return switch (style) {
        .none => null,
        .bold => "1",
        .inline_code => "36",
        .heading => "1;97",
        .bullet => "36",
        .comment => "2",
        .string => "32",
        .keyword => "95",
        .number => "33",
        .dim => "2",
    };
}

/// Current visible width of stdout, or null when stdout is not a TTY.
pub fn terminalWidth(io: std.Io) ?usize {
    const file = std.Io.File.stdout();
    const is_tty = file.isTty(io) catch return null;
    if (!is_tty) return null;
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return null;
    if (result.device_io_control < 0 or ws.col == 0) return null;
    return ws.col;
}

/// Incremental renderer for one assistant message. Calls to `feed` render
/// complete lines; `finish` flushes the trailing partial line and resets.
pub const Renderer = struct {
    io: std.Io,
    file: std.Io.File,
    arena: std.mem.Allocator,
    palette: style_mod.Palette,
    raw: std.ArrayListUnmanaged(u8) = .empty,
    printed: std.ArrayListUnmanaged([]const u8) = .empty,
    active: bool = false,
    last_width: usize = 0,

    pub fn init(io: std.Io, file: std.Io.File, arena: std.mem.Allocator, palette: style_mod.Palette) Renderer {
        return .{ .io = io, .file = file, .arena = arena, .palette = palette };
    }

    pub fn feed(self: *Renderer, chunk: []const u8, width: usize) void {
        if (chunk.len == 0) return;
        if (!self.active) {
            self.active = true;
            self.raw.clearRetainingCapacity();
            self.printed.clearRetainingCapacity();
            self.last_width = 0;
        }
        self.raw.appendSlice(self.arena, chunk) catch return;
        const newline = std.mem.indexOfScalar(u8, chunk, '\n') != null;
        const width_changed = self.palette.enabled and width != self.last_width;
        if (newline or width_changed) self.paint(width, false);
    }

    pub fn finish(self: *Renderer, width: usize) void {
        if (!self.active) return;
        self.paint(width, true);
        self.active = false;
        self.raw.clearRetainingCapacity();
        self.printed.clearRetainingCapacity();
        self.last_width = 0;
    }

    fn paint(self: *Renderer, width: usize, final: bool) void {
        const effective_width = if (self.palette.enabled or self.last_width == 0) width else self.last_width;
        const lines = render(self.arena, self.raw.items, effective_width, self.palette, final) catch return;
        const source_ends_newline = self.raw.items.len > 0 and self.raw.items[self.raw.items.len - 1] == '\n';

        var common: usize = 0;
        while (common < self.printed.items.len and common < lines.len and
            std.mem.eql(u8, self.printed.items[common], lines[common])) common += 1;

        const reflow = self.palette.enabled and self.printed.items.len > 0 and
            (effective_width != self.last_width or common < self.printed.items.len);
        if (reflow) {
            self.erase(self.printed.items.len);
            self.printed.clearRetainingCapacity();
            common = 0;
        }

        for (lines[common..], common..) |line, idx| {
            self.write(line);
            const is_last = idx + 1 == lines.len;
            if (!final or source_ends_newline or !is_last) self.write("\n");
            self.printed.append(self.arena, line) catch return;
        }
        self.last_width = effective_width;
    }

    fn erase(self: *Renderer, count: usize) void {
        if (count == 0 or !self.palette.enabled) return;
        var buf: [48]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A\r\x1b[0J", .{count}) catch return;
        self.write(seq);
    }

    fn write(self: *Renderer, bytes: []const u8) void {
        self.file.writeStreamingAll(self.io, bytes) catch {};
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn readOutput(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, path, arena, .limited(1024 * 1024));
}

test "split bold and inline code across chunks render once complete" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "out.txt", .{});
    defer file.close(io);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Renderer.init(io, file, arena, .{ .enabled = true });
    r.feed("hello **wor", 80);
    r.feed("ld** and `co", 80);
    r.feed("de`\n", 80);
    r.finish(80);

    const out = try readOutput(io, tmp.dir, arena, "out.txt");
    try testing.expect(std.mem.indexOf(u8, out, "**") == null);
    try testing.expect(std.mem.indexOf(u8, out, "`") == null);
    try testing.expect(std.mem.indexOf(u8, out, "world") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1mworld\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[36mcode\x1b[0m") != null);
}

test "split code fence opens only after the fence line completes and closes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "out.txt", .{});
    defer file.close(io);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Renderer.init(io, file, arena, .{ .enabled = false });
    r.feed("```zi", 80);
    r.feed("g\nconst x = 1; // note\n", 80);
    r.feed("``", 80);
    r.feed("`\n", 80);
    r.finish(80);

    const out = try readOutput(io, tmp.dir, arena, "out.txt");
    try testing.expect(std.mem.indexOf(u8, out, "```") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const x = 1; // note") != null);
}

test "headings and lists survive split chunks" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "out.txt", .{});
    defer file.close(io);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Renderer.init(io, file, arena, .{ .enabled = false });
    r.feed("# Head", 80);
    r.feed("ing\n- one item\n", 80);
    r.feed("1. first\n", 80);
    r.finish(80);

    const out = try readOutput(io, tmp.dir, arena, "out.txt");
    try testing.expect(std.mem.indexOf(u8, out, "#") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Heading") != null);
    try testing.expect(std.mem.indexOf(u8, out, "• one item") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first") != null);
}

test "width wrapping and resize reflow" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "out.txt", .{});
    defer file.close(io);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = Renderer.init(io, file, arena, .{ .enabled = true });
    r.feed("alpha beta gamma delta\n", 40);
    const wide = try readOutput(io, tmp.dir, arena, "out.txt");
    try testing.expect(std.mem.indexOf(u8, wide, "alpha beta gamma delta") != null);

    r.feed("epsilon\n", 12);
    const narrow = try readOutput(io, tmp.dir, arena, "out.txt");
    try testing.expect(std.mem.indexOf(u8, narrow, "\x1b[2A") != null or std.mem.indexOf(u8, narrow, "\x1b[1A") != null);
    try testing.expect(std.mem.indexOf(u8, narrow, "epsilon") != null);
    r.finish(12);

    const plain = try render(arena, "alpha beta gamma delta\n", 12, .{ .enabled = false }, true);
    try testing.expect(plain.len > 1);
    for (plain) |line| try testing.expect(line.len <= 12);
}

test "fenced code gets light syntax highlighting and no fence markers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try render(arena, "```zig\nconst x = 1; // note\n```\n", 0, .{ .enabled = true }, true);
    var all: std.ArrayListUnmanaged(u8) = .empty;
    for (lines) |line| try all.appendSlice(arena, line);
    try testing.expect(std.mem.indexOf(u8, all.items, "```") == null);
    try testing.expect(std.mem.indexOf(u8, all.items, "\x1b[95mconst\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, all.items, "\x1b[2m// note\x1b[0m") != null);
}

test "no ANSI in plain output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try render(arena, "# title\n**bold**\n```\nconst x = 1;\n```\n", 0, .{ .enabled = false }, true);
    for (lines) |line| try testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
}
