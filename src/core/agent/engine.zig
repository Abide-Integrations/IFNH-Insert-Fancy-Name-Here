//! Agent turn engine (DESIGN §6, DECISIONS section E rows for M0).
//!
//! One turn: stream from the provider, emit text deltas through callbacks,
//! execute tool calls (permissions + journal via tools/tool.zig), feed
//! results back, repeat until the model stops calling tools or a limit is
//! hit. History is grown in place: assistant and tool messages append to
//! the caller's list so sessions can persist them.

const std = @import("std");
const core_types = @import("../types.zig");
const provider_mod = @import("../../providers/provider.zig");
const tool_mod = @import("../../tools/tool.zig");
const redact_mod = @import("../redact.zig");
const trace_mod = @import("../trace.zig");

pub const max_tool_rounds_default: usize = 25;
/// Upper bound on a server-provided `Retry-After` delay. Keeps a misbehaving
/// or hostile endpoint from stalling a turn indefinitely.
pub const max_retry_after_s: u64 = 60;

/// Delay before the next provider attempt. `Retry-After` wins over the
/// exponential backoff and is capped; otherwise backoff doubles from 1 s and
/// caps at 16 s.
pub fn retryDelaySeconds(attempt: usize, retry_after_s: ?u32) u64 {
    if (retry_after_s) |seconds| return @min(@as(u64, seconds), max_retry_after_s);
    const shift: u6 = @intCast(@min(attempt, 4));
    return @min(@as(u64, 1) << shift, 16);
}

pub const ProviderConfig = struct {
    provider: provider_mod.Provider,
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    /// Session-owned client shared by every round (B-02).
    client: ?*std.http.Client = null,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// Streaming text delta.
    on_text: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// A tool call is about to execute.
    on_tool_start: *const fn (ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void,
    /// A tool call finished.
    on_tool_result: *const fn (ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void,
    /// Non-fatal notice (permission denials, truncation...).
    on_notice: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Optional: an assistant message (text plus any tool calls) was appended
    /// to history. Persistent UIs record it here, not from `on_text`.
    on_assistant_message: ?*const fn (ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void = null,
};

pub const Status = enum { completed, failed, cancelled };

pub const Outcome = struct {
    status: Status,
    reply: []const u8,
    tool_rounds: usize = 0,
    tool_calls: usize = 0,
    usage: core_types.Usage = .{},
    error_message: []const u8 = "",
};

const Collector = struct {
    arena: std.mem.Allocator,
    /// Receives each text delta as it arrives (live streaming to the UI).
    callbacks: Callbacks,
    text: std.ArrayListUnmanaged(u8) = .empty,
    tool_calls: std.ArrayListUnmanaged(core_types.ToolCall) = .empty,
    usage: core_types.Usage = .{},
    failure: ?core_types.ProviderFailure = null,

    fn emit(ctx_ptr: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx_ptr));
        switch (ev) {
            .content_delta => |d| {
                self.text.appendSlice(self.arena, d) catch {};
                // The delta is only valid for this call; UIs must copy or
                // write it immediately.
                self.callbacks.on_text(self.callbacks.ctx, d);
            },
            .reasoning_delta => {},
            .tool_call => |tc| {
                const duped_id = self.arena.dupe(u8, tc.id) catch return;
                const duped_name = self.arena.dupe(u8, tc.name) catch return;
                const duped_args = self.arena.dupe(u8, tc.arguments_json) catch return;
                self.tool_calls.append(self.arena, .{
                    .id = duped_id,
                    .name = duped_name,
                    .arguments_json = duped_args,
                }) catch {};
            },
            .usage => |u| {
                self.usage.input_tokens += u.input_tokens;
                self.usage.output_tokens += u.output_tokens;
                self.usage.cache_read_tokens += u.cache_read_tokens;
                self.usage.cache_write_tokens += u.cache_write_tokens;
            },
            .done => {},
            .failure => |f| {
                self.failure = .{
                    .kind = f.kind,
                    .message = self.arena.dupe(u8, f.message) catch "provider failure",
                    .retry_after_s = f.retry_after_s,
                };
            },
        }
    }
};

fn sinkEmit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
    Collector.emit(ctx, ev);
}

/// Delivers events to the collector and closes the time-to-first-token span
/// on the first event of a provider round.
const TraceSink = struct {
    collector: *Collector,
    ttft: trace_mod.Span,
    seen: bool = false,

    fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *TraceSink = @ptrCast(@alignCast(ctx));
        if (!self.seen) {
            self.seen = true;
            self.ttft.end("");
        }
        Collector.emit(self.collector, ev);
    }
};

pub const RunParams = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    pcfg: ProviderConfig,
    system: []const u8,
    /// Byte length of the byte-stable system-prompt prefix (B-03).
    system_stable_len: usize = 0,
    history: *std.ArrayListUnmanaged(core_types.ChatMessage),
    tool_ctx: *tool_mod.ToolContext,
    callbacks: Callbacks,
    cancel: *std.atomic.Value(bool),
    max_tool_rounds: usize = max_tool_rounds_default,
    /// Chat-only mode: no tool schemas advertised (models without tool
    /// calling still work for Q&A).
    include_tools: bool = true,
    max_retries: usize = 3,
    /// Secret strings redacted from tool output before it enters history.
    redactions: []const []const u8 = &.{},
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    /// Optional per-session timing trace (B-01).
    trace: ?*trace_mod.Trace = null,
};

/// Run one agent turn. Appends assistant/tool messages to `history`.
pub fn runTurn(p: RunParams) !Outcome {
    var total_usage = core_types.Usage{};
    var rounds: usize = 0;
    var total_calls: usize = 0;
    var last_reply: []const u8 = "";
    var tool_total_ns: i96 = 0;
    defer if (p.trace) |t| {
        if (t.enabled) {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}ms", .{@divTrunc(tool_total_ns, std.time.ns_per_ms)}) catch "";
            t.note("turn.total_tools", text);
        }
    };

    while (rounds < p.max_tool_rounds) : (rounds += 1) {
        if (p.cancel.load(.acquire)) {
            return .{ .status = .cancelled, .reply = last_reply, .tool_rounds = rounds, .tool_calls = total_calls, .usage = total_usage };
        }

        var collector = Collector{ .arena = p.arena, .callbacks = p.callbacks };
        const tools: []const core_types.ToolSpec = if (p.include_tools) &tool_mod.specs else &.{};
        var round_span = trace_mod.Span.begin(p.trace, "turn.provider_round");
        const ttft_span = trace_mod.Span.begin(p.trace, "provider.ttft");
        // One sink for the whole round: a retry must not end the TTFT span a
        // second time when the replacement attempt emits its first event.
        var trace_sink = TraceSink{ .collector = &collector, .ttft = ttft_span };
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            collector = Collector{ .arena = p.arena, .callbacks = p.callbacks };
            trace_sink.collector = &collector;
            try p.pcfg.provider.stream(p.arena, p.io, .{
                .model = p.pcfg.model,
                .base_url = p.pcfg.base_url,
                .api_key = p.pcfg.api_key,
                .system = p.system,
                .system_stable_len = p.system_stable_len,
                .messages = p.history.items,
                .tools = tools,
                .temperature = p.temperature,
                .max_output_tokens = p.max_output_tokens,
                .cancel = p.cancel,
                .trace = p.trace,
                .client = p.pcfg.client,
            }, .{ .ctx = &trace_sink, .emit_fn = TraceSink.emit });
            if (collector.failure) |f| {
                if (core_types.isRetryable(f.kind) and attempt < p.max_retries and
                    collector.text.items.len == 0 and !p.cancel.load(.acquire))
                {
                    sleepSeconds(p.io, retryDelaySeconds(attempt, f.retry_after_s)) catch break;
                    continue;
                }
            }
            break;
        }
        round_span.end("");

        total_usage.input_tokens += collector.usage.input_tokens;
        total_usage.output_tokens += collector.usage.output_tokens;
        total_usage.cache_read_tokens += collector.usage.cache_read_tokens;
        total_usage.cache_write_tokens += collector.usage.cache_write_tokens;

        // Keep the text streamed before a failure so the caller can show (and
        // roll back) a partial reply instead of losing it.
        const reply = collector.text.items;
        last_reply = reply;

        if (collector.failure) |f| {
            // An interrupted stream is a cancellation, not a provider error:
            // the REPL prints "(interrupted)" and rolls the turn back.
            if (f.kind == .cancelled) {
                return .{ .status = .cancelled, .reply = last_reply, .tool_rounds = rounds, .tool_calls = total_calls, .usage = total_usage };
            }
            return .{
                .status = .failed,
                .reply = last_reply,
                .tool_rounds = rounds,
                .tool_calls = total_calls,
                .usage = total_usage,
                .error_message = f.message,
            };
        }

        if (collector.tool_calls.items.len == 0) {
            try p.history.append(p.arena, .{ .role = .assistant, .content = reply });
            if (p.callbacks.on_assistant_message) |cb| cb(p.callbacks.ctx, reply, null);
            return .{ .status = .completed, .reply = reply, .tool_rounds = rounds + 1, .tool_calls = total_calls, .usage = total_usage };
        }

        // Assistant message with tool calls; remember calls for the wire.
        var aw: std.Io.Writer.Allocating = .init(p.arena);
        const w = &aw.writer;
        try w.writeByte('[');
        for (collector.tool_calls.items, 0..) |tc, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try std.json.Stringify.value(tc.id, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(tc.name, .{}, w);
            try w.writeAll(",\"arguments_json\":");
            try std.json.Stringify.value(tc.arguments_json, .{}, w);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        const tc_json = aw.written();

        try p.history.append(p.arena, .{
            .role = .assistant,
            .content = reply,
            .tool_calls_json = tc_json,
        });
        if (p.callbacks.on_assistant_message) |cb| cb(p.callbacks.ctx, reply, tc_json);

        // Execute tool calls; consecutive `agent` calls run in parallel
        // (E58), everything else sequentially, results appended in order.
        const calls = collector.tool_calls.items;
        const tools_span = trace_mod.Span.begin(p.trace, "turn.tools_round");
        const tool_start: ?std.Io.Timestamp = if (p.trace) |t|
            (if (t.enabled) std.Io.Timestamp.now(t.io, .awake) else null)
        else
            null;
        var i: usize = 0;
        while (i < calls.len) {
            if (p.cancel.load(.acquire)) {
                return .{ .status = .cancelled, .reply = last_reply, .tool_rounds = rounds, .tool_calls = total_calls, .usage = total_usage };
            }
            if (isAgentCall(calls[i])) {
                var j = i + 1;
                while (j < calls.len and isAgentCall(calls[j])) j += 1;
                const batch = calls[i..j];
                const results = if (batch.len > 1)
                    try runAgentBatch(p, batch)
                else blk: {
                    const one = try p.arena.alloc(tool_mod.ToolResult, 1);
                    one[0] = executeOne(p, batch[0]);
                    total_calls += 1;
                    break :blk one;
                };
                for (batch, results) |tc, result| {
                    p.callbacks.on_tool_start(p.callbacks.ctx, tc.id, tc.name, tc.arguments_json);
                    p.callbacks.on_tool_result(p.callbacks.ctx, tc.id, tc.name, result.status, result.output);
                    if (result.status == .denied) {
                        p.callbacks.on_notice(p.callbacks.ctx, result.output);
                    }
                    try p.history.append(p.arena, .{
                        .role = .tool,
                        .content = result.output,
                        .tool_call_id = tc.id,
                        .tool_name = tc.name,
                    });
                }
                total_calls += batch.len;
                i = j;
            } else {
                const result = executeOne(p, calls[i]);
                total_calls += 1;
                p.callbacks.on_tool_start(p.callbacks.ctx, calls[i].id, calls[i].name, calls[i].arguments_json);
                p.callbacks.on_tool_result(p.callbacks.ctx, calls[i].id, calls[i].name, result.status, result.output);
                if (result.status == .denied) {
                    p.callbacks.on_notice(p.callbacks.ctx, result.output);
                }
                try p.history.append(p.arena, .{
                    .role = .tool,
                    .content = result.output,
                    .tool_call_id = calls[i].id,
                    .tool_name = calls[i].name,
                    .is_error = result.status != .ok,
                });
                i += 1;
            }
        }
        tools_span.end("");
        if (tool_start) |start| {
            tool_total_ns += std.Io.Timestamp.durationTo(start, std.Io.Timestamp.now(p.io, .awake)).nanoseconds;
        }
    }

    return .{
        .status = .completed,
        .reply = last_reply,
        .tool_rounds = rounds,
        .tool_calls = total_calls,
        .usage = total_usage,
        .error_message = "stopped: tool round limit reached",
    };
}

// ---------------------------------------------------------------- tests

const testing = @import("testing.zig");

test "runTurn executes scripted tool call and feeds result back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\n" });

    var fake = testing.Fake{ .script = &.{
        &.{
            .{ .text = "Looking at the file." },
            .{ .tool_call = .{ .id = "c1", .name = "read", .arguments_json = "{\"path\":\"f.txt\"}" } },
            .{ .usage = .{ .input_tokens = 10, .output_tokens = 5 } },
        },
        &.{
            .{ .text = "The file has two lines: alpha, beta." },
            .{ .usage = .{ .input_tokens = 20, .output_tokens = 9 } },
        },
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var perm_engine = @import("../permissions/engine.zig").Engine.init(arena, .auto);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = arena,
        .workspace = tmp.dir,
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn approve(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
                return .denied;
            }
        }.approve,
    };

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    try history.append(arena, .{ .role = .user, .content = "what is in f.txt?" });

    const EventLog = struct {
        texts: std.ArrayListUnmanaged([]const u8) = .empty,
        tool_starts: std.ArrayListUnmanaged([]const u8) = .empty,
        tool_results: std.ArrayListUnmanaged(tool_mod.Status) = .empty,
        tool_ids: std.ArrayListUnmanaged([]const u8) = .empty,
        assistant_msgs: usize = 0,
        notices: usize = 0,
        arena: std.mem.Allocator,
    };
    var log = EventLog{ .arena = arena };
    const cbs = Callbacks{
        .ctx = &log,
        .on_text = struct {
            fn f(ctx: *anyopaque, text: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.texts.append(l.arena, text) catch {};
            }
        }.f,
        .on_tool_start = struct {
            fn f(ctx: *anyopaque, call_id: []const u8, name: []const u8, args_json: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.tool_starts.append(l.arena, name) catch {};
                l.tool_ids.append(l.arena, call_id) catch {};
                _ = args_json;
            }
        }.f,
        .on_tool_result = struct {
            fn f(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.tool_results.append(l.arena, status) catch {};
                _ = call_id;
                _ = name;
                _ = output;
            }
        }.f,
        .on_assistant_message = struct {
            fn f(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.assistant_msgs += 1;
                _ = content;
                _ = tool_calls_json;
            }
        }.f,
        .on_notice = struct {
            fn f(ctx: *anyopaque, text: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.notices += 1;
                _ = text;
            }
        }.f,
    };

    var cancel = std.atomic.Value(bool).init(false);
    var outcome = try runTurn(.{
        .io = io,
        .arena = arena,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
        .system = "system prompt",
        .history = &history,
        .tool_ctx = &tool_ctx,
        .callbacks = cbs,
        .cancel = &cancel,
    });

    try std.testing.expectEqual(Status.completed, outcome.status);
    try std.testing.expectEqualStrings("The file has two lines: alpha, beta.", outcome.reply);
    try std.testing.expectEqual(@as(usize, 1), outcome.tool_calls);
    try std.testing.expectEqual(@as(u64, 30), outcome.usage.input_tokens);
    // Text is streamed to the UI as it arrives, one call per delta, in order
    // (regression: on_text was never invoked and replies never rendered).
    try std.testing.expectEqual(@as(usize, 2), log.texts.items.len);
    try std.testing.expectEqualStrings("Looking at the file.", log.texts.items[0]);
    try std.testing.expectEqualStrings("The file has two lines: alpha, beta.", log.texts.items[1]);
    try std.testing.expectEqual(@as(usize, 1), log.tool_starts.items.len);
    try std.testing.expectEqualStrings("read", log.tool_starts.items[0]);
    try std.testing.expectEqual(tool_mod.Status.ok, log.tool_results.items[0]);
    try std.testing.expectEqual(@as(usize, 4), history.items.len); // user, assistant+tc, tool, assistant

    // History reconstruction for the wire: assistant message carries tool_calls_json.
    try std.testing.expect(history.items[1].tool_calls_json != null);
    _ = &outcome;
}

test "runTurn surfaces provider failure" {
    const io = std.testing.io;
    var fake = testing.Fake{ .script = &.{
        &.{.{ .failure = .{ .kind = .unauthorized, .message = "bad key" } }},
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var perm_engine = @import("../permissions/engine.zig").Engine.init(arena, .auto);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = arena,
        .workspace = std.Io.Dir.cwd(),
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 1024,
        .approval_ctx = undefined,
        .approval_fn = undefined,
    };
    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(false);

    const outcome = try runTurn(.{
        .io = io,
        .arena = arena,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
        .system = "",
        .history = &history,
        .tool_ctx = &tool_ctx,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
        .cancel = &cancel,
    });
    try std.testing.expectEqual(Status.failed, outcome.status);
    try std.testing.expectEqualStrings("bad key", outcome.error_message);
}

test "a cancelled stream reports cancelled, not failed" {
    const io = std.testing.io;
    // The fake checks `req.cancel` first, so a pre-set flag cancels the call.
    var fake = testing.Fake{ .script = &.{
        &.{.{ .text = "partial" }},
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var perm_engine = @import("../permissions/engine.zig").Engine.init(arena, .auto);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = arena,
        .workspace = std.Io.Dir.cwd(),
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 1024,
        .approval_ctx = undefined,
        .approval_fn = undefined,
    };
    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(true);

    const outcome = try runTurn(.{
        .io = io,
        .arena = arena,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
        .system = "",
        .history = &history,
        .tool_ctx = &tool_ctx,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
        .cancel = &cancel,
    });
    try std.testing.expectEqual(Status.cancelled, outcome.status);
    try std.testing.expectEqualStrings("", outcome.error_message);
}

fn isAgentCall(tc: core_types.ToolCall) bool {
    return std.mem.eql(u8, tc.name, "agent");
}

/// Run one tool call in its own scratch arena and copy the redacted output
/// into `caller` before the scratch arena is deinited. `scratch_parent` must
/// be an allocator that actually frees (not the caller's arena), otherwise
/// the scratch memory would live as long as the caller.
fn executeWithScratch(
    p: RunParams,
    tc: core_types.ToolCall,
    caller: std.mem.Allocator,
    scratch_parent: std.mem.Allocator,
) tool_mod.ToolResult {
    var scratch_state = std.heap.ArenaAllocator.init(scratch_parent);
    defer scratch_state.deinit();
    var ctx = p.tool_ctx.*;
    ctx.arena = scratch_state.allocator();
    ctx.cancel = p.cancel;
    const raw = tool_mod.execute(tc.name, tc.arguments_json, &ctx);

    // Copy first, then redact in the caller: the raw slice belongs to the
    // scratch arena and must not leak into ToolResult.
    const copied = caller.dupe(u8, raw.output) catch "";
    return .{
        .output = redact_mod.redact(caller, copied, p.redactions),
        .status = raw.status,
    };
}

fn executeOne(p: RunParams, tc: core_types.ToolCall) tool_mod.ToolResult {
    return executeWithScratch(p, tc, p.arena, std.heap.page_allocator);
}

/// Run consecutive agent calls on parallel threads, each with its own
/// arena and ToolContext copy; results are ordered on return.
fn runAgentBatch(p: RunParams, calls: []const core_types.ToolCall) ![]tool_mod.ToolResult {
    const Slot = struct {
        thread: ?std.Thread = null,
        arena_state: ?std.heap.ArenaAllocator = null,
        result: tool_mod.ToolResult = .{ .output = "", .status = .failed },
        done: std.atomic.Value(bool) = .init(false),
    };
    const slots = try p.arena.alloc(Slot, calls.len);
    for (slots) |*s| s.* = .{};

    const Worker = struct {
        fn run(params: RunParams, tc: core_types.ToolCall, slot: *Slot) void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            slot.result = executeWithScratch(params, tc, arena_state.allocator(), std.heap.page_allocator);
            slot.arena_state = arena_state; // handed back for ordered copy
            slot.done.store(true, .release);
        }
    };

    var spawned: usize = 0;
    for (calls, slots) |tc, *slot| {
        slot.thread = std.Thread.spawn(.{}, Worker.run, .{ p, tc, slot }) catch {
            slot.done.store(true, .release); // runs inline below
            continue;
        };
        spawned += 1;
    }
    // Inline any that failed to spawn.
    for (calls, slots) |tc, *slot| {
        if (slot.thread == null and !slot.done.load(.acquire)) {
            Worker.run(p, tc, slot);
        }
    }
    // Ordered copy-out.
    for (slots) |*slot| {
        if (slot.thread) |t| t.join();
        var arena_state = slot.arena_state orelse continue;
        slot.result.output = p.arena.dupe(u8, slot.result.output) catch "";
        arena_state.deinit();
        slot.arena_state = null;
    }
    const results = try p.arena.alloc(tool_mod.ToolResult, calls.len);
    for (slots, 0..) |*slot, idx| results[idx] = slot.result;
    return results;
}

fn sleepSeconds(io: std.Io, seconds: u64) !void {
    if (seconds == 0) return;
    try std.Io.sleep(io, .fromSeconds(@intCast(seconds)), .awake);
}

fn noopText(_: *anyopaque, _: []const u8) void {}
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
fn noopNotice(_: *anyopaque, _: []const u8) void {}

test "consecutive agent calls run in parallel and append in order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    // Parent makes two agent calls in one round; children are scripted to
    // succeed immediately.
    var parent_fake = testing.Fake{ .script = &.{
        &.{
            .{ .tool_call = .{ .id = "a1", .name = "agent", .arguments_json = "{\"task\":\"t1\",\"role\":\"research\"}" } },
            .{ .tool_call = .{ .id = "a2", .name = "agent", .arguments_json = "{\"task\":\"t2\",\"role\":\"research\"}" } },
        },
        &.{.{ .text = "both children reported" }},
    } };
    var child_fake = testing.Fake{ .script = &.{
        &.{.{ .text = "child-one" }},
        &.{.{ .text = "child-two" }},
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var perm_engine = @import("../permissions/engine.zig").Engine.init(arena, .auto);
    var cancel = std.atomic.Value(bool).init(false);
    var host = @import("subagent.zig").Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "",
        .provider = child_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = undefined,
        .max_depth = 1,
        .max_concurrent = 4,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
    };

    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = arena,
        .workspace = tmp.dir,
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = undefined,
        .agent_spawn_fn = @import("subagent.zig").spawnHookFn,
        .agent_spawn_ctx = &host,
        .agent_depth = 0,
        .agent_label = "parent",
    };

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    try history.append(arena, .{ .role = .user, .content = "delegate two tasks" });

    const outcome = try runTurn(.{
        .io = io,
        .arena = arena,
        .pcfg = .{ .provider = parent_fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
        .system = "",
        .history = &history,
        .tool_ctx = &tool_ctx,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
        .cancel = &cancel,
    });

    try std.testing.expectEqual(Status.completed, outcome.status);
    try std.testing.expectEqual(@as(usize, 2), outcome.tool_calls);
    // Both child summaries are present in history (order preserved).
    const r1 = history.items[2].content;
    const r2 = history.items[3].content;
    try std.testing.expect(std.mem.indexOf(u8, r1, "child-one") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "child-two") != null);
}

test "retry delay honors Retry-After and caps backoff" {
    try std.testing.expectEqual(@as(u64, 5), retryDelaySeconds(0, 5));
    try std.testing.expectEqual(@as(u64, 60), retryDelaySeconds(3, 600));
    try std.testing.expectEqual(@as(u64, 1), retryDelaySeconds(0, null));
    try std.testing.expectEqual(@as(u64, 8), retryDelaySeconds(3, null));
    try std.testing.expectEqual(@as(u64, 16), retryDelaySeconds(9, null));
}

test "partial stream failure is not retried" {
    var fake = testing.Fake{ .script = &.{
        &.{
            .{ .text = "partial" },
            .{ .failure = .{ .kind = .network, .message = "connection dropped" } },
        },
        &.{.{ .text = "must not run" }},
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    try history.append(arena, .{ .role = .user, .content = "hi" });
    var cancel = std.atomic.Value(bool).init(false);

    // The scripted stream fails before any tool call, so the context is only
    // needed to satisfy `RunParams`; the approval hook denies by default.
    var perm_engine = @import("../permissions/engine.zig").Engine.init(arena, .auto);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = std.testing.io,
        .arena = arena,
        .workspace = std.Io.Dir.cwd(),
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn approve(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
                return .denied;
            }
        }.approve,
    };

    const outcome = try runTurn(.{
        .arena = arena,
        .io = std.testing.io,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
        .system = "",
        .history = &history,
        .tool_ctx = &tool_ctx,
        .cancel = &cancel,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
    });

    try std.testing.expectEqual(Status.failed, outcome.status);
    try std.testing.expectEqualStrings("partial", outcome.reply);
    try std.testing.expectEqual(@as(usize, 1), fake.call_index);
}

/// Test-only allocator that tracks outstanding bytes and their peak.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn bump(self: *@This(), len: usize) void {
        self.current += len;
        if (self.current > self.peak) self.peak = self.current;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bump(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.current -= memory.len;
        self.bump(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.current -= memory.len;
        self.bump(new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.current -= memory.len;
    }
};

fn scratchTestParams(
    tool_ctx: *tool_mod.ToolContext,
    history: *std.ArrayListUnmanaged(core_types.ChatMessage),
    cancel: *std.atomic.Value(bool),
) RunParams {
    return .{
        .io = std.testing.io,
        .arena = std.testing.allocator,
        .pcfg = .{ .provider = undefined, .model = "", .base_url = "", .api_key = "" },
        .system = "",
        .history = history,
        .tool_ctx = tool_ctx,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
        .cancel = cancel,
    };
}

test "tool scratch arenas are deinited on every path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha needle\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.zig", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=1\n" });

    var perm_engine = @import("../permissions/engine.zig").Engine.init(std.testing.allocator, .ask);
    defer perm_engine.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = std.testing.allocator,
        .workspace = tmp.dir,
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = undefined,
    };
    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    const p = scratchTestParams(&tool_ctx, &history, &cancel);

    var caller_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer caller_state.deinit();
    const caller = caller_state.allocator();

    const calls = [_]core_types.ToolCall{
        .{ .id = "1", .name = "read", .arguments_json = "{\"path\":\"a.txt\"}" },
        .{ .id = "2", .name = "glob", .arguments_json = "{\"pattern\":\"**\"}" },
        .{ .id = "3", .name = "grep", .arguments_json = "{\"pattern\":\"needle\"}" },
        .{ .id = "4", .name = "read", .arguments_json = "{\"path\":\".env\"}" },
        .{ .id = "5", .name = "read", .arguments_json = "{\"path\":\"missing.txt\"}" },
    };
    for (calls) |tc| {
        const result = executeWithScratch(p, tc, caller, std.testing.allocator);
        switch (tc.id[0]) {
            '1', '2', '3' => try std.testing.expectEqual(tool_mod.Status.ok, result.status),
            '4' => try std.testing.expectEqual(tool_mod.Status.denied, result.status),
            '5' => try std.testing.expectEqual(tool_mod.Status.failed, result.status),
            else => unreachable,
        }
    }
}

test "grep peak outstanding memory stays bounded on large files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    const line = "x" ** 1023 ++ "\n";
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    while (data.items.len < 1000 * 1024) {
        try data.appendSlice(std.testing.allocator, line);
    }
    try data.appendSlice(std.testing.allocator, "needle\n");
    for ([_][]const u8{ "g1.txt", "g2.txt", "g3.txt" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data.items });
    }

    var perm_engine = @import("../permissions/engine.zig").Engine.init(std.testing.allocator, .auto);
    defer perm_engine.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = std.testing.allocator,
        .workspace = tmp.dir,
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = undefined,
    };
    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    const p = scratchTestParams(&tool_ctx, &history, &cancel);

    var counting = CountingAllocator{ .parent = std.testing.allocator };
    var caller_state = std.heap.ArenaAllocator.init(counting.allocator());
    defer caller_state.deinit();
    const result = executeWithScratch(
        p,
        .{ .id = "g", .name = "grep", .arguments_json = "{\"pattern\":\"needle\"}" },
        caller_state.allocator(),
        counting.allocator(),
    );
    try std.testing.expectEqual(tool_mod.Status.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "g1.txt:1001: needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "g3.txt:1001: needle") != null);
    try std.testing.expect(counting.peak < 512 * 1024);
}
