//! Spend budget and usage-log summary (ACTIVE_PLAN C-06).
//!
//! `agents.budget_usd` is a circuit breaker checked before a turn starts, so a
//! blocked turn costs nothing. The usage log (`usage.jsonl`, one record per
//! turn) is the durable record; `summarize` folds it for `/usage` and to seed
//! the counter of a resumed session.

const std = @import("std");

/// True once `spent` has reached the configured budget. No budget never trips.
pub fn exceeded(spent: f64, budget: ?f64) bool {
    const b = budget orelse return false;
    return spent >= b;
}

/// The one line shown when the breaker trips (REPL and `ifnh ask` share it).
pub fn blockedMessage(buf: []u8, spent: f64, budget: f64) []const u8 {
    // Four decimals would print a tiny budget as $0.0000; show more digits then.
    const smallest = @min(spent, budget);
    const digits: usize = if (smallest > 0 and smallest < 0.01) 8 else 4;
    return std.fmt.bufPrint(buf, "[budget] ${d:.[2]} of ${d:.[2]} spent; raise agents.budget_usd or /usage to inspect\n", .{ spent, budget, digits }) catch "[budget] budget spent\n";
}

pub const ModelTotal = struct {
    model: []const u8,
    turns: usize = 0,
    cost_usd: f64 = 0,
    /// Turns recorded without a price (unknown model or older log records).
    unpriced_turns: usize = 0,
};

pub const Summary = struct {
    turns: usize = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cost_usd: f64 = 0,
    unpriced_turns: usize = 0,
    models: []const ModelTotal = &.{},
};

/// Fold `usage.jsonl` text. Malformed lines are skipped; records written
/// before C-06 have no `model`/`cost_usd` and count as unpriced.
pub fn summarize(arena: std.mem.Allocator, raw: []const u8) Summary {
    var s = Summary{};
    var models: std.ArrayListUnmanaged(ModelTotal) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (v != .object) continue;
        if (intField(v, "input_tokens")) |n| s.tokens_in += n;
        if (intField(v, "output_tokens")) |n| s.tokens_out += n;
        s.turns += 1;

        const priced = if (v.object.get("priced")) |p| p == .bool and p.bool else false;
        const cost: f64 = if (priced) numField(v, "cost_usd") else 0;
        if (priced) s.cost_usd += cost else s.unpriced_turns += 1;

        const name = if (v.object.get("model")) |m| (if (m == .string) m.string else "") else "";
        const slot = for (models.items) |*m| {
            if (std.mem.eql(u8, m.model, name)) break m;
        } else blk: {
            models.append(arena, .{ .model = name }) catch break :blk null;
            break :blk &models.items[models.items.len - 1];
        };
        if (slot) |m| {
            m.turns += 1;
            if (priced) m.cost_usd += cost else m.unpriced_turns += 1;
        }
    }
    s.models = models.items;
    return s;
}

fn intField(v: std.json.Value, key: []const u8) ?u64 {
    const f = v.object.get(key) orelse return null;
    return if (f == .integer and f.integer >= 0) @intCast(f.integer) else null;
}

fn numField(v: std.json.Value, key: []const u8) f64 {
    const f = v.object.get(key) orelse return 0;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => 0,
    };
}

/// `/usage` text. The `N turns, X tokens in, Y tokens out` prefix predates
/// C-06 and stays intact; the dollar part is appended.
pub fn formatSummary(arena: std.mem.Allocator, s: Summary, budget: ?f64) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("session usage: {d} turns, {d} tokens in, {d} tokens out, ${d:.4}", .{ s.turns, s.tokens_in, s.tokens_out, s.cost_usd });
    if (s.unpriced_turns > 0) try w.print(" ({d} unpriced)", .{s.unpriced_turns});
    if (budget) |b| try w.print(" (budget ${d:.4}, ${d:.4} remaining)", .{ b, @max(b - s.cost_usd, 0) });
    try w.writeByte('\n');
    if (s.models.len > 1) {
        try w.writeAll("by model:");
        for (s.models, 0..) |m, i| {
            try w.writeAll(if (i == 0) " " else ", ");
            const name = if (m.model.len > 0) m.model else "(unrecorded)";
            if (m.unpriced_turns == m.turns) {
                try w.print("{s} n/a ({d} turns)", .{ name, m.turns });
            } else {
                try w.print("{s} ${d:.4} ({d} turns)", .{ name, m.cost_usd, m.turns });
            }
        }
        try w.writeByte('\n');
    }
    return aw.written();
}

test "budget: exceeded is a >= check and null never trips" {
    try std.testing.expect(!exceeded(100.0, null));
    try std.testing.expect(!exceeded(0.0, 0.01));
    try std.testing.expect(exceeded(0.01, 0.01));
    try std.testing.expect(exceeded(0.02, 0.01));
    try std.testing.expect(exceeded(0.0, 0.0));
}

test "budget: blocked message names spend and the knob" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[budget] $0.0123 of $0.0100 spent; raise agents.budget_usd or /usage to inspect\n",
        blockedMessage(&buf, 0.0123, 0.01),
    );
    try std.testing.expectEqualStrings(
        "[budget] $0.00000075 of $0.00000010 spent; raise agents.budget_usd or /usage to inspect\n",
        blockedMessage(&buf, 0.00000075, 0.0000001),
    );
}

test "budget: usage summary folds records, models and old-format lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw =
        \\{"ts_ms":1,"input_tokens":10,"output_tokens":5,"model":"claude-sonnet-4-6","cost_usd":0.25,"priced":true}
        \\{"ts_ms":2,"input_tokens":20,"output_tokens":6,"model":"mystery","cost_usd":0,"priced":false}
        \\not json
        \\{"ts_ms":3,"input_tokens":1,"output_tokens":1}
        \\{"ts_ms":4,"input_tokens":2,"output_tokens":2,"model":"claude-sonnet-4-6","cost_usd":0.5,"priced":true}
        \\
    ;
    const s = summarize(arena, raw);
    try std.testing.expectEqual(@as(usize, 4), s.turns);
    try std.testing.expectEqual(@as(u64, 33), s.tokens_in);
    try std.testing.expectEqual(@as(u64, 14), s.tokens_out);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), s.cost_usd, 1e-12);
    try std.testing.expectEqual(@as(usize, 2), s.unpriced_turns);
    try std.testing.expectEqual(@as(usize, 3), s.models.len);

    const text = try formatSummary(arena, s, 1.0);
    try std.testing.expect(std.mem.startsWith(u8, text, "session usage: 4 turns, 33 tokens in, 14 tokens out, $0.7500"));
    try std.testing.expect(std.mem.indexOf(u8, text, "(budget $1.0000, $0.2500 remaining)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "by model: claude-sonnet-4-6 $0.7500 (2 turns), mystery n/a (1 turns)") != null);

    const one = try formatSummary(arena, summarize(arena, "{\"input_tokens\":1,\"output_tokens\":2,\"model\":\"m\",\"cost_usd\":0.1,\"priced\":true}\n"), null);
    try std.testing.expectEqualStrings("session usage: 1 turns, 1 tokens in, 2 tokens out, $0.1000\n", one);
}
