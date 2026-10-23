//! OpenAI Responses API adapter (ACTIVE_PLAN E-01).
//!
//! Streams SSE from `{base_url}/responses` (OpenAI's `/v1/responses` when
//! the configured base URL already ends in `/v1`), normalizing output text,
//! reasoning summaries, function calls, usage, and errors to StreamEvents.
//! Input items are serialized from the neutral ChatMessage list, and tool
//! definitions in the chat-completions shape are rewritten to the Responses
//! `function` shape.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const core_types = @import("../core/types.zig");

pub const default_context: Context = .{};

pub const Context = struct {};

const transfer_buffer_size: usize = 16 * 1024;

const ToolAcc = struct {
    item_id: []const u8 = "",
    call_id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayListUnmanaged(u8) = .empty,
    emitted: bool = false,
};

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

    const url = try std.fmt.allocPrint(arena, "{s}/responses", .{trimSlash(req.base_url)});
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

    var tools: [16]ToolAcc = undefined;
    var tool_count: usize = 0;
    var saw_text_delta = false;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;

    while (try parser.next(arena)) |payload| {
        if (req.cancel.load(.acquire)) {
            sink.emit(.{ .failure = .{ .kind = .cancelled, .message = "cancelled" } });
            return;
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const type_v = o.get("type") orelse continue;
        if (type_v != .string) continue;
        const ev = type_v.string;

        if (std.mem.eql(u8, ev, "response.output_text.delta")) {
            if (o.get("delta")) |d| {
                if (d == .string and d.string.len > 0) {
                    saw_text_delta = true;
                    sink.emit(.{ .content_delta = d.string });
                }
            }
        } else if (std.mem.eql(u8, ev, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, ev, "response.reasoning_text.delta"))
        {
            if (o.get("delta")) |d| {
                if (d == .string and d.string.len > 0) {
                    sink.emit(.{ .reasoning_delta = d.string });
                }
            }
        } else if (std.mem.eql(u8, ev, "response.output_item.added")) {
            const item = o.get("item") orelse continue;
            if (item != .object) continue;
            const it = item.object;
            const item_type = strOrEmpty(it.get("type"));
            if (std.mem.eql(u8, item_type, "function_call")) {
                if (tool_count < tools.len) {
                    const t = &tools[tool_count];
                    t.* = .{
                        .item_id = try arena.dupe(u8, strOrEmpty(it.get("id"))),
                        .call_id = try arena.dupe(u8, strOrEmpty(it.get("call_id"))),
                        .name = try arena.dupe(u8, strOrEmpty(it.get("name"))),
                    };
                    if (it.get("arguments")) |args| {
                        if (args == .string and args.string.len > 0) {
                            t.args.appendSlice(arena, args.string) catch {};
                        }
                    }
                    tool_count += 1;
                }
            }
        } else if (std.mem.eql(u8, ev, "response.function_call_arguments.delta")) {
            const item_id = strOrEmpty(o.get("item_id"));
            const delta = if (o.get("delta")) |d| (if (d == .string) d.string else "") else "";
            if (findOrAddTool(&tools, &tool_count, item_id, arena)) |t| {
                t.args.appendSlice(arena, delta) catch {};
            }
        } else if (std.mem.eql(u8, ev, "response.function_call_arguments.done")) {
            const item_id = strOrEmpty(o.get("item_id"));
            const args = if (o.get("arguments")) |a| (if (a == .string) a.string else "") else "";
            if (findOrAddTool(&tools, &tool_count, item_id, arena)) |t| {
                if (args.len > 0) {
                    t.args = .empty;
                    t.args.appendSlice(arena, args) catch {};
                }
                emitTool(t, sink);
            }
        } else if (std.mem.eql(u8, ev, "response.output_item.done")) {
            const item = o.get("item") orelse continue;
            if (item != .object) continue;
            const it = item.object;
            const item_type = strOrEmpty(it.get("type"));
            if (std.mem.eql(u8, item_type, "function_call")) {
                if (findOrAddTool(&tools, &tool_count, strOrEmpty(it.get("id")), arena)) |t| {
                    if (t.call_id.len == 0) t.call_id = try arena.dupe(u8, strOrEmpty(it.get("call_id")));
                    if (t.name.len == 0) t.name = try arena.dupe(u8, strOrEmpty(it.get("name")));
                    if (it.get("arguments")) |args| {
                        if (args == .string and args.string.len > 0) {
                            t.args = .empty;
                            t.args.appendSlice(arena, args.string) catch {};
                        }
                    }
                    emitTool(t, sink);
                }
            } else if (std.mem.eql(u8, item_type, "message") and !saw_text_delta) {
                // Non-delta streams: emit the final message text once.
                if (it.get("content")) |content| {
                    if (content == .array) {
                        for (content.array.items) |part| {
                            if (part != .object) continue;
                            if (std.mem.eql(u8, strOrEmpty(part.object.get("type")), "output_text")) {
                                if (part.object.get("text")) |txt| {
                                    if (txt == .string and txt.string.len > 0) {
                                        sink.emit(.{ .content_delta = txt.string });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "response.completed")) {
            if (o.get("response")) |resp| {
                if (resp == .object) {
                    if (resp.object.get("usage")) |u| {
                        if (u == .object) {
                            input_tokens = intOf(u.object.get("input_tokens")) orelse input_tokens;
                            output_tokens = intOf(u.object.get("output_tokens")) orelse output_tokens;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "error") or std.mem.eql(u8, ev, "response.failed")) {
            var msg: []const u8 = "provider error";
            if (o.get("message")) |m| {
                if (m == .string) msg = m.string;
            } else if (o.get("error")) |err_v| {
                if (err_v == .object) {
                    if (err_v.object.get("message")) |m| {
                        if (m == .string) msg = m.string;
                    }
                }
            } else if (o.get("response")) |resp| {
                if (resp == .object) {
                    if (resp.object.get("error")) |err_v| {
                        if (err_v == .object) {
                            if (err_v.object.get("message")) |m| {
                                if (m == .string) msg = m.string;
                            }
                        }
                    }
                }
            }
            sink.emit(.{ .failure = .{ .kind = .invalid_request, .message = msg } });
            return;
        }
    }

    for (tools[0..tool_count]) |*t| {
        emitTool(t, sink);
    }

    if (input_tokens != 0 or output_tokens != 0) {
        sink.emit(.{ .usage = .{ .input_tokens = input_tokens, .output_tokens = output_tokens } });
    }
    sink.emit(.done);
}

fn emitTool(t: *ToolAcc, sink: provider.Sink) void {
    if (t.emitted) return;
    if (t.name.len == 0) return;
    t.emitted = true;
    sink.emit(.{ .tool_call = .{
        .id = if (t.call_id.len > 0) t.call_id else t.item_id,
        .name = t.name,
        .arguments_json = if (t.args.items.len > 0) t.args.items else "{}",
    } });
}

fn findOrAddTool(
    tools: []ToolAcc,
    count: *usize,
    item_id: []const u8,
    arena: std.mem.Allocator,
) ?*ToolAcc {
    if (item_id.len == 0) return null;
    for (tools[0..count.*]) |*t| {
        if (std.mem.eql(u8, t.item_id, item_id)) return t;
    }
    if (count.* >= tools.len) return null;
    const t = &tools[count.*];
    t.* = .{ .item_id = arena.dupe(u8, item_id) catch return null };
    count.* += 1;
    return t;
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

fn strOrEmpty(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
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
    try w.writeAll(",\"stream\":true,\"input\":[");

    var first = true;
    if (req.system.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.Stringify.value(req.system, .{}, w);
        try w.writeByte('}');
        first = false;
    }
    for (req.messages) |msg| {
        if (msg.role == .tool) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(msg.tool_call_id orelse "", .{}, w);
            try w.writeAll(",\"output\":");
            try std.json.Stringify.value(msg.content, .{}, w);
            try w.writeByte('}');
            continue;
        }

        if (msg.role == .assistant and msg.tool_calls_json != null) {
            if (msg.content.len > 0 or msg.blocks.len > 0) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[");
                if (msg.blocks.len > 0) {
                    var inner_first = true;
                    try writeInputBlocks(arena, w, msg.blocks, &inner_first, .assistant);
                } else {
                    try w.writeAll("{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, w);
                    try w.writeByte('}');
                }
                try w.writeAll("]}");
            }
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, msg.tool_calls_json.?, .{})) |tcv| {
                if (tcv == .array) {
                    for (tcv.array.items) |item| {
                        if (item != .object) continue;
                        const obj = item.object;
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                        try std.json.Stringify.value(strOrEmpty(obj.get("id")), .{}, w);
                        try w.writeAll(",\"name\":");
                        try std.json.Stringify.value(strOrEmpty(obj.get("name")), .{}, w);
                        try w.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(strOrEmpty(obj.get("arguments_json")), .{}, w);
                        try w.writeByte('}');
                    }
                }
            } else |_| {}
            continue;
        }

        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"type\":\"message\",\"role\":");
        try std.json.Stringify.value(@tagName(msg.role), .{}, w);
        try w.writeAll(",\"content\":[");
        if (msg.blocks.len > 0) {
            var inner_first = true;
            try writeInputBlocks(arena, w, msg.blocks, &inner_first, msg.role);
        } else {
            const content_type = if (msg.role == .assistant) "output_text" else "input_text";
            try w.print("{{\"type\":\"{s}\",\"text\":", .{content_type});
            try std.json.Stringify.value(msg.content, .{}, w);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');

    if (!std.mem.eql(u8, req.tools_json, "[]")) {
        try w.writeAll(",\"tools\":");
        try writeTools(arena, w, req.tools_json);
    }
    if (req.temperature) |t| {
        try w.print(",\"temperature\":{d}", .{t});
    }
    if (req.max_output_tokens) |t| {
        try w.print(",\"max_output_tokens\":{d}", .{t});
    }
    if (req.provider_options.len > 0) {
        try w.print(",{s}", .{std.mem.trimEnd(u8, req.provider_options, "{}")});
    }
    try w.writeByte('}');
    return aw.written();
}

fn writeInputBlocks(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    blocks: []const core_types.ContentBlock,
    first: *bool,
    role: core_types.ChatRole,
) !void {
    for (blocks) |block| {
        if (!first.*) try w.writeByte(',');
        first.* = false;
        switch (block) {
            .text => |text| {
                const content_type = if (role == .assistant) "output_text" else "input_text";
                try w.print("{{\"type\":\"{s}\",\"text\":", .{content_type});
                try std.json.Stringify.value(text, .{}, w);
                try w.writeByte('}');
            },
            .image => |img| {
                const url = if (img.url) |u| u else try std.fmt.allocPrint(
                    arena,
                    "data:{s};base64,{s}",
                    .{ img.media_type, img.data orelse "" },
                );
                try w.writeAll("{\"type\":\"input_image\",\"image_url\":");
                try std.json.Stringify.value(url, .{}, w);
                try w.writeByte('}');
            },
        }
    }
}

fn writeTools(arena: std.mem.Allocator, w: *std.Io.Writer, tools_json: []const u8) !void {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, tools_json, .{}) catch {
        try w.writeAll("[]");
        return;
    };
    if (v != .array) {
        try w.writeAll("[]");
        return;
    }
    try w.writeByte('[');
    var first = true;
    for (v.array.items) |item| {
        if (item != .object) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const fn_obj = item.object.get("function");
        if (fn_obj != null and fn_obj.? == .object) {
            const f = fn_obj.?.object;
            try w.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(strOrEmpty(f.get("name")), .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(strOrEmpty(f.get("description")), .{}, w);
            try w.writeAll(",\"parameters\":");
            if (f.get("parameters")) |params| {
                try std.json.Stringify.value(params, .{}, w);
            } else {
                try w.writeAll("{}");
            }
            try w.writeByte('}');
        } else {
            const passthrough = std.json.Value{ .object = item.object };
            try std.json.Stringify.value(passthrough, .{}, w);
        }
    }
    try w.writeByte(']');
}

pub var instance_context: Context = .{};

pub const instance = provider.Provider{
    .ctx = &instance_context,
    .stream_fn = streamFn,
    .capabilities_fn = capabilities,
};

fn capabilities() provider.Capabilities {
    return .{ .streaming = true, .tool_use = true, .reasoning = true };
}

test "responses buildBody serializes input items and rewrites tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cancel = std.atomic.Value(bool).init(false);
    var messages = [_]core_types.ChatMessage{
        .{
            .role = .user,
            .content = "describe",
            .blocks = &.{
                .{ .text = "describe" },
                .{ .image = .{ .media_type = "image/png", .data = "aW1n" } },
            },
        },
        .{
            .role = .tool,
            .content = "done",
            .tool_call_id = "c1",
        },
    };

    const body = try buildBody(arena, .{
        .model = "gpt-5",
        .base_url = "https://example.test/v1",
        .api_key = "",
        .system = "sys",
        .messages = &messages,
        .tools_json = "[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"read a file\",\"parameters\":{\"type\":\"object\"}}}]",
        .cancel = &cancel,
    });

    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5\",\"stream\":true,\"input\":[{\"role\":\"system\",\"content\":\"sys\"},{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"describe\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aW1n\"}]},{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"done\"}],\"tools\":[{\"type\":\"function\",\"name\":\"read\",\"description\":\"read a file\",\"parameters\":{\"type\":\"object\"}}]}",
        body,
    );
}
