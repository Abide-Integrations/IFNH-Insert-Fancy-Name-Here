//! Secret redaction for model-facing output (DECISIONS H110, M0-T22).
//!
//! Tool outputs and provider error text pass through `redact` before they
//! reach the model context or the session log. Redaction covers:
//!   1. Exact secret values supplied by the host (API keys, tokens).
//!   2. Common credential shapes (sk-..., ghp_..., xox..., AKIA..., JWTs).
//! Redaction replaces matches with a fixed marker; it never fails.

const std = @import("std");

pub const marker = "[REDACTED]";

pub const Pattern = struct {
    prefix: []const u8,
    min_len: usize,
};

const known_patterns = [_]Pattern{
    .{ .prefix = "sk-", .min_len = 20 },
    .{ .prefix = "sk-ant-", .min_len = 20 },
    .{ .prefix = "ghp_", .min_len = 36 },
    .{ .prefix = "github_pat_", .min_len = 30 },
    .{ .prefix = "xoxb-", .min_len = 20 },
    .{ .prefix = "AKIA", .min_len = 20 },
    .{ .prefix = "Bearer ", .min_len = 24 },
    .{ .prefix = "eyJ", .min_len = 40 }, // JWT header start
};

fn isSecretChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

/// Replace every occurrence of `secret` in `text` with the marker.
fn replaceAll(arena: std.mem.Allocator, text: []const u8, secret: []const u8) ![]const u8 {
    if (secret.len < 8) return text; // too short to be a reliable secret
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, text, idx, secret)) |pos| {
        count += 1;
        idx = pos + secret.len;
    }
    if (count == 0) return text;

    const out_len = text.len - count * secret.len + count * marker.len;
    const out = try arena.alloc(u8, out_len);
    var w: usize = 0;
    var r: usize = 0;
    while (std.mem.indexOfPos(u8, text, r, secret)) |pos| {
        @memcpy(out[w .. w + pos - r], text[r..pos]);
        w += pos - r;
        @memcpy(out[w .. w + marker.len], marker);
        w += marker.len;
        r = pos + secret.len;
    }
    @memcpy(out[w..], text[r..]);
    return out;
}

/// Redact known secret values and credential-shaped strings.
pub fn redact(arena: std.mem.Allocator, text: []const u8, secrets: []const []const u8) []const u8 {
    var current = text;
    for (secrets) |s| {
        current = replaceAll(arena, current, s) catch return current;
    }
    // Pattern-based redaction: find candidate tokens and mask the rest.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var copied = true;
    while (i < current.len) {
        var matched: ?usize = null;
        for (known_patterns) |pat| {
            if (current.len - i >= pat.prefix.len and
                std.mem.startsWith(u8, current[i..], pat.prefix) and
                current.len - i >= pat.min_len)
            {
                // Extend to the end of the token.
                var j = i + pat.prefix.len;
                while (j < current.len and isSecretChar(current[j])) j += 1;
                if (j - i >= pat.min_len) matched = j;
                break;
            }
        }
        if (matched) |end| {
            out.appendSlice(arena, marker) catch return current;
            i = end;
            copied = false;
        } else {
            if (copied) {
                out.append(arena, current[i]) catch return current;
            }
            i += 1;
        }
    }
    if (copied and out.items.len == current.len) return current;
    return out.items;
}

test "exact secret values replaced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const out1 = redact(a, "key is sk-abc123def456ghi789 done", &.{});
    try std.testing.expect(std.mem.indexOf(u8, out1, "sk-abc123def456ghi789") == null);
    try std.testing.expect(std.mem.indexOf(u8, out1, marker) != null);

    const out2 = redact(a, "token=supersecretvalue12345 end", &.{"supersecretvalue12345"});
    try std.testing.expect(std.mem.indexOf(u8, out2, "supersecretvalue12345") == null);

    // Short strings are never treated as secrets.
    const out3 = redact(a, "short sk-1 here", &.{});
    try std.testing.expectEqualStrings("short sk-1 here", out3);
}

test "plain text untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "const x = skynet_function(); // totally fine";
    try std.testing.expectEqualStrings(text, redact(a, text, &.{}));
}
