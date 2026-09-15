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

/// Decide whether to compact: history text over `threshold_tokens` and
/// enough messages to be worth it. The last 2 messages are always kept.
pub fn planCompaction(history: []const core_types.ChatMessage, threshold_tokens: usize, compact_fraction: f64) Plan {
    var total: usize = 0;
    for (history) |m| {
        total += estimateTokens(m.content);
        if (m.tool_calls_json) |t| total += estimateTokens(t);
    }
    const trigger = @max(threshold_tokens, 1);
    const at = total >= trigger;
    const summarize = if (history.len > 4) history.len - 2 else 0;
    const worth = total >= trigger * 2 or @as(f64, @floatFromInt(total)) >= @as(f64, @floatFromInt(trigger)) * (1.0 + compact_fraction);
    return .{
        .summarize_count = if (at and worth) summarize else 0,
        .estimated_tokens = total,
        .should_compact = at and worth and summarize > 0,
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
    const plan = planCompaction(history.items, 1, 1.0); // force
    if (plan.summarize_count == 0) return error.NothingToCompact;

    // Build the summarization transcript from the leading portion.
    var transcript: std.ArrayListUnmanaged(u8) = .empty;
    for (history.items[0..plan.summarize_count]) |m| {
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
    for (history.items[plan.summarize_count..]) |m| {
        try new_history.append(arena, m);
    }

    var tokens_after: usize = 0;
    for (new_history.items) |m| tokens_after += estimateTokens(m.content);

    return .{
        .handoff = handoff,
        .history = new_history.items,
        .tokens_before = plan.estimated_tokens,
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
        .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "",
    }, &history, &.{}));
}
