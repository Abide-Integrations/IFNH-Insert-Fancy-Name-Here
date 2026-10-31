//! Model price table and cost arithmetic (ACTIVE_PLAN C-06).
//!
//! The table is data: `pricing.json`, embedded into the binary. List prices
//! in USD per million tokens, from the vendors' public pricing pages:
//!   https://docs.anthropic.com/en/docs/about-claude/pricing
//!   https://openai.com/api/pricing/
//! Matching mirrors `limits.zig`: the model id after the last '/', compared
//! case-insensitively, longest `match` prefix wins. The `"*"` entry has all
//! prices null and means "unpriced"; so does a model nothing matches.

const std = @import("std");
const core_types = @import("../core/types.zig");

const table_json = @embedFile("pricing.json");

/// USD per million tokens. A null cache price falls back to `input`.
pub const Price = struct {
    input: f64,
    output: f64,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
    /// OpenAI-style usage: `input_tokens` already contains the cached tokens.
    /// Anthropic reports cache reads and writes separately from input.
    input_includes_cache: bool = false,
};

pub const Cost = struct {
    usd: f64 = 0,
    priced: bool = false,
};

const Entry = struct {
    match: []const u8,
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
    input_includes_cache: bool = false,
};

const Table = struct {
    currency: []const u8 = "USD",
    per: []const u8 = "million_tokens",
    models: []const Entry = &.{},
};

/// Price for `model`, or null when it is unknown or explicitly unpriced.
/// Parses the embedded table into a stack buffer; no allocation escapes.
pub fn lookup(model: []const u8) ?Price {
    var buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const table = std.json.parseFromSliceLeaky(Table, fba.allocator(), table_json, .{ .ignore_unknown_fields = true }) catch return null;
    return lookupIn(table.models, model);
}

fn lookupIn(models: []const Entry, model: []const u8) ?Price {
    const id = if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
    var best: ?Entry = null;
    for (models) |e| {
        if (std.mem.eql(u8, e.match, "*")) continue;
        if (e.match.len > id.len or !std.ascii.eqlIgnoreCase(e.match, id[0..e.match.len])) continue;
        if (best == null or e.match.len > best.?.match.len) best = e;
    }
    const e = best orelse return null;
    return .{
        .input = e.input orelse return null,
        .output = e.output orelse return null,
        .cache_read = e.cache_read,
        .cache_write = e.cache_write,
        .input_includes_cache = e.input_includes_cache,
    };
}

/// Cost of `usage` on `model`. Unknown or unpriced models yield `priced = false`.
pub fn cost(model: []const u8, usage: core_types.Usage) Cost {
    const p = lookup(model) orelse return .{};
    return .{ .usd = costFor(p, usage), .priced = true };
}

pub fn costFor(p: Price, u: core_types.Usage) f64 {
    const fresh_in: u64 = if (p.input_includes_cache) u.input_tokens -| u.cache_read_tokens else u.input_tokens;
    const per_m = 1_000_000.0;
    return (@as(f64, @floatFromInt(fresh_in)) * p.input +
        @as(f64, @floatFromInt(u.output_tokens)) * p.output +
        @as(f64, @floatFromInt(u.cache_read_tokens)) * (p.cache_read orelse p.input) +
        @as(f64, @floatFromInt(u.cache_write_tokens)) * (p.cache_write orelse p.input)) / per_m;
}

/// Dollar amount as the UI shows it: `$0.0123`, `$0.00` under a tenth of a cent.
pub fn formatUsd(buf: []u8, usd: f64) []const u8 {
    if (usd < 0.001) return std.fmt.bufPrint(buf, "$0.00", .{}) catch "$0.00";
    return std.fmt.bufPrint(buf, "${d:.4}", .{usd}) catch "$?";
}

test "pricing: longest prefix wins, provider prefix and case are ignored" {
    try std.testing.expectEqual(@as(f64, 3.0), lookup("claude-sonnet-4-6").?.input);
    try std.testing.expectEqual(@as(f64, 3.0), lookup("anthropic/Claude-Sonnet-4-20250514").?.input);
    // claude-opus-4-5 is a longer prefix than claude-opus-4.
    try std.testing.expectEqual(@as(f64, 5.0), lookup("claude-opus-4-5-20251101").?.input);
    try std.testing.expectEqual(@as(f64, 15.0), lookup("claude-opus-4-1").?.input);
    // gpt-4.1-mini must not fall into the gpt-4.1 row.
    try std.testing.expectEqual(@as(f64, 0.4), lookup("openai/gpt-4.1-mini-2025-04-14").?.input);
    try std.testing.expectEqual(@as(f64, 2.0), lookup("gpt-4.1").?.input);
    try std.testing.expectEqual(@as(f64, 1.1), lookup("o4-mini").?.input);
}

test "pricing: unknown, empty and wildcard models are unpriced" {
    try std.testing.expect(lookup("llama-3.3-70b-versatile") == null);
    try std.testing.expect(lookup("") == null);
    const c = cost("mystery-model", .{ .input_tokens = 1000, .output_tokens = 1000 });
    try std.testing.expect(!c.priced);
    try std.testing.expectEqual(@as(f64, 0), c.usd);
}

test "pricing: anthropic cache tokens are priced separately from input" {
    // 1M fresh in ($3) + 1M out ($15) + 1M read ($0.30) + 1M write ($3.75).
    const c = cost("claude-sonnet-4-6", .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
        .cache_write_tokens = 1_000_000,
    });
    try std.testing.expect(c.priced);
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), c.usd, 1e-9);
}

test "pricing: openai cached tokens are carved out of input" {
    // 1M prompt tokens of which 400k cached: 600k * $2 + 400k * $0.50, plus 100k out * $8.
    const c = cost("gpt-4.1", .{ .input_tokens = 1_000_000, .cache_read_tokens = 400_000, .output_tokens = 100_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.2 + 0.2 + 0.8), c.usd, 1e-9);
}

test "pricing: usd formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.00", formatUsd(&buf, 0));
    try std.testing.expectEqualStrings("$0.00", formatUsd(&buf, 0.0009));
    try std.testing.expectEqualStrings("$0.0123", formatUsd(&buf, 0.0123));
    try std.testing.expectEqualStrings("$1.5000", formatUsd(&buf, 1.5));
}
