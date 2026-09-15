//! Glob matching for path grants (DECISIONS H100-H102).
//!
//! Supported syntax:
//!   `**`  matches any number of path segments (including none)
//!   `*`   matches any characters within a single path segment
//!   `?`   matches exactly one character within a segment
//! A leading `./` on either side is ignored. Matching is on `/`-separated
//! relative paths.

const std = @import("std");

/// Pure glob match. No allocation.
pub fn match(pattern: []const u8, path: []const u8) bool {
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
        if (c.i < c.s.len) c.i += 1; // skip '/'
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
            if (!p.hasMoreSegments()) return true; // trailing ** eats the rest
            // Try matching the remainder against every possible position.
            var rest = s;
            while (true) {
                if (matchSegs(p.s[p.i..], rest.s[rest.i..])) return true;
                if (rest.atEnd()) return false;
                _ = rest.nextSegment();
            }
        }
        if (s.atEnd()) return false;
        const sseg = s.nextSegment();
        if (!matchOneSegment(pseg, sseg)) return false;
    }
    return !s.hasMoreSegments();
}

/// Match a single path segment pattern (* and ? only, no **).
pub fn matchOneSegment(pattern: []const u8, subject: []const u8) bool {
    return matchInline(pattern, subject);
}

fn matchInline(p: []const u8, s: []const u8) bool {
    // Classic backtracking wildcard match.
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var star_si: usize = 0;
    while (si < s.len) {
        if (pi < p.len and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            star_si = si;
            pi += 1;
        } else if (star) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

test "match basic and recursive globs" {
    try std.testing.expect(match("**", "a/b/c.txt"));
    try std.testing.expect(match("**", "a.txt"));
    try std.testing.expect(match("src/**", "src/core/x.zig"));
    try std.testing.expect(match("src/**", "src/x.zig"));
    try std.testing.expect(!match("src/**", "other/x.zig"));
    try std.testing.expect(match("*.zig", "main.zig"));
    try std.testing.expect(!match("*.zig", "src/main.zig")); // * does not cross segments
    try std.testing.expect(match("src/*.zig", "src/main.zig"));
    try std.testing.expect(match("src/**/gen/*.c", "src/a/b/gen/x.c"));
    try std.testing.expect(match("te?t.txt", "test.txt"));
    try std.testing.expect(!match("te?t.txt", "testt.txt"));
    try std.testing.expect(match("./src/**", "src/x")); // ./ normalization
    try std.testing.expect(match("**", "")); // ** matches empty
    try std.testing.expect(!match("a/**", "b/a/c")); // anchored at start
}
