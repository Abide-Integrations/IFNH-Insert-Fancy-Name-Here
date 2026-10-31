//! Streaming-safe inline markdown renderer (ACTIVE_PLAN C-07).
//!
//! Line-oriented: bytes are accumulated until a line is complete (`\n`), then
//! the line is parsed and emitted. That makes chunk boundaries irrelevant: a
//! fixture fed one byte at a time renders byte-identically to the same fixture
//! fed whole, and a half-written construct or UTF-8 sequence is never emitted.
//! `finish()` renders whatever tail is left as one final line.
//!
//! Terminal-free apart from the caller-supplied width (and the `wrapWidth`
//! helper the REPL calls once at startup). ANSI codes come from the same
//! palette as the rest of the UI, so a disabled palette writes zero ESC bytes
//! while still removing markers, wrapping and indenting.
//!
//! Subset rendered: ATX headings, `**bold**`, `*italic*`/`_italic_`, inline
//! `code`, fenced code blocks (``` or ~~~, optional language), `-`/`*`/`+`/
//! `1.` lists, `>` blockquotes, and `[text](url)` links. Code content is
//! verbatim and never wrapped; prose wraps at `Options.width` code points.

const std = @import("std");
const builtin = @import("builtin");
const style = @import("style.zig");

pub const Options = struct {
    width: usize = 80,
    palette: style.Palette = .{},
};

/// Inline / highlight styles. The SGR codes mirror `style.Palette`; they are
/// kept inline so a styled span can be written without allocating a wrapper.
const Style = enum {
    plain,
    heading,
    bold,
    italic,
    code,
    dim,
    success,
    warn,
    err,
    info,

    fn sgr(self: Style) []const u8 {
        return switch (self) {
            .plain => "",
            .heading => "1;97", // palette.heading
            .bold => "1",
            .italic => "3",
            .code, .info => "36", // palette.info
            .dim => "2", // palette.dim
            .success => "32", // palette.success
            .warn => "93", // palette.warn
            .err => "91", // palette.err
        };
    }
};

/// Writes one physical output line, tracking the open style so no line ends
/// with an SGR code still in effect.
const LineOut = struct {
    out: *std.Io.Writer,
    palette_on: bool,
    cur: Style = .plain,
    saw_sgr: bool = false,

    fn set(self: *LineOut, st: Style) !void {
        if (!self.palette_on or st == self.cur) return;
        if (self.cur != .plain) try self.out.writeAll("\x1b[0m");
        if (st != .plain) {
            try self.out.writeAll("\x1b[");
            try self.out.writeAll(st.sgr());
            try self.out.writeByte('m');
            self.saw_sgr = true;
        }
        self.cur = st;
    }

    fn write(self: *LineOut, st: Style, text: []const u8) !void {
        if (text.len == 0) return;
        try self.set(st);
        try self.out.writeAll(text);
    }

    /// Write bytes without touching the open style (word separators).
    fn raw(self: *LineOut, text: []const u8) !void {
        try self.out.writeAll(text);
    }

    /// Close the physical line: reset any style that was opened, then `\n`.
    fn end(self: *LineOut) !void {
        if (self.saw_sgr) try self.out.writeAll("\x1b[0m");
        try self.out.writeByte('\n');
        self.cur = .plain;
        self.saw_sgr = false;
    }
};

const Atom = struct {
    text: []const u8,
    style: Style,
    /// A space preceded this atom, so it starts a new word.
    space_before: bool,
};

const AtomSink = struct {
    list: *std.ArrayListUnmanaged(Atom),
    alloc: std.mem.Allocator,
    space: bool = false,

    /// Append `text` as atoms split on spaces. A run of spaces sets the flag
    /// for the next atom only, so word grouping survives style changes.
    fn push(self: *AtomSink, text: []const u8, st: Style) !void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == ' ') {
                self.space = true;
                i += 1;
                continue;
            }
            var j = i;
            while (j < text.len and text[j] != ' ') j += 1;
            try self.list.append(self.alloc, .{ .text = text[i..j], .style = st, .space_before = self.space });
            self.space = false;
            i = j;
        }
    }
};

const Fence = struct {
    info: []const u8,
    ch: u8,
};

const ListItem = struct {
    marker: []const u8,
    content: []const u8,
};

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    options: Options,
    /// The unresolved tail: bytes after the last emitted `\n`.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    in_fence: bool = false,
    fence_ch: u8 = '`',
    lang_buf: [24]u8 = undefined,
    lang_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, options: Options) Renderer {
        return .{ .alloc = alloc, .options = options };
    }

    pub fn deinit(self: *Renderer) void {
        self.buf.deinit(self.alloc);
    }

    /// Drop buffered text and fenced state. Call between turns.
    pub fn reset(self: *Renderer) void {
        self.buf.clearRetainingCapacity();
        self.in_fence = false;
        self.fence_ch = '`';
        self.lang_len = 0;
    }

    /// Bytes waiting for a newline (test/diagnostic helper).
    pub fn pending(self: *const Renderer) usize {
        return self.buf.items.len;
    }

    pub fn push(self: *Renderer, chunk: []const u8, out: *std.Io.Writer) !void {
        try self.buf.appendSlice(self.alloc, chunk);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.buf.items, start, '\n')) |nl| {
            var line = self.buf.items[start..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try self.emitLine(line, out);
            start = nl + 1;
        }
        if (start > 0) {
            const rest = self.buf.items.len - start;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[start..]);
            self.buf.shrinkRetainingCapacity(rest);
        }
    }

    /// Render the remaining tail as a final line. A clean (empty) tail writes
    /// nothing, so a turn that ended with `\n` gets no extra blank line.
    pub fn finish(self: *Renderer, out: *std.Io.Writer) !void {
        if (self.buf.items.len == 0) return;
        var line: []const u8 = self.buf.items;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try self.emitLine(line, out);
        self.buf.clearRetainingCapacity();
    }

    fn effectiveWidth(self: *const Renderer) usize {
        const w = self.options.width;
        return if (w == 0) 80 else w;
    }

    fn lang(self: *const Renderer) []const u8 {
        return self.lang_buf[0..self.lang_len];
    }

    fn emitLine(self: *Renderer, line: []const u8, out: *std.Io.Writer) !void {
        if (self.in_fence) {
            if (isClosingFence(line, self.fence_ch)) {
                self.in_fence = false;
                self.lang_len = 0;
                return;
            }
            return self.emitCode(line, out);
        }
        if (parseFence(line)) |fence| {
            self.in_fence = true;
            self.fence_ch = fence.ch;
            self.setLang(fence.info);
            return;
        }
        try self.emitProse(line, out);
    }

    fn setLang(self: *Renderer, info: []const u8) void {
        var it = std.mem.tokenizeAny(u8, info, " \t{,");
        const first = it.next() orelse "";
        const n = @min(first.len, self.lang_buf.len);
        for (first[0..n], 0..) |c, i| self.lang_buf[i] = std.ascii.toLower(c);
        self.lang_len = n;
    }

    fn emitProse(self: *Renderer, line: []const u8, out: *std.Io.Writer) !void {
        var indent_len: usize = 0;
        while (indent_len < line.len and (line[indent_len] == ' ' or line[indent_len] == '\t')) indent_len += 1;
        const indent = line[0..indent_len];
        const rest = line[indent_len..];
        if (rest.len == 0) {
            try out.writeByte('\n');
            return;
        }

        var atoms: std.ArrayListUnmanaged(Atom) = .empty;
        defer atoms.deinit(self.alloc);
        var sink = AtomSink{ .list = &atoms, .alloc = self.alloc };

        if (parseHeading(rest)) |heading| {
            try sink.push(std.mem.trimEnd(u8, heading, " \t"), .heading);
            return self.wrapAtoms(out, atoms.items, indent, indent, .plain);
        }
        if (parseQuote(rest)) |quote| {
            try collectInline(quote, &sink, .dim);
            return self.wrapAtoms(out, atoms.items, "| ", "| ", .dim);
        }
        if (parseList(line)) |item| {
            const marker_width = cpWidth(item.marker);
            var cont_buf: [64]u8 = undefined;
            const cont = cont_buf[0..@min(marker_width, cont_buf.len)];
            @memset(cont, ' ');
            try collectInline(item.content, &sink, .plain);
            return self.wrapAtoms(out, atoms.items, item.marker, cont, .plain);
        }
        try collectInline(rest, &sink, .plain);
        return self.wrapAtoms(out, atoms.items, indent, indent, .plain);
    }

    /// Greedy word wrap. Words are runs of atoms joined without a space, so
    /// `**a**nd` stays one word. A word wider than the line is hard-split at a
    /// code-point boundary; nothing ever splits an escape sequence because
    /// codes are written between spans, never into them.
    fn wrapAtoms(
        self: *const Renderer,
        out: *std.Io.Writer,
        atoms: []const Atom,
        first_prefix: []const u8,
        cont_prefix: []const u8,
        prefix_style: Style,
    ) !void {
        const width = self.effectiveWidth();
        var lo = LineOut{ .out = out, .palette_on = self.options.palette.enabled };
        var first = true;
        var line_started = false;
        var line_width: usize = 0;
        var prefix_width: usize = 0;
        var pending_space = false;

        var i: usize = 0;
        while (i < atoms.len) {
            const start = i;
            i += 1;
            while (i < atoms.len and !atoms[i].space_before) i += 1;
            if (atoms[start].space_before) pending_space = true;

            var word_width: usize = 0;
            for (atoms[start..i]) |a| word_width += cpWidth(a.text);

            if (!line_started) {
                const pfx = if (first) first_prefix else cont_prefix;
                try lo.write(prefix_style, pfx);
                prefix_width = cpWidth(pfx);
                line_width = prefix_width;
                line_started = true;
            }
            const add_space = pending_space and line_width > prefix_width;
            const need = word_width + @as(usize, if (add_space) 1 else 0);
            if (line_width + need <= width) {
                if (add_space) {
                    try lo.raw(" ");
                    line_width += 1;
                }
                for (atoms[start..i]) |a| try lo.write(a.style, a.text);
                line_width += word_width;
                pending_space = false;
                continue;
            }

            // The word does not fit here: drop the pending space, break the
            // line, then hard-split only if it cannot fit on a fresh one.
            pending_space = false;
            if (line_width > prefix_width) {
                try lo.end();
                first = false;
                try lo.write(prefix_style, cont_prefix);
                prefix_width = cpWidth(cont_prefix);
                line_width = prefix_width;
            }
            if (width <= line_width or word_width <= width - line_width) {
                for (atoms[start..i]) |a| try lo.write(a.style, a.text);
                line_width += word_width;
                continue;
            }
            for (atoms[start..i]) |a| {
                var text = a.text;
                while (text.len > 0) {
                    const room = if (width > line_width) width - line_width else 1;
                    if (cpWidth(text) <= room) {
                        try lo.write(a.style, text);
                        line_width += cpWidth(text);
                        break;
                    }
                    const cut = byteAfterCodepoints(text, room);
                    try lo.write(a.style, text[0..cut]);
                    text = text[cut..];
                    try lo.end();
                    first = false;
                    try lo.write(prefix_style, cont_prefix);
                    prefix_width = cpWidth(cont_prefix);
                    line_width = prefix_width;
                }
            }
        }
        if (!line_started) {
            try out.writeByte('\n');
            return;
        }
        try lo.end();
    }

    fn emitCode(self: *Renderer, line: []const u8, out: *std.Io.Writer) !void {
        const family = langFamily(self.lang());
        var lo = LineOut{ .out = out, .palette_on = self.options.palette.enabled };
        switch (family) {
            .none => try lo.write(.plain, line),
            .diff => {
                const st: Style = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---"))
                    .heading
                else if (std.mem.startsWith(u8, line, "+"))
                    .success
                else if (std.mem.startsWith(u8, line, "-"))
                    .err
                else if (std.mem.startsWith(u8, line, "@@"))
                    .info
                else if (std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index "))
                    .dim
                else
                    .plain;
                try lo.write(st, line);
            },
            else => try scanCode(family, line, &lo),
        }
        try lo.end();
    }
};

/// One-shot render: push the whole text then finish. Used by fixtures and by
/// callers that already hold a complete reply.
pub fn renderAll(alloc: std.mem.Allocator, text: []const u8, options: Options, out: *std.Io.Writer) !void {
    var r = Renderer.init(alloc, options);
    defer r.deinit();
    try r.push(text, out);
    try r.finish(out);
}

// ---------------------------------------------------------------- terminal width

/// `ioctl(TIOCGWINSZ)` on `fd`; 0 when it is not a terminal or has no width.
pub fn termWidth(fd: std.posix.fd_t) usize {
    if (builtin.os.tag == .windows) return 0;
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0 or ws.col == 0) return 0;
    return ws.col;
}

/// `COLUMNS` as a width; 0 for absent, zero, negative or non-numeric.
pub fn parseColumns(value: ?[]const u8) usize {
    const raw = value orelse return 0;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const n = std.fmt.parseInt(usize, text, 10) catch return 0;
    return n;
}

/// Width the REPL passes to `Options.width`: fd 1's terminal, else COLUMNS,
/// else 80. A non-positive/invalid value falls through to the next source.
pub fn wrapWidth(environ: ?*const std.process.Environ.Map) usize {
    const from_term = termWidth(std.posix.STDOUT_FILENO);
    if (from_term > 0) return from_term;
    if (environ) |env| {
        const from_env = parseColumns(env.get("COLUMNS"));
        if (from_env > 0) return from_env;
    }
    return 80;
}

// ---------------------------------------------------------------- line syntax

fn parseFence(line: []const u8) ?Fence {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len < 3) return null;
    const ch = t[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == ch) n += 1;
    if (n < 3) return null;
    return .{ .info = std.mem.trim(u8, t[n..], " \t"), .ch = ch };
}

fn isClosingFence(line: []const u8, ch: u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len < 3) return false;
    var n: usize = 0;
    while (n < t.len and t[n] == ch) n += 1;
    return n >= 3 and std.mem.trim(u8, t[n..], " \t").len == 0;
}

/// Heading text without the marker, or null when the line is not an ATX
/// heading. Levels 1..6 only; the marker must be followed by a space.
fn parseHeading(rest: []const u8) ?[]const u8 {
    var n: usize = 0;
    while (n < rest.len and rest[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n >= rest.len or rest[n] != ' ') return null;
    return rest[n + 1 ..];
}

fn parseQuote(rest: []const u8) ?[]const u8 {
    if (rest.len == 0 or rest[0] != '>') return null;
    var i: usize = 1;
    if (i < rest.len and rest[i] == ' ') i += 1;
    return rest[i..];
}

fn parseList(line: []const u8) ?ListItem {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const rest = line[i..];
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        return .{ .marker = line[0 .. i + 2], .content = rest[2..] };
    }
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits > 0 and digits + 1 < rest.len and rest[digits] == '.' and rest[digits + 1] == ' ') {
        return .{ .marker = line[0 .. i + digits + 2], .content = rest[digits + 2 ..] };
    }
    return null;
}

// ---------------------------------------------------------------- inline markdown

fn collectInline(line: []const u8, sink: *AtomSink, base: Style) !void {
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "**")) {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try sink.push(line[plain_start..i], base);
                try sink.push(line[i + 2 .. end], .bold);
                i = end + 2;
                plain_start = i;
                continue;
            }
        }
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try sink.push(line[plain_start..i], base);
                try sink.push(line[i + 1 .. end], .code);
                i = end + 1;
                plain_start = i;
                continue;
            }
        }
        if (line[i] == '*' or line[i] == '_') {
            const ch = line[i];
            if (std.mem.indexOfScalarPos(u8, line, i + 1, ch)) |end| {
                // `**` opens bold; a star pair is never italic.
                if (end > i + 1 and !(ch == '*' and line[i + 1] == '*')) {
                    try sink.push(line[plain_start..i], base);
                    try sink.push(line[i + 1 .. end], .italic);
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }
        }
        if (line[i] == '[') {
            if (parseLink(line, i)) |link| {
                try sink.push(line[plain_start..i], base);
                if (link.url.len == 0) {
                    try sink.push(link.text, base);
                } else if (std.mem.eql(u8, link.text, link.url)) {
                    try sink.push(link.text, base);
                } else if (link.text.len == 0) {
                    try sink.push(link.url, base);
                } else {
                    try sink.push(link.text, base);
                    try sink.push(" (", base);
                    try sink.push(link.url, .dim);
                    try sink.push(")", base);
                }
                i = link.next;
                plain_start = i;
                continue;
            }
        }
        i += 1;
    }
    try sink.push(line[plain_start..], base);
}

const Link = struct {
    text: []const u8,
    url: []const u8,
    next: usize,
};

fn parseLink(line: []const u8, i: usize) ?Link {
    if (line[i] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, line, i + 1, ']') orelse return null;
    if (close + 1 >= line.len or line[close + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse return null;
    return .{
        .text = line[i + 1 .. close],
        .url = line[close + 2 .. close_paren],
        .next = close_paren + 1,
    };
}

// ---------------------------------------------------------------- syntax highlight

const Lang = enum { none, zig, json, shell, python, js, diff };

fn langFamily(name: []const u8) Lang {
    if (std.mem.eql(u8, name, "zig")) return .zig;
    if (std.mem.eql(u8, name, "json")) return .json;
    if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "shell")) return .shell;
    if (std.mem.eql(u8, name, "python") or std.mem.eql(u8, name, "py")) return .python;
    if (std.mem.eql(u8, name, "js") or std.mem.eql(u8, name, "javascript") or
        std.mem.eql(u8, name, "ts") or std.mem.eql(u8, name, "typescript")) return .js;
    if (std.mem.eql(u8, name, "diff")) return .diff;
    return .none;
}

const zig_keywords = [_][]const u8{
    "addrspace", "align",       "allowzero",      "and",      "anyframe", "anytype",     "asm",
    "async",     "await",       "break",          "callconv", "catch",    "comptime",    "const",
    "continue",  "defer",       "else",           "enum",     "errdefer", "error",       "export",
    "extern",    "fn",          "for",            "if",       "inline",   "noalias",     "noinline",
    "nosuspend", "opaque",      "or",             "orelse",   "packed",   "pub",         "resume",
    "return",    "struct",      "suspend",        "switch",   "test",     "threadlocal", "try",
    "union",     "unreachable", "usingnamespace", "var",      "volatile", "while",       "null",
    "true",      "false",       "undefined",
};

const shell_keywords = [_][]const u8{
    "if",   "then",  "else",  "elif",     "fi",     "for",    "while",  "until", "do",  "done",
    "case", "esac",  "in",    "function", "local",  "export", "return", "exit",  "set", "unset",
    "read", "shift", "break", "continue", "source", "alias",
};

const python_keywords = [_][]const u8{
    "False", "None",     "True",  "and",    "as",   "assert", "async",  "await",    "break",
    "class", "continue", "def",   "del",    "elif", "else",   "except", "finally",  "for",
    "from",  "global",   "if",    "import", "in",   "is",     "lambda", "nonlocal", "not",
    "or",    "pass",     "raise", "return", "try",  "while",  "with",   "yield",
};

const js_keywords = [_][]const u8{
    "const",  "let",        "var",     "function", "return",    "if",     "else",  "for",       "while",
    "do",     "switch",     "case",    "break",    "continue",  "new",    "class", "extends",   "import",
    "export", "from",       "default", "async",    "await",     "try",    "catch", "finally",   "throw",
    "typeof", "instanceof", "this",    "null",     "undefined", "true",   "false", "interface", "type",
    "enum",   "implements", "public",  "private",  "readonly",  "static", "void",  "never",     "unknown",
    "any",
};

fn inWords(words: []const []const u8, word: []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isKeyword(family: Lang, word: []const u8) bool {
    return switch (family) {
        .zig => inWords(&zig_keywords, word),
        .shell => inWords(&shell_keywords, word),
        .python => inWords(&python_keywords, word),
        .js => inWords(&js_keywords, word),
        .json => std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false") or std.mem.eql(u8, word, "null"),
        else => false,
    };
}

fn isQuote(family: Lang, c: u8) bool {
    return switch (family) {
        .json => c == '"',
        .zig, .python => c == '"' or c == '\'',
        .shell => c == '"' or c == '\'' or c == '`',
        .js => c == '"' or c == '\'' or c == '`',
        else => false,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn commentAt(family: Lang, line: []const u8, i: usize) bool {
    return switch (family) {
        .zig, .js => i + 1 < line.len and line[i] == '/' and line[i + 1] == '/',
        .shell, .python => line[i] == '#',
        else => false,
    };
}

fn isInteresting(family: Lang, c: u8) bool {
    return std.ascii.isDigit(c) or isIdentStart(c) or isQuote(family, c) or
        c == '#' or c == '/';
}

/// Token scan for one code line: comments dim, strings green, keywords cyan
/// and numbers yellow. No state survives the line (multi-line strings and
/// block comments re-open per line), and unknown languages never get here.
fn scanCode(family: Lang, line: []const u8, lo: *LineOut) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (family == .js and i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
            const stop = if (std.mem.indexOfPos(u8, line, i + 2, "*/")) |end| end + 2 else line.len;
            try lo.write(.dim, line[i..stop]);
            i = stop;
            continue;
        }
        if (commentAt(family, line, i)) {
            try lo.write(.dim, line[i..]);
            return;
        }
        const c = line[i];
        if (isQuote(family, c)) {
            var j = i + 1;
            while (j < line.len) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    j += 2;
                    continue;
                }
                if (line[j] == c) {
                    j += 1;
                    break;
                }
                j += 1;
            }
            try lo.write(.success, line[i..j]);
            i = j;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or line[j] == '_')) j += 1;
            try lo.write(.warn, line[i..j]);
            i = j;
            continue;
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < line.len and isIdentPart(line[j])) j += 1;
            const word = line[i..j];
            try lo.write(if (isKeyword(family, word)) .info else .plain, word);
            i = j;
            continue;
        }
        var j = i + 1;
        while (j < line.len and !isInteresting(family, line[j])) j += 1;
        try lo.write(.plain, line[i..j]);
        i = j;
    }
}

// ---------------------------------------------------------------- code points

/// Byte length of the UTF-8 sequence at `i`, or 1 for an invalid byte, so
/// arbitrary streamed bytes still count and split predictably.
fn seqLen(s: []const u8, i: usize) usize {
    const b = s[i];
    const len: usize = if (b < 0x80)
        1
    else if (b & 0xE0 == 0xC0)
        2
    else if (b & 0xF0 == 0xE0)
        3
    else if (b & 0xF8 == 0xF0)
        4
    else
        1;
    if (i + len > s.len) return 1;
    var k: usize = 1;
    while (k < len) : (k += 1) {
        if (s[i + k] & 0xC0 != 0x80) return 1;
    }
    return len;
}

fn cpWidth(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        i += seqLen(s, i);
        n += 1;
    }
    return n;
}

/// Byte offset just past `n` code points (clamped to the end).
fn byteAfterCodepoints(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < s.len and c < n) {
        i += seqLen(s, i);
        c += 1;
    }
    return i;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn renderToString(alloc: std.mem.Allocator, text: []const u8, options: Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try renderAll(alloc, text, options, &aw.writer);
    return aw.toOwnedSlice();
}

const fixture =
    "# Release notes\n" ++
    "\n" ++
    "This is **bold** and *italic* with `inline code` in a sentence.\n" ++
    "\n" ++
    "- first item is long enough to wrap around the width when the width is narrow\n" ++
    "- see [the docs](https://example.test/docs) for more\n" ++
    "\n" ++
    "```zig\n" ++
    "const answer = 42; // **not bold** and `not code`\n" ++
    "```\n" ++
    "\n" ++
    "> quoted prose that should stay dim\n" ++
    "\n" ++
    "Final paragraph without a trailing newline";

fn renderFeeding(alloc: std.mem.Allocator, text: []const u8, options: Options, chunk: usize) ![]u8 {
    var r = Renderer.init(alloc, options);
    defer r.deinit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const end = @min(i + chunk, text.len);
        try r.push(text[i..end], &aw.writer);
        i = end;
    }
    try r.finish(&aw.writer);
    return aw.toOwnedSlice();
}

test "render: byte-split feeds match a whole render" {
    const a = testing.allocator;
    const opts = Options{ .width = 40, .palette = .{ .enabled = true } };
    const whole = try renderToString(a, fixture, opts);
    defer a.free(whole);

    const one = try renderFeeding(a, fixture, opts, 1);
    defer a.free(one);
    try testing.expectEqualStrings(whole, one);

    const three = try renderFeeding(a, fixture, opts, 3);
    defer a.free(three);
    try testing.expectEqualStrings(whole, three);

    // The fixture exercises a fence, a link and inline markers; the whole
    // render must actually contain them rendered.
    try testing.expect(std.mem.indexOf(u8, whole, "Release notes") != null);
    try testing.expect(std.mem.indexOf(u8, whole, "https://example.test/docs") != null);
    try testing.expect(std.mem.indexOf(u8, whole, "```") == null);
}

test "render: headings and inline markdown styling with palette on" {
    const a = testing.allocator;
    const out = try renderToString(a, "# Title\n\n**bold** *it* _it2_ `code`\n", .{ .palette = .{ .enabled = true } });
    defer a.free(out);
    try testing.expectEqualStrings(
        "\x1b[1;97mTitle\x1b[0m\n" ++
            "\n" ++
            "\x1b[1mbold \x1b[0m\x1b[3mit it2 \x1b[0m\x1b[36mcode\x1b[0m\n",
        out,
    );
}

test "render: fenced zig block highlights and leaves markdown markers alone" {
    const a = testing.allocator;
    const src = "```zig\nconst x = 1; // **not bold** `not code`\n```\n";
    const out = try renderToString(a, src, .{ .palette = .{ .enabled = true } });
    defer a.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x1b[36mconst\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[93m1\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m// **not bold** `not code`\x1b[0m") != null);
    // Markdown inside code is untouched: no bold/italic/code styling.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") == null);
    try testing.expect(std.mem.indexOf(u8, out, "**not bold**") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`not code`") != null);
    // The fence lines themselves are gone.
    try testing.expect(std.mem.indexOf(u8, out, "```") == null);
}

test "render: unknown language and disabled palette emit zero escape bytes" {
    const a = testing.allocator;

    const unknown = try renderToString(a, "```txt\n**x** `y`\n```\n", .{ .palette = .{ .enabled = true } });
    defer a.free(unknown);
    try testing.expectEqualStrings("**x** `y`\n", unknown);

    const plain = try renderToString(a, "# Head\n\n**bold** and `code`\n```zig\nconst x = 1;\n```\n- item\n", .{ .width = 40 });
    defer a.free(plain);
    try testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);
    try testing.expectEqualStrings("Head\n\nbold and code\nconst x = 1;\n- item\n", plain);
}

test "render: wraps prose at width 40 and keeps list continuation indent" {
    const a = testing.allocator;
    const prose = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen\n";
    const out = try renderToString(a, prose, .{ .width = 40 });
    defer a.free(out);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        try testing.expect(cpWidth(line) <= 40);
    }
    try testing.expect(count > 1);

    const list = "- alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi\n";
    const list_out = try renderToString(a, list, .{ .width = 40 });
    defer a.free(list_out);
    var list_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, list_out, "\n"), '\n');
    var first = true;
    var list_count: usize = 0;
    while (list_lines.next()) |line| {
        list_count += 1;
        try testing.expect(cpWidth(line) <= 40);
        if (first) {
            try testing.expect(std.mem.startsWith(u8, line, "- "));
            first = false;
        } else {
            try testing.expect(std.mem.startsWith(u8, line, "  "));
            try testing.expect(!std.mem.startsWith(u8, line, "- "));
        }
    }
    try testing.expect(list_count > 1);
}

test "render: an incomplete construct split across chunks is not emitted early" {
    const a = testing.allocator;
    var r = Renderer.init(a, .{ .palette = .{ .enabled = true } });
    defer r.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    try r.push("**bo", &aw.writer);
    try testing.expectEqual(@as(usize, 0), aw.written().len);
    try testing.expectEqual(@as(usize, 4), r.pending());

    try r.push("ld**\n", &aw.writer);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m\n", aw.written());

    // A partial UTF-8 sequence and a partial fence also wait for the line.
    var r2 = Renderer.init(a, .{});
    defer r2.deinit();
    var aw2: std.Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    try r2.push("caf\xc3", &aw2.writer);
    try testing.expectEqual(@as(usize, 0), aw2.written().len);
    try r2.push("\xa9\n```zi", &aw2.writer);
    try testing.expectEqualStrings("caf\u{e9}\n", aw2.written());
    try r2.push("g\nconst n = 1;\n", &aw2.writer);
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "const n = 1;") != null);
}

test "render: an unclosed fence at finish renders its body" {
    const a = testing.allocator;
    var r = Renderer.init(a, .{ .palette = .{ .enabled = true } });
    defer r.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    try r.push("```python\ndef f(x):\n    return x + 1", &aw.writer);
    try r.finish(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "def") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "```") == null);
}

test "render: every styled line ends with a reset before its newline" {
    const a = testing.allocator;
    const out = try renderToString(a, fixture, .{ .width = 40, .palette = .{ .enabled = true } });
    defer a.free(out);

    var lines = std.mem.splitScalar(u8, out, '\n');
    var styled: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, 0x1b) == null) continue;
        styled += 1;
        try testing.expect(std.mem.endsWith(u8, line, "\x1b[0m"));
    }
    try testing.expect(styled >= 4);
}

test "render: links render text plus a dim url unless they are equal" {
    const a = testing.allocator;
    const out = try renderToString(a, "[docs](https://example.test) and [same](same)\n", .{ .palette = .{ .enabled = true } });
    defer a.free(out);
    try testing.expectEqualStrings(
        "docs (\x1b[2mhttps://example.test\x1b[0m) and same\x1b[0m\n",
        out,
    );

    const plain = try renderToString(a, "[docs](https://example.test)\n", .{});
    defer a.free(plain);
    try testing.expectEqualStrings("docs (https://example.test)\n", plain);
}

test "render: terminal width falls back from COLUMNS to 80" {
    try testing.expectEqual(@as(usize, 0), parseColumns(null));
    try testing.expectEqual(@as(usize, 0), parseColumns(""));
    try testing.expectEqual(@as(usize, 0), parseColumns("0"));
    try testing.expectEqual(@as(usize, 0), parseColumns("abc"));
    try testing.expectEqual(@as(usize, 0), parseColumns("-5"));
    try testing.expectEqual(@as(usize, 40), parseColumns("40"));
    try testing.expectEqual(@as(usize, 40), parseColumns(" 40\n"));

    // No terminal on test stdout and no environment: the documented default.
    try testing.expectEqual(@as(usize, 80), wrapWidth(null));
}
