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
    text: std.ArrayListUnmanaged(u8) = .empty,
    tool_calls: std.ArrayListUnmanaged(core_types.ToolCall) = .empty,
    usage: core_types.Usage = .{},
    failure: ?core_types.ProviderFailure = null,

    fn emit(ctx_ptr: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx_ptr));
        switch (ev) {
            .content_delta => |d| {
                self.text.appendSlice(self.arena, d) catch {};
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

        var collector = Collector{ .arena = p.arena };
        const tools_json = try renderToolsJson(p.arena, null);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            collector = Collector{ .arena = p.arena };
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

        // Execute each tool call, appending results.
        for (collector.tool_calls.items) |tc| {
            if (p.cancel.load(.acquire)) {
                return .{ .status = .cancelled, .reply = last_reply, .tool_rounds = rounds, .tool_calls = total_calls, .usage = total_usage };
            }
            p.callbacks.on_tool_start(p.callbacks.ctx, tc.name, tc.arguments_json);
            const result_raw = tool_mod.execute(tc.name, tc.arguments_json, p.tool_ctx);
            const result = tool_mod.ToolResult{
                .output = redact_mod.redact(p.arena, result_raw.output, p.redactions),
                .status = result_raw.status,
            };
            total_calls += 1;
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

fn sleepSeconds(io: std.Io, seconds: u64) !void {
    if (seconds == 0) return;
    try std.Io.sleep(io, .fromSeconds(@intCast(seconds)), .awake);
}

fn noopText(_: *anyopaque, _: []const u8) void {}
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
fn noopNotice(_: *anyopaque, _: []const u8) void {}
