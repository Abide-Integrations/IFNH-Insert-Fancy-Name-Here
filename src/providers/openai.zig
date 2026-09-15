//! OpenAI-compatible Chat Completions adapter (DECISIONS D40).
//!
//! Works against any OpenAI-compatible endpoint (OpenAI, OpenRouter,
//! Ollama, llama.cpp server, Z.AI, vLLM, custom proxies) with a
//! config-driven base URL. Streams SSE, accumulates tool calls, and emits
//! normalized events. This adapter is the generic fallback provider.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const core_types = @import("../core/types.zig");

pub const default_context: Context = .{};

pub const Context = struct {};

const max_response_bytes: usize = 32 * 1024 * 1024;
const transfer_buffer_size: usize = 16 * 1024;

pub fn streamFn(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    io: std.Io,
    req: provider.ModelRequest,
    sink: provider.Sink,
) anyerror!void {
    _ = ctx;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{trimSlash(req.base_url)});
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    const body = try buildBody(arena, req);

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var extra = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
    };

    var creq = try client.request(.POST, uri, .{
        .headers = .{
            .authorization = if (req.api_key.len > 0)
                .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{req.api_key}) }
            else
                .omit,
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &extra,
        .redirect_behavior = .unhandled,
    });
    defer creq.deinit();

    try creq.sendBodyComplete(@constCast(body));

    var redirect_buf: [8192]u8 = undefined;
    var response = try creq.receiveHead(&redirect_buf);

    if (response.head.status.class() != .success) {
        var err_body: [16 * 1024]u8 = undefined;
        const r = response.reader(&err_body);
        const text = r.allocRemaining(arena, .limited(16 * 1024)) catch "";
        sink.emit(.{ .failure = .{
            .kind = provider.failureKindForStatus(@intFromEnum(response.head.status)),
            .message = extractErrorMessage(arena, text) catch text,
        } });
        return;
    }

    var transfer_buffer: [transfer_buffer_size]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var parser = sse.Parser{ .reader = reader };

    // Tool call accumulation keyed by index.
    const ToolAcc = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        args: std.ArrayListUnmanaged(u8) = .empty,
    };
    var tools: [16]ToolAcc = undefined;
    var tool_count: usize = 0;

    while (try parser.next(arena)) |payload| {
        if (req.cancel.load(.acquire)) {
            sink.emit(.{ .failure = .{ .kind = .cancelled, .message = "cancelled" } });
            return;
        }
        if (std.mem.eql(u8, std.mem.trim(u8, payload, " \t\r\n"), "[DONE]")) break;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;

        if (o.get("error")) |err_v| {
            const msg = if (err_v == .object)
                if (err_v.object.get("message")) |m| (if (m == .string) m.string else "provider error") else "provider error"
            else
                "provider error";
            sink.emit(.{ .failure = .{ .kind = .invalid_request, .message = msg } });
            return;
        }

        if (o.get("usage")) |usage_v| {
            if (usage_v == .object) {
                const u = usage_v.object;
                sink.emit(.{ .usage = .{
                    .input_tokens = intOf(u.get("prompt_tokens")) orelse 0,
                    .output_tokens = intOf(u.get("completion_tokens")) orelse 0,
                } });
            }
        }

        const choices_v = o.get("choices") orelse continue;
        if (choices_v != .array or choices_v.array.items.len == 0) continue;
        const choice = choices_v.array.items[0];
        if (choice != .object) continue;
        const co = choice.object;

        if (co.get("delta")) |delta_v| {
            if (delta_v == .object) {
                const d = delta_v.object;
                if (d.get("content")) |c| {
                    if (c == .string and c.string.len > 0) {
                        sink.emit(.{ .content_delta = c.string });
                    }
                }
                if (d.get("tool_calls")) |tc_v| {
                    if (tc_v == .array) {
                        for (tc_v.array.items) |item| {
                            if (item != .object) continue;
                            const io_ = item.object;
                            const index = intOf(io_.get("index")) orelse tool_count;
                            while (tool_count <= index and tool_count < tools.len) : (tool_count += 1) {
                                tools[tool_count] = .{};
                            }
                            if (index >= tools.len) continue;
                            const t = &tools[index];
                            if (io_.get("id")) |idv| {
                                if (idv == .string and idv.string.len > 0) t.id = try arena.dupe(u8, idv.string);
                            }
                            if (io_.get("function")) |fv| {
                                if (fv == .object) {
                                    if (fv.object.get("name")) |nv| {
                                        if (nv == .string and nv.string.len > 0) t.name = try arena.dupe(u8, nv.string);
                                    }
                                    if (fv.object.get("arguments")) |av| {
                                        if (av == .string) t.args.appendSlice(arena, av.string) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const finish_v = co.get("finish_reason") orelse continue;
        if (finish_v == .string and std.mem.eql(u8, finish_v.string, "tool_calls")) {
            // Emit completed tool calls at finish.
            for (tools[0..tool_count]) |*t| {
                if (t.name.len == 0) continue;
                sink.emit(.{ .tool_call = .{
                    .id = t.id,
                    .name = t.name,
                    .arguments_json = t.args.items,
                } });
            }
            tool_count = 0;
        }
    }

    // Emit any accumulated tool calls not flushed by finish_reason.
    for (tools[0..tool_count]) |*t| {
        if (t.name.len == 0) continue;
        sink.emit(.{ .tool_call = .{
            .id = t.id,
            .name = t.name,
            .arguments_json = t.args.items,
        } });
    }

    sink.emit(.done);
}

fn trimSlash(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, "/")) s[0 .. s.len - 1] else s;
}

fn intOf(v: ?std.json.Value) ?u64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn extractErrorMessage(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (v == .object) {
        if (v.object.get("error")) |e| {
            if (e == .object) {
                if (e.object.get("message")) |m| {
                    if (m == .string) return m.string;
                }
            }
            if (e == .string) return e.string;
        }
    }
    return error.NotFound;
}

fn buildBody(arena: std.mem.Allocator, req: provider.ModelRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(req.model, .{}, w);
    try w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");

    var first = true;
    if (req.system.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.Stringify.value(req.system, .{}, w);
        try w.writeByte('}');
        first = false;
    }
    for (req.messages) |msg| {
        if (!first) try w.writeByte(',');
        first = false;
        switch (msg.role) {
            .system, .user, .assistant => {
                try w.writeAll("{\"role\":");
                try std.json.Stringify.value(@tagName(msg.role), .{}, w);
                try w.writeAll(",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
            },
            .tool => {
                try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(msg.tool_call_id orelse "", .{}, w);
                try w.writeAll(",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
            },
        }
    }
    try w.writeByte(']');

    if (!std.mem.eql(u8, req.tools_json, "[]")) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(req.tools_json);
        try w.writeAll(",\"tool_choice\":\"auto\"");
    }
    if (req.temperature) |t| {
        try w.print(",\"temperature\":{d}", .{t});
    }
    if (req.max_output_tokens) |t| {
        try w.print(",\"max_tokens\":{d}", .{t});
    }
    if (req.provider_options.len > 0) {
        try w.print(",{s}", .{std.mem.trimEnd(u8, req.provider_options, "{}")});
    }
    try w.writeByte('}');
    return aw.written();
}

/// The OpenAI-compatible provider singleton.
pub var instance_context: Context = .{};

pub const instance = provider.Provider{
    .ctx = &instance_context,
    .stream_fn = streamFn,
    .capabilities_fn = capabilities,
};

fn capabilities() provider.Capabilities {
    return .{ .streaming = true, .tool_use = true, .reasoning = false };
}
