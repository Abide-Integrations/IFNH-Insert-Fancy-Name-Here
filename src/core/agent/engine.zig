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

pub const max_tool_rounds_default: usize = 25;

pub const ProviderConfig = struct {
    provider: provider_mod.Provider,
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
};

pub const Callbacks = struct {
    ctx: *anyopaque,
    /// Streaming text delta.
    on_text: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// A tool call is about to execute.
    on_tool_start: *const fn (ctx: *anyopaque, name: []const u8, arguments_json: []const u8) void,
    /// A tool call finished.
    on_tool_result: *const fn (ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void,
    /// Non-fatal notice (permission denials, truncation...).
    on_notice: *const fn (ctx: *anyopaque, text: []const u8) void,
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

/// Render tool specs (name/description/parameters) as a JSON array for the
/// provider request.
pub fn renderToolsJson(arena: std.mem.Allocator, names: ?[]const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    for (tool_mod.specs) |spec| {
        if (names) |allowed| {
            var ok = false;
            for (allowed) |n| {
                if (std.mem.eql(u8, n, spec.name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) continue;
        }
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(spec.name, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(spec.description, .{}, w);
        try w.writeAll(",\"parameters\":");
        try w.writeAll(spec.parameters_json);
        try w.writeAll("}}");
    }
    try w.writeByte(']');
    return aw.written();
}

pub const RunParams = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    pcfg: ProviderConfig,
    system: []const u8,
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
};

/// Run one agent turn. Appends assistant/tool messages to `history`.
pub fn runTurn(p: RunParams) !Outcome {
    var total_usage = core_types.Usage{};
    var rounds: usize = 0;
    var total_calls: usize = 0;
    var last_reply: []const u8 = "";

    while (rounds < p.max_tool_rounds) : (rounds += 1) {
        if (p.cancel.load(.acquire)) {
            return .{ .status = .cancelled, .reply = last_reply, .tool_rounds = rounds, .tool_calls = total_calls, .usage = total_usage };
        }

        var collector = Collector{ .arena = p.arena, .callbacks = p.callbacks };
        const tools_json = if (p.include_tools)
            try renderToolsJson(p.arena, null)
        else
            "[]";
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            collector = Collector{ .arena = p.arena, .callbacks = p.callbacks };
            try p.pcfg.provider.stream(p.arena, p.io, .{
                .model = p.pcfg.model,
                .base_url = p.pcfg.base_url,
                .api_key = p.pcfg.api_key,
                .system = p.system,
                .messages = p.history.items,
                .tools_json = tools_json,
                .temperature = p.temperature,
                .max_output_tokens = p.max_output_tokens,
                .cancel = p.cancel,
            }, .{ .ctx = &collector, .emit_fn = sinkEmit });
            if (collector.failure) |f| {
                if (core_types.isRetryable(f.kind) and attempt < p.max_retries and !p.cancel.load(.acquire)) {
                    const shift: u6 = @intCast(@min(attempt, 4));
                    const delay_s: u64 = @min(@as(u64, 1) << shift, 16);
                    sleepSeconds(p.io, delay_s) catch break;
                    continue;
                }
            }
            break;
        }

        total_usage.input_tokens += collector.usage.input_tokens;
        total_usage.output_tokens += collector.usage.output_tokens;

        if (collector.failure) |f| {
            return .{
                .status = .failed,
                .reply = last_reply,
                .tool_rounds = rounds,
                .tool_calls = total_calls,
                .usage = total_usage,
                .error_message = f.message,
            };
        }

        const reply = collector.text.items;
        last_reply = reply;

        if (collector.tool_calls.items.len == 0) {
            try p.history.append(p.arena, .{ .role = .assistant, .content = reply });
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

        // Execute tool calls; consecutive `agent` calls run in parallel
        // (E58), everything else sequentially, results appended in order.
        const calls = collector.tool_calls.items;
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
                    p.callbacks.on_tool_start(p.callbacks.ctx, tc.name, tc.arguments_json);
                    p.callbacks.on_tool_result(p.callbacks.ctx, tc.name, result.status, result.output);
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
                p.callbacks.on_tool_start(p.callbacks.ctx, calls[i].name, calls[i].arguments_json);
                p.callbacks.on_tool_result(p.callbacks.ctx, calls[i].name, result.status, result.output);
                if (result.status == .denied) {
                    p.callbacks.on_notice(p.callbacks.ctx, result.output);
                }
                try p.history.append(p.arena, .{
                    .role = .tool,
                    .content = result.output,
                    .tool_call_id = calls[i].id,
                    .tool_name = calls[i].name,
                });
                i += 1;
            }
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
            fn f(ctx: *anyopaque, name: []const u8, args_json: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.tool_starts.append(l.arena, name) catch {};
                _ = args_json;
            }
        }.f,
        .on_tool_result = struct {
            fn f(ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void {
                const l: *EventLog = @ptrCast(@alignCast(ctx));
                l.tool_results.append(l.arena, status) catch {};
                _ = name;
                _ = output;
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

fn isAgentCall(tc: core_types.ToolCall) bool {
    return std.mem.eql(u8, tc.name, "agent");
}

fn executeOne(p: RunParams, tc: core_types.ToolCall) tool_mod.ToolResult {
    const raw = tool_mod.execute(tc.name, tc.arguments_json, p.tool_ctx);
    return .{
        .output = redact_mod.redact(p.arena, raw.output, p.redactions),
        .status = raw.status,
    };
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
            var ctx = params.tool_ctx.*;
            ctx.arena = arena_state.allocator();
            const raw = tool_mod.execute(tc.name, tc.arguments_json, &ctx);
            slot.result = raw;
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
        const output = arena_state.allocator().dupe(u8, slot.result.output) catch slot.result.output;
        const out_copy = p.arena.dupe(u8, output) catch output;
        slot.result.output = out_copy;
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
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
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
