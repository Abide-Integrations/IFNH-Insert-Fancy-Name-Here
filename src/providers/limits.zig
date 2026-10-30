//! Per-model default output-token limits (ACTIVE_PLAN B-10).
//!
//! Used only by adapters that must send an explicit cap. OpenAI has no
//! entries on purpose: `max_tokens` is deprecated for its reasoning models
//! and the service already picks a per-model default, so omitting the field
//! is the correct default there.

const std = @import("std");

pub const Rule = struct { prefix: []const u8, max_output_tokens: u32 };

/// Matched by longest prefix on the model id, so order does not matter.
pub const rules = [_]Rule{
    .{ .prefix = "claude-3-5-", .max_output_tokens = 8192 },
    .{ .prefix = "claude-3-7-", .max_output_tokens = 8192 },
    .{ .prefix = "claude-sonnet-4", .max_output_tokens = 8192 },
    .{ .prefix = "claude-opus-4", .max_output_tokens = 8192 },
    .{ .prefix = "claude-haiku-4", .max_output_tokens = 8192 },
    .{ .prefix = "claude-3-opus", .max_output_tokens = 4096 },
    .{ .prefix = "claude-3-haiku", .max_output_tokens = 4096 },
};

/// Default cap for `model` (the id after the last '/'), or null when no
/// rule matches. Does not allocate.
pub fn defaultMaxOutputTokens(model: []const u8) ?u32 {
    const id = if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
    var best: ?Rule = null;
    for (rules) |r| {
        if (!std.mem.startsWith(u8, id, r.prefix)) continue;
        if (best == null or r.prefix.len > best.?.prefix.len) best = r;
    }
    return if (best) |r| r.max_output_tokens else null;
}

test "limits match by prefix" {
    try std.testing.expectEqual(@as(?u32, 8192), defaultMaxOutputTokens("claude-sonnet-4-6"));
    try std.testing.expectEqual(@as(?u32, 8192), defaultMaxOutputTokens("anthropic/claude-sonnet-4-6"));
    try std.testing.expectEqual(@as(?u32, 4096), defaultMaxOutputTokens("claude-3-opus-20240229"));
    try std.testing.expectEqual(@as(?u32, null), defaultMaxOutputTokens("gpt-5.1"));
    try std.testing.expectEqual(@as(?u32, null), defaultMaxOutputTokens("claude-test"));
}
