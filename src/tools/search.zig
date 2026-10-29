//! Search helpers for the glob/grep tools (B-07).
//!
//! The fallback path uses a small regex subset and a `.gitignore`-aware
//! walker. External `rg`/`fd` are used when the host allows them; their
//! output is normalised by `tool.zig` so both paths emit the same lines.

const std = @import("std");

pub const CompileError = error{
    UnsupportedGroup,
    UnsupportedAlternation,
    UnsupportedBackreference,
    UnsupportedRepetition,
    InvalidPattern,
    OutOfMemory,
};

pub fn regexError(err: CompileError) []const u8 {
    return switch (err) {
        error.UnsupportedGroup => "groups are unsupported",
        error.UnsupportedAlternation => "alternation is unsupported",
        error.UnsupportedBackreference => "backreferences are unsupported",
        error.UnsupportedRepetition => "{m,n} repetition is unsupported",
        error.InvalidPattern => "invalid pattern",
        error.OutOfMemory => "out of memory",
    };
}

const Atom = union(enum) {
    literal: u8,
    any,
    class: [32]u8,
    start,
    end,
};

const Node = struct {
    atom: Atom,
    min: usize = 1,
    max: ?usize = 1,
};

const State = struct {
    node: usize,
    text: usize,
    count: usize,
};

/// A compiled pattern from the supported subset: literals, `.`, `*`, `+`,
/// `?`, `[...]`, `^`, `$` and backslash escapes. Matching is byte-wise.
pub const Regex = struct {
    nodes: []const Node,
    alloc: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(State) = .empty,

    pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        var nodes: std.ArrayListUnmanaged(Node) = .empty;
        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];
            var node: Node = undefined;
            if (c == '^') {
                node = .{ .atom = .start };
                i += 1;
                try nodes.append(alloc, node);
                continue;
            }
            if (c == '$') {
                node = .{ .atom = .end };
                i += 1;
                try nodes.append(alloc, node);
                continue;
            }
            switch (c) {
                '\\' => {
                    i += 1;
                    if (i >= pattern.len) return error.InvalidPattern;
                    const escaped = pattern[i];
                    if (escaped >= '1' and escaped <= '9') return error.UnsupportedBackreference;
                    node = .{ .atom = .{ .literal = switch (escaped) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => escaped,
                    } } };
                    i += 1;
                },
                '(', ')' => return error.UnsupportedGroup,
                '|' => return error.UnsupportedAlternation,
                '{' => return error.UnsupportedRepetition,
                '[' => {
                    const class = try parseClass(pattern, &i);
                    node = .{ .atom = .{ .class = class } };
                },
                '.' => {
                    node = .{ .atom = .any };
                    i += 1;
                },
                '*', '+', '?' => return error.InvalidPattern,
                else => {
                    node = .{ .atom = .{ .literal = c } };
                    i += 1;
                },
            }
            if (i < pattern.len) {
                switch (pattern[i]) {
                    '*' => {
                        node.min = 0;
                        node.max = null;
                        i += 1;
                    },
                    '+' => {
                        node.min = 1;
                        node.max = null;
                        i += 1;
                    },
                    '?' => {
                        node.min = 0;
                        node.max = 1;
                        i += 1;
                    },
                    else => {},
                }
            }
            try nodes.append(alloc, node);
        }
        return .{ .nodes = try nodes.toOwnedSlice(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *Regex) void {
        self.stack.deinit(self.alloc);
    }

    pub fn isMatch(self: *Regex, text: []const u8) bool {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            self.stack.clearRetainingCapacity();
            self.stack.append(self.alloc, .{ .node = 0, .text = start, .count = 0 }) catch return false;
            var steps: usize = 0;
            while (self.stack.pop()) |state| {
                steps += 1;
                if (steps > 2_000_000) return false; // pathological pattern guard
                if (state.node >= self.nodes.len) return true;
                const node = self.nodes[state.node];
                switch (node.atom) {
                    .start => {
                        if (state.text == 0) self.push(state.node + 1, state.text, 0);
                        continue;
                    },
                    .end => {
                        if (state.text == text.len) self.push(state.node + 1, state.text, 0);
                        continue;
                    },
                    else => {},
                }
                const max = node.max orelse text.len + 1;
                if (state.count < max and state.text < text.len and atomMatches(node.atom, text[state.text])) {
                    self.push(state.node, state.text + 1, state.count + 1);
                }
                if (state.count >= node.min) self.push(state.node + 1, state.text, 0);
            }
        }
        return false;
    }

    fn push(self: *Regex, node: usize, text: usize, count: usize) void {
        self.stack.append(self.alloc, .{ .node = node, .text = text, .count = count }) catch {};
    }
};

fn atomMatches(atom: Atom, c: u8) bool {
    return switch (atom) {
        .literal => |l| l == c,
        .any => true,
        .class => |set| (set[c >> 3] & (@as(u8, 1) << @intCast(c & 7))) != 0,
        .start, .end => false,
    };
}

fn setBit(set: *[32]u8, c: u8) void {
    set[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
}

fn parseClass(pattern: []const u8, i: *usize) CompileError![32]u8 {
    var set = [_]u8{0} ** 32;
    var p = i.* + 1;
    var negated = false;
    if (p < pattern.len and pattern[p] == '^') {
        negated = true;
        p += 1;
    }
    var first = true;
    while (p < pattern.len) {
        var c = pattern[p];
        if (c == ']' and !first) {
            p += 1;
            if (negated) {
                for (0..set.len) |j| set[j] = ~set[j];
            }
            i.* = p;
            return set;
        }
        if (c == '\\') {
            p += 1;
            if (p >= pattern.len) return error.InvalidPattern;
            c = pattern[p];
        }
        p += 1;
        if (p + 1 < pattern.len and pattern[p] == '-' and pattern[p + 1] != ']') {
            var hi = pattern[p + 1];
            p += 2;
            if (hi == '\\') {
                if (p >= pattern.len) return error.InvalidPattern;
                hi = pattern[p];
                p += 1;
            }
            if (c > hi) return error.InvalidPattern;
            var x: usize = c;
            while (x <= hi) : (x += 1) setBit(&set, @intCast(x));
        } else {
            setBit(&set, c);
        }
        first = false;
    }
    return error.InvalidPattern;
}

/// Glob matching for `.gitignore` patterns: `**` crosses segments, `*` and
/// `?` stay within one, and `[...]` classes/escapes are supported.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    const p = stripDotSlash(pattern);
    const s = stripDotSlash(path);
    return matchSegs(p, s);
}

fn stripDotSlash(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '.' and s[1] == '/') return s[2..];
    return s;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn atEnd(c: *const Cursor) bool {
        return c.i >= c.s.len;
    }

    fn nextSegment(c: *Cursor) []const u8 {
        const start = c.i;
        while (c.i < c.s.len and c.s[c.i] != '/') c.i += 1;
        const seg = c.s[start..c.i];
        if (c.i < c.s.len) c.i += 1;
        return seg;
    }

    fn hasMoreSegments(c: *const Cursor) bool {
        return c.i < c.s.len;
    }
};

fn matchSegs(pattern_in: []const u8, subject_in: []const u8) bool {
    var p = Cursor{ .s = pattern_in };
    var s = Cursor{ .s = subject_in };

    while (!p.atEnd()) {
        const pseg = p.nextSegment();
        if (std.mem.eql(u8, pseg, "**")) {
            if (!p.hasMoreSegments()) return true;
            var rest = s;
            while (true) {
                if (matchSegs(p.s[p.i..], rest.s[rest.i..])) return true;
                if (rest.atEnd()) return false;
                _ = rest.nextSegment();
            }
        }
        if (s.atEnd()) return false;
        const sseg = s.nextSegment();
        if (!matchSegment(pseg, sseg)) return false;
    }
    return !s.hasMoreSegments();
}

fn matchSegment(pattern: []const u8, subject: []const u8) bool {
    return matchSegmentAt(pattern, 0, subject, 0);
}

fn matchSegmentAt(p: []const u8, pi: usize, s: []const u8, si: usize) bool {
    if (pi == p.len) return si == s.len;
    switch (p[pi]) {
        '*' => {
            var next = pi + 1;
            while (next < p.len and p[next] == '*') next += 1;
            var k = si;
            while (true) {
                if (matchSegmentAt(p, next, s, k)) return true;
                if (k >= s.len) return false;
                k += 1;
            }
        },
        '?' => {
            if (si >= s.len) return false;
            return matchSegmentAt(p, pi + 1, s, si + 1);
        },
        '[' => {
            var index = pi;
            const class = parseClass(p, &index) catch return false;
            if (si >= s.len) return false;
            if ((class[s[si] >> 3] & (@as(u8, 1) << @intCast(s[si] & 7))) == 0) return false;
            return matchSegmentAt(p, index, s, si + 1);
        },
        '\\' => {
            if (pi + 1 >= p.len or si >= s.len) return false;
            if (s[si] != p[pi + 1]) return false;
            return matchSegmentAt(p, pi + 2, s, si + 1);
        },
        else => {
            if (si >= s.len or s[si] != p[pi]) return false;
            return matchSegmentAt(p, pi + 1, s, si + 1);
        },
    }
}

const Pattern = struct {
    glob: []const u8,
    negated: bool,
    dir_only: bool,
    has_slash: bool,
};

const IgnoreFile = struct {
    base: []const u8,
    patterns: []const Pattern,
};

/// Stack of inherited `.gitignore` files for one walk. Patterns from deeper
/// directories win, matching Git's last-match-wins rule.
pub const IgnoreSet = struct {
    alloc: std.mem.Allocator,
    files: std.ArrayListUnmanaged(IgnoreFile) = .empty,

    pub fn init(alloc: std.mem.Allocator) IgnoreSet {
        return .{ .alloc = alloc };
    }

    pub fn push(self: *IgnoreSet, io: std.Io, dir: std.Io.Dir, rel: []const u8) void {
        var patterns: std.ArrayListUnmanaged(Pattern) = .empty;
        if (dir.readFileAlloc(io, ".gitignore", self.alloc, .limited(64 * 1024))) |data| {
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw| {
                var line = std.mem.trimEnd(u8, raw, "\r");
                if (line.len == 0 or line[0] == '#') continue;
                var negated = false;
                if (line[0] == '!') {
                    negated = true;
                    line = line[1..];
                    if (line.len == 0) continue;
                }
                var dir_only = false;
                if (line[line.len - 1] == '/') {
                    dir_only = true;
                    line = line[0 .. line.len - 1];
                    if (line.len == 0) continue;
                }
                var anchored = false;
                if (line[0] == '/') {
                    anchored = true;
                    line = line[1..];
                    if (line.len == 0) continue;
                }
                const has_slash = anchored or std.mem.indexOfScalar(u8, line, '/') != null;
                patterns.append(self.alloc, .{
                    .glob = line,
                    .negated = negated,
                    .dir_only = dir_only,
                    .has_slash = has_slash,
                }) catch break;
            }
        } else |_| {}
        self.files.append(self.alloc, .{
            .base = rel,
            .patterns = patterns.toOwnedSlice(self.alloc) catch &.{},
        }) catch {};
    }

    pub fn pop(self: *IgnoreSet) void {
        _ = self.files.pop();
    }

    pub fn isIgnored(self: *const IgnoreSet, rel: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.files.items) |file| {
            const sub = if (file.base.len == 0)
                rel
            else blk: {
                if (!std.mem.startsWith(u8, rel, file.base) or rel.len <= file.base.len or rel[file.base.len] != '/') continue;
                break :blk rel[file.base.len + 1 ..];
            };
            for (file.patterns) |pattern| {
                if (pattern.dir_only and !is_dir) continue;
                const subject = if (pattern.has_slash) sub else std.fs.path.basename(sub);
                if (globMatch(pattern.glob, subject)) ignored = !pattern.negated;
            }
        }
        return ignored;
    }
};

/// Process-global result of the one `rg`/`fd` availability probe. Tool
/// contexts are copied per call (and per parallel batch worker), so the probe
/// must live outside them or `--version` would run on every call.
var probe_state = std.atomic.Value(u8).init(0); // 0 = unchecked, 1 = probing, 2 = ready
var probe_rg_available: bool = false;
var probe_fd_name: ?[]const u8 = null;

fn probePrograms(io: std.Io) void {
    if (probe_state.load(.acquire) == 2) return;
    if (probe_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        probe_rg_available = programAvailable(io, "rg");
        probe_fd_name = if (programAvailable(io, "fd"))
            "fd"
        else if (programAvailable(io, "fdfind"))
            "fdfind"
        else
            null;
        probe_state.store(2, .release);
        return;
    }
    while (probe_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// Cached `rg`/`fd` probe. An explicit checked field (tests) wins over the
/// process-global cache; otherwise a context reads the shared result.
pub const ExternalCache = struct {
    rg_checked: bool = false,
    rg_available: bool = false,
    fd_checked: bool = false,
    fd_name: ?[]const u8 = null,

    pub fn rg(self: *ExternalCache, io: std.Io) ?[]const u8 {
        if (self.rg_checked) return if (self.rg_available) "rg" else null;
        probePrograms(io);
        self.rg_checked = true;
        self.rg_available = probe_rg_available;
        return if (self.rg_available) "rg" else null;
    }

    pub fn fd(self: *ExternalCache, io: std.Io) ?[]const u8 {
        if (self.fd_checked) return self.fd_name;
        probePrograms(io);
        self.fd_checked = true;
        self.fd_name = probe_fd_name;
        return self.fd_name;
    }
};

/// Probe a program through `std.process.spawn`, which resolves PATH without
/// the tools module inspecting the environment itself.
pub fn programAvailable(io: std.Io, program: []const u8) bool {
    const argv = [_][]const u8{ program, "--version" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "regex subset matches literals, classes and quantifiers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var re = try Regex.compile(alloc, "^const [a-z]+ = [0-9]+;$");
    defer re.deinit();
    try std.testing.expect(re.isMatch("const abc = 12;"));
    try std.testing.expect(!re.isMatch("var abc = 12;"));

    var dot = try Regex.compile(alloc, "a.c");
    defer dot.deinit();
    try std.testing.expect(dot.isMatch("xabcx"));
    try std.testing.expect(!dot.isMatch("ac"));

    var quant = try Regex.compile(alloc, "ab*c");
    defer quant.deinit();
    try std.testing.expect(quant.isMatch("ac"));
    try std.testing.expect(quant.isMatch("abbbc"));

    var plus = try Regex.compile(alloc, "ab+c");
    defer plus.deinit();
    try std.testing.expect(!plus.isMatch("ac"));
    try std.testing.expect(plus.isMatch("abc"));

    var optional = try Regex.compile(alloc, "colou?r");
    defer optional.deinit();
    try std.testing.expect(optional.isMatch("color"));
    try std.testing.expect(optional.isMatch("colour"));

    var escaped = try Regex.compile(alloc, "literal\\.dot");
    defer escaped.deinit();
    try std.testing.expect(escaped.isMatch("a literal.dot here"));
}

test "regex rejects unsupported constructs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try std.testing.expectError(error.UnsupportedGroup, Regex.compile(alloc, "(a)"));
    try std.testing.expectError(error.UnsupportedAlternation, Regex.compile(alloc, "a|b"));
    try std.testing.expectError(error.UnsupportedRepetition, Regex.compile(alloc, "a{2}"));
    try std.testing.expectError(error.UnsupportedBackreference, Regex.compile(alloc, "a\\1"));
}

test "gitignore subset and inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data =
        \\# comment
        \\*.log
        \\/root-only.txt
        \\build/
        \\!keep.log
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.gitignore", .data = "local.tmp\n" });

    var set = IgnoreSet.init(alloc);
    set.push(io, tmp.dir, "");
    try std.testing.expect(set.isIgnored("a.log", false));
    try std.testing.expect(!set.isIgnored("keep.log", false));
    try std.testing.expect(set.isIgnored("root-only.txt", false));
    try std.testing.expect(!set.isIgnored("sub/root-only.txt", false));
    try std.testing.expect(set.isIgnored("build", true));
    try std.testing.expect(!set.isIgnored("build", false));
    try std.testing.expect(!set.isIgnored("sub/local.tmp", false));

    const sub = try tmp.dir.openDir(io, "sub", .{ .iterate = true });
    defer sub.close(io);
    set.push(io, sub, "sub");
    try std.testing.expect(set.isIgnored("sub/deep/local.tmp", false));
    set.pop();
    set.pop();
}
