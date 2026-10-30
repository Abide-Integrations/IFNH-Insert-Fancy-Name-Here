//! OpenAI-compatible Chat Completions adapter (DECISIONS D40).
//!
//! Works against any OpenAI-compatible endpoint (OpenAI, OpenRouter,
//! Ollama, llama.cpp server, Z.AI, vLLM, custom proxies) with a
//! config-driven base URL. Streams SSE, accumulates tool calls, and emits
//! normalized events. This adapter is the generic fallback provider.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const transport = @import("transport.zig");
const trace_mod = @import("../core/trace.zig");
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
    var build_span = trace_mod.Span.begin(req.trace, "provider.request_build");
    const body = try buildBody(arena, req);
    build_span.end("");

    var fallback_client: std.http.Client = .{ .allocator = alloc, .io = io };
    const client = req.client orelse &fallback_client;
    defer if (req.client == null) fallback_client.deinit();

    var stream_span = trace_mod.Span.begin(req.trace, "provider.stream");
    defer stream_span.end("");

    var extra = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
    };
    const auth_header = if (req.api_key.len > 0)
        try std.fmt.allocPrint(arena, "Bearer {s}", .{req.api_key})
    else
        "";

    const connection = transport.openConnection(client, uri, transport.default_limits) catch |err| {
        sink.emit(.{ .failure = transport.failureFor(err, null) });
        return;
    };
    var creq = client.request(.POST, uri, .{
        .headers = .{
            .authorization = if (req.api_key.len > 0)
                .{ .override = auth_header }
            else
                .omit,
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
        // Read the headers before the body: `head.bytes` borrows the
        // connection read buffer that the body reader refills.
        const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
        const retry_after_s = transport.retryAfterFromHead(response.head, now_s);
        const kind = provider.failureKindForStatus(@intFromEnum(response.head.status));
        var err_body: [16 * 1024]u8 = undefined;
        const r = response.reader(&err_body);
        const text = r.allocRemaining(arena, .limited(16 * 1024)) catch "";
        sink.emit(.{ .failure = .{
            .kind = kind,
            .message = extractErrorMessage(arena, text) catch text,
            .retry_after_s = retry_after_s,
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
        emitted: bool = false,

        /// Emit this call once, when it is complete. The caller keeps the
        /// emitted slices for the rest of the stream call, so the arguments
        /// are copied out of the list that later deltas would grow. `id` and
        /// `name` are already arena-owned from the delta that carried them.
        fn emit(self: *@This(), arena_mem: std.mem.Allocator, event_sink: provider.Sink) !void {
            if (self.emitted or self.name.len == 0) return;
            const args = try arena_mem.dupe(u8, self.args.items);
            self.emitted = true;
            event_sink.emit(.{ .tool_call = .{
                .id = self.id,
                .name = self.name,
                .arguments_json = args,
            } });
        }
    };
    var tools: [16]ToolAcc = undefined;
    var tool_count: usize = 0;

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
            sink.emit(.{ .usage = parseUsage(usage_v) });
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
                            const index = std.math.cast(usize, intOf(io_.get("index")) orelse tool_count) orelse continue;
                            if (index >= tools.len) continue;
                            while (tool_count <= index) : (tool_count += 1) {
                                tools[tool_count] = .{};
                            }
                            // A higher index means every lower call is complete.
                            for (tools[0..index]) |*done| try done.emit(arena, sink);
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
        if (finish_v == .string) {
            // The choice is finished: emit whatever is still pending, in
            // index order.
            for (tools[0..tool_count]) |*t| try t.emit(arena, sink);
        }
    }

    // Fallback for a stream that ended without a finish_reason: emit each
    // call that was never flushed.
    for (tools[0..tool_count]) |*t| try t.emit(arena, sink);

    sink.emit(.done);
}

fn trimSlash(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, "/")) s[0 .. s.len - 1] else s;
}

/// Chat Completions usage (B-03): OpenAI reports cache hits under
/// `prompt_tokens_details.cached_tokens`; missing fields are zero.
fn parseUsage(u: std.json.Value) core_types.Usage {
    if (u != .object) return .{};
    const o = u.object;
    var out = core_types.Usage{
        .input_tokens = intOf(o.get("prompt_tokens")) orelse 0,
        .output_tokens = intOf(o.get("completion_tokens")) orelse 0,
    };
    if (o.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            out.cache_read_tokens = intOf(details.object.get("cached_tokens")) orelse 0;
        }
    }
    return out;
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

fn strOrEmpty(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

fn indexOfStr(items: []const []const u8, needle: []const u8) ?usize {
    for (items, 0..) |item, idx| {
        if (std.mem.eql(u8, item, needle)) return idx;
    }
    return null;
}

/// `arguments` is a JSON *string* on the OpenAI wire. Malformed or non-object
/// arguments degrade to "{}" so one bad call does not break the request.
fn toolArguments(arena: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const raw = args orelse return "{}";
    if (raw != .string or raw.string.len == 0) return "{}";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw.string, .{}) catch return "{}";
    if (parsed != .object) return "{}";
    return raw.string;
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
    // tool_call ids from the most recent assistant message; a tool result
    // without one would make the request invalid, so it is dropped.
    var issued: std.ArrayListUnmanaged([]const u8) = .empty;
    for (req.messages) |msg| {
        switch (msg.role) {
            .system, .user => {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":");
                try std.json.Stringify.value(@tagName(msg.role), .{}, w);
                try w.writeAll(",\"content\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
            },
            .assistant => {
                issued = .empty;
                var msg_buf: std.Io.Writer.Allocating = .init(arena);
                const mw = &msg_buf.writer;
                try mw.writeAll("{\"role\":\"assistant\",\"content\":");
                if (msg.content.len > 0) {
                    try std.json.Stringify.value(msg.content, .{}, mw);
                } else {
                    try mw.writeAll("null");
                }
                var call_count: usize = 0;
                if (msg.tool_calls_json) |tcj| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{})) |tcv| {
                        if (tcv == .array) {
                            for (tcv.array.items) |item| {
                                if (item != .object) continue;
                                const id = strOrEmpty(item.object.get("id"));
                                const name = strOrEmpty(item.object.get("name"));
                                if (id.len == 0 or name.len == 0) continue;
                                try mw.writeAll(if (call_count == 0) ",\"tool_calls\":[" else ",");
                                try mw.writeAll("{\"id\":");
                                try std.json.Stringify.value(id, .{}, mw);
                                try mw.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                                try std.json.Stringify.value(name, .{}, mw);
                                try mw.writeAll(",\"arguments\":");
                                try std.json.Stringify.value(toolArguments(arena, item.object.get("arguments_json")), .{}, mw);
                                try mw.writeAll("}}");
                                call_count += 1;
                                const owned_id = arena.dupe(u8, id) catch continue;
                                try issued.append(arena, owned_id);
                            }
                        }
                    } else |_| {}
                }
                if (call_count > 0) try mw.writeByte(']');
                // An assistant turn with neither text nor calls carries
                // nothing the API accepts.
                if (msg.content.len == 0 and call_count == 0) continue;
                try mw.writeByte('}');
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll(msg_buf.written());
            },
            .tool => {
                const id = msg.tool_call_id orelse continue;
                const at = indexOfStr(issued.items, id) orelse continue;
                _ = issued.orderedRemove(at);
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(id, .{}, w);
                try w.writeAll(",\"content\":");
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
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(spec.name, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(spec.description, .{}, w);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(spec.parameters_json);
            try w.writeAll("}}");
        }
        try w.writeAll("],\"tool_choice\":\"auto\"");
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

// ---------------------------------------------------------------- tests

fn testRequest(msgs: []const core_types.ChatMessage, tools: []const core_types.ToolSpec) provider.ModelRequest {
    return .{
        .model = "gpt-test",
        .base_url = "https://api.openai.com/v1",
        .api_key = "k",
        .system = "sys",
        .messages = msgs,
        .tools = tools,
        .cancel = undefined,
    };
}

test "body carries assistant tool_calls so tool results pair up" {
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"},{\"id\":\"c2\",\"name\":\"bash\",\"arguments_json\":\"not json\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "c1" },
        .{ .role = .tool, .content = "boom", .tool_call_id = "c2", .is_error = true },
        .{ .role = .tool, .content = "stray", .tool_call_id = "zzz" },
    };
    const tools = [_]core_types.ToolSpec{
        .{ .name = "read", .description = "d", .parameters_json = "{\"type\":\"object\"}" },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &tools));
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});

    // Assistant text is null but tool_calls are present and well-formed.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"c2\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}") != null);

    // Results for issued calls only; the orphan is dropped.
    try std.testing.expect(std.mem.indexOf(u8, body, "stray") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"alpha\"}") != null);

    // Tool schemas use the OpenAI function envelope.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"}}}]") != null);
}

test "body skips empty assistant turns and keeps plain replies" {
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "" },
        .{ .role = .assistant, .content = "hello" },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &.{}));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    try std.testing.expect(parsed == .object);
    const arr = parsed.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len); // system + user + assistant
    try std.testing.expectEqualStrings("assistant", arr.items[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", arr.items[2].object.get("content").?.string);
    try std.testing.expect(parsed.object.get("tools") == null);
}

test "wire golden openai body is byte-stable" {
    // A fixed request renders byte-for-byte: no maps are involved (every
    // field is written in source order), so the full body is asserted
    // instead of a substring set.
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "checking", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "c1" },
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
        \\{"model":"gpt-test","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"system","content":"sys"},{"role":"user","content":"first"},{"role":"assistant","content":"checking","tool_calls":[{"id":"c1","type":"function","function":{"name":"read","arguments":"{\"path\":\"a.txt\"}"}}]},{"role":"tool","tool_call_id":"c1","content":"alpha"},{"role":"user","content":"second"}],"tools":[{"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}}],"tool_choice":"auto"}
    ;
    try std.testing.expectEqualStrings(expected, body);
}

test "body emits max_tokens only when configured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req = testRequest(&.{.{ .role = .user, .content = "hi" }}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, try buildBody(arena, req), "max_tokens") == null);
    req.max_output_tokens = 1234;
    try std.testing.expect(std.mem.indexOf(u8, try buildBody(arena, req), "\"max_tokens\":1234") != null);
}

test "usage parses prompt_tokens_details.cached_tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cached = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt_tokens":120,"completion_tokens":9,"prompt_tokens_details":{"cached_tokens":64}}
    , .{});
    const u = parseUsage(cached);
    try std.testing.expectEqual(@as(u64, 120), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 9), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 64), u.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 0), u.cache_write_tokens);

    // Absent details block reads as a cache miss.
    const plain = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"prompt_tokens\":5,\"completion_tokens\":2}", .{});
    const v = parseUsage(plain);
    try std.testing.expectEqual(@as(u64, 5), v.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), v.cache_read_tokens);
}
