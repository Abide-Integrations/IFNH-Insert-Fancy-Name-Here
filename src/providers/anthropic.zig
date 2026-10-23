//! Anthropic Messages API adapter (DECISIONS D39/D40 set).
//!
//! Streams SSE from `{base_url}/v1/messages`, normalizing to StreamEvents.
//! Tool results are serialized as user `tool_result` blocks per the
//! Anthropic wire format; assistant tool_use blocks are reconstructed from
//! `tool_calls_json` carried on the chat message.

const std = @import("std");
const core_types = @import("../core/types.zig");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const transport = @import("transport.zig");

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

    const connection = transport.openConnection(&client, uri, transport.default_limits) catch |err| {
        sink.emit(.{ .failure = transport.failureFor(err, null) });
        return;
    };
    var creq = client.request(.POST, uri, .{
        .headers = .{
            .authorization = .omit,
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &extra,
        .redirect_behavior = .unhandled,
        .connection = connection,
    }) catch |err| {
        const failure = transport.failureFor(err, connection);
        client.connection_pool.release(connection, io);
        sink.emit(.{ .failure = failure });
        return;
    };
    defer creq.deinit();

    creq.sendBodyComplete(@constCast(body)) catch |err| {
        sink.emit(.{ .failure = transport.failureFor(err, creq.connection) });
        return;
    };

    var redirect_buf: [8192]u8 = undefined;
    var response = creq.receiveHead(&redirect_buf) catch |err| {
        sink.emit(.{ .failure = transport.failureFor(err, creq.connection) });
        return;
    };

    if (response.head.status.class() != .success) {
        var err_body: [16 * 1024]u8 = undefined;
        const r = response.reader(&err_body);
        const text = r.allocRemaining(arena, .limited(16 * 1024)) catch "";
        const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
        sink.emit(.{ .failure = .{
            .kind = provider.failureKindForStatus(@intFromEnum(response.head.status)),
            .message = extractErrorMessage(arena, text) catch text,
            .retry_after_s = transport.retryAfterFromHead(response.head, now_s),
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
    var cache_read_tokens: u64 = 0;
    var cache_write_tokens: u64 = 0;

    while (true) {
        const maybe_payload = parser.next(arena) catch |err| {
            sink.emit(.{ .failure = transport.failureFor(err, creq.connection) });
            return;
        };
        const payload = maybe_payload orelse break;
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
                        if (u == .object) {
                            input_tokens = intOf(u.object.get("input_tokens")) orelse 0;
                            cache_read_tokens = intOf(u.object.get("cache_read_input_tokens")) orelse 0;
                            cache_write_tokens = intOf(u.object.get("cache_creation_input_tokens")) orelse 0;
                        }
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

    if (input_tokens != 0 or output_tokens != 0 or cache_read_tokens != 0 or cache_write_tokens != 0) {
        sink.emit(.{ .usage = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read_tokens = cache_read_tokens,
            .cache_write_tokens = cache_write_tokens,
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
    // tool_use ids issued by the most recent assistant message. A result
    // whose id is not among them cannot be paired and is dropped (T01).
    var issued: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < req.messages.len) {
        const msg = req.messages[i];
        switch (msg.role) {
            .system => {
                i += 1; // handled via the top-level system field
            },
            .tool => {
                // Consecutive results for one assistant turn become a single
                // user message carrying one tool_result block each.
                var blocks: std.Io.Writer.Allocating = .init(arena);
                var block_count: usize = 0;
                while (i < req.messages.len and req.messages[i].role == .tool) : (i += 1) {
                    const res = req.messages[i];
                    const id = res.tool_call_id orelse continue;
                    const at = indexOfStr(issued.items, id) orelse continue;
                    _ = issued.orderedRemove(at);
                    if (block_count > 0) try blocks.writer.writeByte(',');
                    block_count += 1;
                    try blocks.writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                    try std.json.Stringify.value(id, .{}, &blocks.writer);
                    try blocks.writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(res.content, .{}, &blocks.writer);
                    if (res.is_error) try blocks.writer.writeAll(",\"is_error\":true");
                    try blocks.writer.writeByte('}');
                }
                if (block_count == 0) continue; // orphan results: emit nothing
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"user\",\"content\":[");
                try w.writeAll(blocks.written());
                try w.writeAll("]}");
            },
            .assistant => {
                i += 1;
                issued = .empty;
                var blocks: std.Io.Writer.Allocating = .init(arena);
                var block_count: usize = 0;
                if (msg.content.len > 0) {
                    try blocks.writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, &blocks.writer);
                    try blocks.writer.writeByte('}');
                    block_count += 1;
                }
                if (msg.tool_calls_json) |tcj| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{})) |tcv| {
                        if (tcv == .array) {
                            for (tcv.array.items) |item| {
                                if (item != .object) continue;
                                const id = strOrEmpty(item.object.get("id"));
                                const name = strOrEmpty(item.object.get("name"));
                                // Without an id the block can never be paired
                                // with its result.
                                if (id.len == 0 or name.len == 0) continue;
                                if (block_count > 0) try blocks.writer.writeByte(',');
                                block_count += 1;
                                try blocks.writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                                try std.json.Stringify.value(id, .{}, &blocks.writer);
                                try blocks.writer.writeAll(",\"name\":");
                                try std.json.Stringify.value(name, .{}, &blocks.writer);
                                try blocks.writer.writeAll(",\"input\":");
                                try writeToolInput(&blocks.writer, arena, item.object.get("arguments_json"));
                                try blocks.writer.writeByte('}');
                                const owned_id = arena.dupe(u8, id) catch continue;
                                try issued.append(arena, owned_id);
                            }
                        }
                    } else |_| {}
                }
                if (block_count == 0) continue; // never emit empty content
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"assistant\",\"content\":[");
                try w.writeAll(blocks.written());
                try w.writeAll("]}");
            },
            else => {
                i += 1;
                issued = .empty;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"user\",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
            },
        }
    }
    try w.writeByte(']');

    if (req.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (req.tools, 0..) |spec, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(spec.name, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(spec.description, .{}, w);
            try w.writeAll(",\"input_schema\":");
            try w.writeAll(spec.parameters_json);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    if (req.temperature) |t| {
        try w.print(",\"temperature\":{d}", .{t});
    }
    try w.writeByte('}');
    return aw.written();
}

fn indexOfStr(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (std.mem.eql(u8, item, needle)) return idx;
    }
    return null;
}

/// Anthropic requires `input` to be a JSON object. Malformed or non-object
/// arguments degrade to `{}` instead of breaking the whole request.
fn writeToolInput(w: *std.Io.Writer, arena: std.mem.Allocator, args: ?std.json.Value) !void {
    const text = blk: {
        const raw = args orelse break :blk "{}";
        if (raw != .string or raw.string.len == 0) break :blk "{}";
        break :blk raw.string;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        try w.writeAll("{}");
        return;
    };
    if (parsed != .object) {
        try w.writeAll("{}");
        return;
    }
    try std.json.Stringify.value(parsed, .{}, w);
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

// ---------------------------------------------------------------- tests

fn testRequest(msgs: []const core_types.ChatMessage, tools: []const core_types.ToolSpec) provider.ModelRequest {
    return .{
        .model = "claude-test",
        .base_url = "https://api.anthropic.com",
        .api_key = "k",
        .system = "sys",
        .messages = msgs,
        .tools = tools,
        .cancel = undefined,
    };
}

test "body pairs tool results into one user message" {
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"},{\"id\":\"t2\",\"name\":\"bash\",\"arguments_json\":\"not json\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "t1" },
        .{ .role = .tool, .content = "boom", .tool_call_id = "t2", .is_error = true },
        .{ .role = .user, .content = "done" },
    };
    const tools = [_]core_types.ToolSpec{
        .{ .name = "read", .description = "d", .parameters_json = "{\"type\":\"object\"}" },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &tools));
    // Must be valid JSON (Anthropic rejects malformed bodies).
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    try std.testing.expect(parsed == .object);

    // Three user messages: opening, the merged tool-result one, and the
    // follow-up; the two results did NOT become two messages.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "\"role\":\"user\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"content\":[{\"type\":\"tool_result\""));

    // tool_use input is a JSON object; malformed arguments degrade to {}.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read\",\"input\":{\"path\":\"a.txt\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"bash\",\"input\":{}") != null);

    // Both results travel together, in order, with the error flag.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"alpha\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\",\"tool_use_id\":\"t2\",\"content\":\"boom\",\"is_error\":true}") != null);

    // Tool schemas are forwarded for Anthropic, untouched.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "input_schema") != null);
}

test "body drops orphan results and empty messages" {
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "   " },
        .{ .role = .tool, .content = "stray", .tool_call_id = "zzz" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\",\"arguments_json\":\"{}\"}]" },
        .{ .role = .tool, .content = "never issued", .tool_call_id = "other" },
        .{ .role = .tool, .content = "ok", .tool_call_id = "t1" },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &.{}));
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});

    // Orphan results produce no user message of their own.
    try std.testing.expect(std.mem.indexOf(u8, body, "stray") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "never issued") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"ok\"}") != null);
    // No empty assistant content array.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\",\"content\":[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
}

test "wire golden anthropic body is byte-stable" {
    // A fixed request renders byte-for-byte: no maps are involved (every
    // field is written in source order), so the full body is asserted
    // instead of a substring set.
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "checking", .tool_calls_json = "[{\"id\":\"t1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "t1" },
        .{ .role = .user, .content = "second" },
    };
    const tools = [_]core_types.ToolSpec{
        .{
            .name = "read",
            .description = "Read a file",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &tools));
    const expected =
        \\{"model":"claude-test","max_tokens":4096,"stream":true,"system":"sys","messages":[{"role":"user","content":"first"},{"role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.txt"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"alpha"}]},{"role":"user","content":"second"}],"tools":[{"name":"read","description":"Read a file","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}}]}
    ;
    try std.testing.expectEqualStrings(expected, body);
}
