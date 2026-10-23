//! Context compaction (M1-T08, DECISIONS C36-C37, PLAN §24).
//!
//! Trigger: automatic when the bounded history exceeds a token estimate
//! threshold. Compaction runs a summarization request over the history
//! and produces a structured handoff preserved as a durable checkpoint
//! (requirements/decisions/plan/done/outstanding). The handoff replaces
//! the summarized portion of history; the session event log keeps a
//! `note` event recording the compaction.

const std = @import("std");
const core_types = @import("types.zig");
const agent_engine = @import("agent/engine.zig");

/// Rough token estimate: ~4 chars per token (fx is also tokenizer-free).
pub fn estimateTokens(text: []const u8) usize {
    return text.len / 4 + 1;
}

pub const Plan = struct {
    /// Number of leading messages to summarize (excluding preserved tail).
    summarize_count: usize,
    estimated_tokens: usize,
    should_compact: bool,
};

/// Assumed context budget when neither an explicit override nor a model
/// window is known.
pub const default_threshold_tokens: usize = 96_000;

/// Messages always preserved after the summarized prefix. A cut may keep
/// more so the tail begins on a turn boundary.
const keep_tail = 2;

/// Compaction trigger: an explicit `context.max_context_tokens` budget wins;
/// otherwise derive 3/4 of an advertised model window; otherwise fall back
/// to the historical 96k default.
pub fn thresholdTokens(configured: ?u32, advertised_window: ?u64) usize {
    if (configured) |v| {
        if (v > 0) return v;
    }
    if (advertised_window) |w| {
        if (w > 0) return @intCast(@max(w / 4 * 3, 4096));
    }
    return default_threshold_tokens;
}

fn estimateHistoryTokens(history: []const core_types.ChatMessage) usize {
    var total: usize = 0;
    for (history) |m| {
        total += estimateTokens(m.content);
        if (m.tool_calls_json) |t| total += estimateTokens(t);
    }
    return total;
}

/// A turn boundary starts a user/system message and does not fall inside an
/// assistant tool round. A round is one unit: the assistant message carrying
/// `tool_calls` plus the consecutive tool messages answering it.
fn isTurnBoundary(history: []const core_types.ChatMessage, index: usize) bool {
    if (index >= history.len) return false;
    switch (history[index].role) {
        .user, .system => {},
        else => return false,
    }
    for (history[0..index], 0..) |m, j| {
        if (m.role != .assistant or m.tool_calls_json == null) continue;
        var k = j + 1;
        while (k < history.len and history[k].role == .tool) : (k += 1) {
            if (k >= index) return false; // round straddles the cut
        }
    }
    return true;
}

/// Largest valid cut that preserves at least `keep_tail` messages; 0 when
/// no boundary exists (whole history is one turn, or nothing to summarize).
fn boundaryCut(history: []const core_types.ChatMessage) usize {
    if (history.len <= keep_tail) return 0;
    var cut = history.len - keep_tail;
    while (cut > 0) : (cut -= 1) {
        if (isTurnBoundary(history, cut)) return cut;
    }
    return 0;
}

/// Decide whether to compact: history text over `threshold_tokens` and
/// enough messages to be worth it. The tail starts on a turn boundary.
pub fn planCompaction(history: []const core_types.ChatMessage, threshold_tokens: usize, compact_fraction: f64) Plan {
    const total = estimateHistoryTokens(history);
    const trigger = @max(threshold_tokens, 1);
    const at = total >= trigger;
    const summarize = boundaryCut(history);
    const worth = total >= trigger * 2 or @as(f64, @floatFromInt(total)) >= @as(f64, @floatFromInt(trigger)) * (1.0 + compact_fraction);
    const ok = at and worth and summarize > 0;
    return .{
        .summarize_count = if (ok) summarize else 0,
        .estimated_tokens = total,
        .should_compact = ok,
    };
}

pub const compact_error = error{
    NothingToCompact,
    CompactionFailed,
} || anyerror;

pub const Result = struct {
    handoff: []const u8,
    /// History after compaction: [summary message] + preserved tail.
    history: []core_types.ChatMessage,
    tokens_before: usize,
    tokens_after: usize,
};

const compaction_instructions =
    \\Summarize the conversation so far into a compact handoff document for
    \\a future agent instance. Preserve exactly these sections, in order:
    \\Requirements (what was asked), Decisions (made so far), Constraints,
    \\Current plan, Completed work, Outstanding work, Key files (paths only),
    \\Open questions. Be terse; keep all concrete details (paths, names,
    \\numbers). Do not narrate.
    \\
;

/// Compact a history in place: summarize the leading portion via the
/// provider, keep the tail, return the new history (caller's arena).
pub fn compact(
    arena: std.mem.Allocator,
    io: std.Io,
    pcfg: agent_engine.ProviderConfig,
    history: *std.ArrayListUnmanaged(core_types.ChatMessage),
    redactions: []const []const u8,
) compact_error!Result {
    // Forced compaction (`/compact`) uses the same boundary rule as the
    // automatic path, so it cannot leave an orphaned tool tail either.
    const summarize_count = boundaryCut(history.items);
    if (summarize_count == 0) return error.NothingToCompact;
    const tokens_before = estimateHistoryTokens(history.items);

    // Build the summarization transcript from the leading portion.
    var transcript: std.ArrayListUnmanaged(u8) = .empty;
    for (history.items[0..summarize_count]) |m| {
        switch (m.role) {
            .user => try transcript.print(arena, "USER: {s}\n", .{m.content}),
            .assistant => try transcript.print(arena, "ASSISTANT: {s}\n", .{m.content}),
            .tool => try transcript.print(arena, "TOOL({s}): {s}\n", .{ m.tool_name orelse "?", m.content }),
            .system => {},
        }
    }

    // One non-streaming-ish request: reuse the streaming provider and
    // collect the full reply.
    var reply: std.ArrayListUnmanaged(u8) = .empty;
    const SinkCtx = struct {
        out: *std.ArrayListUnmanaged(u8),
        arena: std.mem.Allocator,
        failed: bool = false,
        fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .content_delta => |d| self.out.appendSlice(self.arena, d) catch {},
                .failure => self.failed = true,
                else => {},
            }
        }
    };
    var sink_ctx = SinkCtx{ .out = &reply, .arena = arena };
    var cancel = std.atomic.Value(bool).init(false);

    var msgs: [2]core_types.ChatMessage = .{
        .{ .role = .system, .content = compaction_instructions },
        .{ .role = .user, .content = transcript.items },
    };
    try pcfg.provider.stream(arena, io, .{
        .model = pcfg.model,
        .base_url = pcfg.base_url,
        .api_key = pcfg.api_key,
        .system = compaction_instructions,
        .messages = msgs[0..],
        .cancel = &cancel,
    }, .{ .ctx = &sink_ctx, .emit_fn = SinkCtx.emit });

    if (sink_ctx.failed or reply.items.len == 0) return error.CompactionFailed;

    // New history: user message carrying the handoff + preserved tail.
    var new_history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    const handoff = redact_mod_redact(arena, reply.items, redactions);
    try new_history.append(arena, .{
        .role = .user,
        .content = std.fmt.allocPrint(arena, "[context compaction handoff]\n{s}", .{handoff}) catch handoff,
    });
    for (history.items[summarize_count..]) |m| {
        try new_history.append(arena, m);
    }

    var tokens_after: usize = 0;
    for (new_history.items) |m| tokens_after += estimateTokens(m.content);

    return .{
        .handoff = handoff,
        .history = new_history.items,
        .tokens_before = tokens_before,
        .tokens_after = tokens_after,
    };
}

// small local alias to avoid an import cycle comment
const redact_mod_redact = @import("redact.zig").redact;

// ---------------------------------------------------------------- tests

test "token estimate and plan thresholds" {
    try std.testing.expect(estimateTokens("") == 1);
    try std.testing.expectEqual(@as(usize, 26), estimateTokens("x" ** 100));

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    defer history.deinit(std.testing.allocator);
    for (0..10) |_| {
        try history.append(std.testing.allocator, .{ .role = .user, .content = "y" ** 4000 });
    }
    const plan = planCompaction(history.items, 1000, 0.8);
    try std.testing.expect(plan.should_compact);
    try std.testing.expectEqual(@as(usize, 8), plan.summarize_count);

    const small = planCompaction(history.items[0..2], 1000, 0.8);
    try std.testing.expect(!small.should_compact); // nothing left after tail
}

test "compaction backs the cut up to the preceding user turn" {
    const history = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\"}]" },
        .{ .role = .tool, .content = "r1", .tool_call_id = "t1" },
        .{ .role = .user, .content = "second" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t2\",\"name\":\"read\"}]" },
        .{ .role = .tool, .content = "r2", .tool_call_id = "t2" },
    };
    const plan = planCompaction(&history, 1, 0.8);
    try std.testing.expect(plan.should_compact);
    // len - 2 lands on the last assistant; back up to "second".
    try std.testing.expectEqual(@as(usize, 3), plan.summarize_count);
    try std.testing.expectEqual(core_types.ChatRole.user, history[plan.summarize_count].role);
}

test "compaction never splits an assistant tool round" {
    const history = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\"}]" },
        .{ .role = .tool, .content = "r1", .tool_call_id = "t1" },
        .{ .role = .user, .content = "u2" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t2\",\"name\":\"read\"}]" },
        .{ .role = .tool, .content = "r2", .tool_call_id = "t2" },
    };
    const plan = planCompaction(&history, 1, 0.8);
    try std.testing.expect(plan.should_compact);
    // The assistant(t2) + tool(t2) pair stays together in the tail.
    try std.testing.expect(history[plan.summarize_count].role != .tool);
    try std.testing.expect(history[plan.summarize_count - 1].role != .assistant);
    try std.testing.expectEqualStrings("t2", history[plan.summarize_count + 2].tool_call_id.?);
}

test "compaction refuses when the only turn is the last one" {
    const history = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "u" ** 4000 },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\"}]" },
        .{ .role = .tool, .content = "r" ** 4000, .tool_call_id = "t1" },
    };
    const plan = planCompaction(&history, 100, 0.8);
    try std.testing.expect(!plan.should_compact);
    try std.testing.expectEqual(@as(usize, 0), plan.summarize_count);
}

test "compaction threshold follows the configured window" {
    try std.testing.expectEqual(default_threshold_tokens, thresholdTokens(null, null));
    try std.testing.expectEqual(@as(usize, 32_000), thresholdTokens(32_000, null));
    try std.testing.expectEqual(@as(usize, 150_000), thresholdTokens(null, 200_000));
    try std.testing.expectEqual(@as(usize, 4096), thresholdTokens(null, 1000));
    try std.testing.expectEqual(@as(usize, 32_000), thresholdTokens(32_000, 200_000));
}

test "compaction fails cleanly when provider fails" {
    const io = std.testing.io;
    const testing = @import("agent/testing.zig");
    var fake = testing.Fake{ .script = &.{
        &.{.{ .failure = .{ .kind = .server_error, .message = "down" } }},
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    for (0..6) |_| {
        try history.append(arena, .{ .role = .user, .content = "z" ** 3000 });
    }
    try std.testing.expectError(error.CompactionFailed, compact(arena, io, .{
        .provider = fake.provider(),
        .model = "fake",
        .base_url = "",
        .api_key = "",
    }, &history, &.{}));
}
