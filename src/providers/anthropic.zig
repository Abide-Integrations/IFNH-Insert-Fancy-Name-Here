//! Anthropic Messages API adapter (DECISIONS D39/D40 set).
//!
//! Streams SSE from `{base_url}/v1/messages`, normalizing to StreamEvents.
//! Tool results are serialized as user `tool_result` blocks per the
//! Anthropic wire format; assistant tool_use blocks are reconstructed from
//! `tool_calls_json` carried on the chat message.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");

const anthropic_version = "2023-06-01";
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

    const url = try std.fmt.allocPrint(arena, "{s}/v1/messages", .{trimSlash(req.base_url)});
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    const body = try buildBody(arena, req);

    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var extra = [_]std.http.Header{
        .{ .name = "x-api-key", .value = req.api_key },
        .{ .name = "anthropic-version", .value = anthropic_version },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    var creq = try client.request(.POST, uri, .{
        .headers = .{
            .authorization = .omit,
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

    // Tool block accumulation keyed by content block index.
    const ToolAcc = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        args: std.ArrayListUnmanaged(u8) = .empty,
    };
    var tools: [16]ToolAcc = undefined;
    var tool_count: usize = 0;
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

        if (std.mem.eql(u8, ev, "message_start")) {
            if (o.get("message")) |m| {
                if (m == .object) {
                    if (m.object.get("usage")) |u| {
                        if (u == .object) input_tokens = intOf(u.object.get("input_tokens")) orelse 0;
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "content_block_start")) {
            const cb = o.get("content_block") orelse continue;
            if (cb != .object) continue;
            const index = intOf(o.get("index")) orelse continue;
            if (cb.object.get("type")) |t| {
                if (t == .string and std.mem.eql(u8, t.string, "tool_use")) {
                    if (index < tools.len) {
                        while (tool_count <= index) : (tool_count += 1) tools[tool_count] = .{};
                        if (cb.object.get("id")) |idv| {
                            if (idv == .string) tools[index].id = try arena.dupe(u8, idv.string);
                        }
                        if (cb.object.get("name")) |nv| {
                            if (nv == .string) tools[index].name = try arena.dupe(u8, nv.string);
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "content_block_delta")) {
            const delta = o.get("delta") orelse continue;
            if (delta != .object) continue;
            const d = delta.object;
            const dt = d.get("type") orelse continue;
            if (dt != .string) continue;
            if (std.mem.eql(u8, dt.string, "text_delta")) {
                if (d.get("text")) |t| {
                    if (t == .string and t.string.len > 0) sink.emit(.{ .content_delta = t.string });
                }
            } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                if (d.get("partial_json")) |pj| {
                    if (pj == .string) {
                        const index = intOf(o.get("index")) orelse continue;
                        if (index < tool_count) tools[index].args.appendSlice(arena, pj.string) catch {};
                    }
                }
            }
        } else if (std.mem.eql(u8, ev, "message_delta")) {
            if (o.get("usage")) |u| {
                if (u == .object) output_tokens = intOf(u.object.get("output_tokens")) orelse output_tokens;
            }
        } else if (std.mem.eql(u8, ev, "message_stop")) {
            break;
        }
    }

    for (tools[0..tool_count]) |*t| {
        if (t.name.len == 0) continue;
        sink.emit(.{ .tool_call = .{
            .id = t.id,
            .name = t.name,
            .arguments_json = t.args.items,
        } });
    }

    if (input_tokens != 0 or output_tokens != 0) {
        sink.emit(.{ .usage = .{ .input_tokens = input_tokens, .output_tokens = output_tokens } });
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
        }
    }
    return error.NotFound;
}

fn buildBody(arena: std.mem.Allocator, req: provider.ModelRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(req.model, .{}, w);
    try w.print(",\"max_tokens\":{d},\"stream\":true", .{req.max_output_tokens orelse 4096});

    if (req.system.len > 0) {
        try w.writeAll(",\"system\":");
        try std.json.Stringify.value(req.system, .{}, w);
    }

    try w.writeAll(",\"messages\":[");
    var first = true;
    for (req.messages) |msg| {
        if (msg.role == .system) continue; // handled via system field
        if (!first) try w.writeByte(',');
        first = false;

        switch (msg.role) {
            .tool => {
                // Tool results are user messages with tool_result blocks.
                try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
                try std.json.Stringify.value(msg.tool_call_id orelse "", .{}, w);
                try w.writeAll(",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeAll("}]}");
            },
            .assistant => {
                try w.writeAll("{\"role\":\"assistant\",\"content\":[");
                var inner_first = true;
                if (msg.content.len > 0) {
                    try w.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, w);
                    try w.writeByte('}');
                    inner_first = false;
                }
                if (msg.tool_calls_json) |tcj| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{})) |tcv| {
                        if (tcv == .array) {
                            for (tcv.array.items) |item| {
                                if (item != .object) continue;
                                if (!inner_first) try w.writeByte(',');
                                inner_first = false;
                                try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                                try std.json.Stringify.value(strOrEmpty(item.object.get("id")), .{}, w);
                                try w.writeAll(",\"name\":");
                                try std.json.Stringify.value(strOrEmpty(item.object.get("name")), .{}, w);
                                try w.writeAll(",\"input\":");
                                const args = item.object.get("arguments_json");
                                try w.writeAll(if (args != null and args.? == .string) args.?.string else "{}");
                                try w.writeByte('}');
                            }
                        }
                    } else |_| {}
                }
                try w.writeAll("]}");
            },
            else => {
                try w.writeAll("{\"role\":\"user\",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
            },
        }
    }
    try w.writeByte(']');

    if (!std.mem.eql(u8, req.tools_json, "[]")) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(req.tools_json);
    }
    if (req.temperature) |t| {
        try w.print(",\"temperature\":{d}", .{t});
    }
    try w.writeByte('}');
    return aw.written();
}

fn strOrEmpty(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

pub var instance_context: u8 = 0;

pub const instance = provider.Provider{
    .ctx = &instance_context,
    .stream_fn = streamFn,
    .capabilities_fn = capabilities,
};

fn capabilities() provider.Capabilities {
    return .{ .streaming = true, .tool_use = true, .reasoning = true };
}
