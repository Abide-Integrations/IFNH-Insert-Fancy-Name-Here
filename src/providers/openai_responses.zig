//! OpenAI Responses API adapter (ACTIVE_PLAN E-01).
//!
//! Streams SSE from `{base_url}/responses`. Same provider interface as the
//! Chat Completions adapter; only the wire shape differs: `input` items
//! instead of `messages`, flat tool specs, and typed stream events
//! (`response.output_text.delta`, `response.output_item.done`, ...). The
//! JSON `type` of each SSE payload names the event, so the `event:` line,
//! which `sse.Parser` skips, is not needed.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const transport = @import("transport.zig");
const openai = @import("openai.zig");
const trace_mod = @import("../core/trace.zig");
const core_types = @import("../core/types.zig");
const options_mod = @import("options.zig");

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

    const url = try std.fmt.allocPrint(arena, "{s}/responses", .{openai.trimSlash(req.base_url)});
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
    if (req.wire) |w| w.request("openai-responses", url, &.{
        .{ .name = "authorization", .value = auth_header },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
    }, body, req.api_key);

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
        const kind = provider.failureKindForStatus(@backingInt(response.head.status));
        var err_body: [16 * 1024]u8 = undefined;
        const r = response.reader(&err_body);
        const text = r.allocRemaining(arena, .limited(16 * 1024)) catch "";
        sink.emit(.{ .failure = .{
            .kind = kind,
            .message = openai.extractErrorMessage(arena, text) catch text,
            .retry_after_s = retry_after_s,
        } });
        return;
    }

    var transfer_buffer: [transfer_buffer_size]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var parser = sse.Parser{ .reader = reader };

    // Incremental function-call arguments, keyed by `item_id`. They are used
    // only when the finished item carries no `arguments` of its own, so one
    // item never produces two tool calls.
    var pending_args: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u8)) = .empty;

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
        const ev = openai.strOrEmpty(o.get("type"));

        if (std.mem.eql(u8, ev, "response.output_text.delta")) {
            const d = openai.strOrEmpty(o.get("delta"));
            if (d.len > 0) sink.emit(.{ .content_delta = d });
        } else if (std.mem.eql(u8, ev, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, ev, "response.reasoning_text.delta"))
        {
            const d = openai.strOrEmpty(o.get("delta"));
            if (d.len > 0) sink.emit(.{ .reasoning_delta = d });
        } else if (std.mem.eql(u8, ev, "response.function_call_arguments.delta")) {
            const item_id = openai.strOrEmpty(o.get("item_id"));
            if (item_id.len == 0) continue;
            const slot = try pending_args.getOrPut(arena, try arena.dupe(u8, item_id));
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.appendSlice(arena, openai.strOrEmpty(o.get("delta")));
        } else if (std.mem.eql(u8, ev, "response.output_item.done")) {
            const item = o.get("item") orelse continue;
            if (item != .object) continue;
            if (!std.mem.eql(u8, openai.strOrEmpty(item.object.get("type")), "function_call")) continue;
            const name = openai.strOrEmpty(item.object.get("name"));
            if (name.len == 0) continue;
            var call_id = openai.strOrEmpty(item.object.get("call_id"));
            if (call_id.len == 0) call_id = openai.strOrEmpty(item.object.get("id"));
            var args = openai.strOrEmpty(item.object.get("arguments"));
            if (args.len == 0) {
                if (pending_args.get(openai.strOrEmpty(item.object.get("id")))) |acc| args = acc.items;
            }
            sink.emit(.{ .tool_call = .{
                .id = call_id,
                .name = name,
                .arguments_json = if (args.len > 0) args else "{}",
            } });
        } else if (std.mem.eql(u8, ev, "response.completed")) {
            if (o.get("response")) |resp| {
                if (resp == .object) {
                    if (resp.object.get("usage")) |u| sink.emit(.{ .usage = parseUsage(u) });
                }
            }
            sink.emit(.done);
            return;
        } else if (std.mem.eql(u8, ev, "response.failed") or std.mem.eql(u8, ev, "response.incomplete")) {
            sink.emit(.{ .failure = responseFailure(o.get("response"), ev) });
            return;
        } else if (std.mem.eql(u8, ev, "error")) {
            sink.emit(.{ .failure = .{
                .kind = failureKindForCode(openai.strOrEmpty(o.get("code"))),
                .message = nonEmpty(openai.strOrEmpty(o.get("message")), "provider error"),
            } });
            return;
        }
    }

    // A stream that ended without `response.completed`: finish like the
    // other adapters do; calls were already emitted as their items closed.
    sink.emit(.done);
}

fn nonEmpty(s: []const u8, fallback: []const u8) []const u8 {
    return if (s.len > 0) s else fallback;
}

/// Map a Responses error `code` to a failure kind.
fn failureKindForCode(code: []const u8) core_types.ProviderFailureKind {
    if (std.mem.startsWith(u8, code, "rate_limit")) return .rate_limited;
    if (std.mem.eql(u8, code, "server_error")) return .server_error;
    if (std.mem.eql(u8, code, "invalid_prompt") or std.mem.startsWith(u8, code, "invalid_request")) return .invalid_request;
    return .other;
}

/// `response.failed` / `response.incomplete`: the reason lives in
/// `response.error` (failed) or `response.incomplete_details` (incomplete).
fn responseFailure(resp: ?std.json.Value, ev: []const u8) core_types.ProviderFailure {
    const default_msg: []const u8 = if (std.mem.eql(u8, ev, "response.incomplete")) "response incomplete" else "response failed";
    const r = resp orelse return .{ .kind = .other, .message = default_msg };
    if (r != .object) return .{ .kind = .other, .message = default_msg };
    if (r.object.get("error")) |e| {
        if (e == .object) return .{
            .kind = failureKindForCode(openai.strOrEmpty(e.object.get("code"))),
            .message = nonEmpty(openai.strOrEmpty(e.object.get("message")), default_msg),
        };
    }
    if (r.object.get("incomplete_details")) |d| {
        if (d == .object) return .{
            .kind = .other,
            .message = nonEmpty(openai.strOrEmpty(d.object.get("reason")), default_msg),
        };
    }
    return .{ .kind = .other, .message = default_msg };
}

/// Responses usage: `input_tokens`/`output_tokens`, cache hits under
/// `input_tokens_details.cached_tokens`; missing fields are zero.
fn parseUsage(u: std.json.Value) core_types.Usage {
    if (u != .object) return .{};
    const o = u.object;
    var out = core_types.Usage{
        .input_tokens = openai.intOf(o.get("input_tokens")) orelse 0,
        .output_tokens = openai.intOf(o.get("output_tokens")) orelse 0,
    };
    if (o.get("input_tokens_details")) |details| {
        if (details == .object) {
            out.cache_read_tokens = openai.intOf(details.object.get("cached_tokens")) orelse 0;
        }
    }
    return out;
}

fn writeDataUrl(w: *std.Io.Writer, img: core_types.ImagePart) !void {
    try w.writeAll("\"data:");
    try w.writeAll(img.media_type);
    try w.writeAll(";base64,");
    try w.writeAll(img.data_base64);
    try w.writeByte('"');
}

fn buildBody(arena: std.mem.Allocator, req: provider.ModelRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(req.model, .{}, w);
    try w.writeAll(",\"stream\":true,\"store\":false");
    if (req.system.len > 0) {
        try w.writeAll(",\"instructions\":");
        try std.json.Stringify.value(req.system, .{}, w);
    }
    try w.writeAll(",\"input\":[");

    var first = true;
    // call_ids from the most recent assistant message; an output without
    // one would make the request invalid, so it is dropped.
    var issued: std.ArrayListUnmanaged([]const u8) = .empty;
    for (req.messages) |msg| {
        switch (msg.role) {
            .system, .user => {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"role\":");
                try std.json.Stringify.value(@tagName(msg.role), .{}, w);
                try w.writeAll(",\"content\":[{\"type\":\"input_text\",\"text\":");
                try std.json.Stringify.value(msg.content, .{}, w);
                try w.writeByte('}');
                if (msg.role == .user) {
                    for (msg.images) |img| {
                        try w.writeAll(",{\"type\":\"input_image\",\"image_url\":");
                        try writeDataUrl(w, img);
                        try w.writeByte('}');
                    }
                }
                try w.writeAll("]}");
            },
            .assistant => {
                issued = .empty;
                if (msg.content.len > 0) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, w);
                    try w.writeAll("}]}");
                }
                const tcj = msg.tool_calls_json orelse continue;
                const tcv = std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{}) catch continue;
                if (tcv != .array) continue;
                for (tcv.array.items) |item| {
                    if (item != .object) continue;
                    const id = openai.strOrEmpty(item.object.get("id"));
                    const name = openai.strOrEmpty(item.object.get("name"));
                    if (id.len == 0 or name.len == 0) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(id, .{}, w);
                    try w.writeAll(",\"name\":");
                    try std.json.Stringify.value(name, .{}, w);
                    try w.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(openai.toolArguments(arena, item.object.get("arguments_json")), .{}, w);
                    try w.writeByte('}');
                    try issued.append(arena, try arena.dupe(u8, id));
                }
            },
            .tool => {
                const id = msg.tool_call_id orelse continue;
                const at = openai.indexOfStr(issued.items, id) orelse continue;
                _ = issued.orderedRemove(at);
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(id, .{}, w);
                try w.writeAll(",\"output\":");
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
            try w.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(spec.name, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(spec.description, .{}, w);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(spec.parameters_json);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    if (req.temperature) |t| try w.print(",\"temperature\":{d}", .{t});
    if (req.max_output_tokens) |t| try w.print(",\"max_output_tokens\":{d}", .{t});
    // Provider-specific options (D-05), only for keys this adapter compiles.
    try options_mod.splice(w, req.provider_options);
    try w.writeByte('}');
    return aw.written();
}

pub var instance_context: u8 = 0;

pub const instance = provider.Provider{
    .ctx = &instance_context,
    .stream_fn = streamFn,
    .capabilities_fn = capabilities,
};

/// Reasoning summaries stream as `reasoning_delta` events.
fn capabilities() provider.Capabilities {
    return .{ .streaming = true, .tool_use = true, .reasoning = true };
}

// ---------------------------------------------------------------- tests

const testing = @import("testing.zig");

/// 1x1 transparent PNG, base64.
const tiny_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

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

test "wire golden openai-responses body is byte-stable" {
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "checking", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "c1" },
        .{ .role = .user, .content = "second" },
    };
    const tools = [_]core_types.ToolSpec{
        .{ .name = "read", .description = "Read a file", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}" },
        .{ .name = "ls", .description = "List", .parameters_json = "{\"type\":\"object\"}" },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&msgs, &tools));
    const expected =
        \\{"model":"gpt-test","stream":true,"store":false,"instructions":"sys","input":[{"role":"user","content":[{"type":"input_text","text":"first"}]},{"role":"assistant","content":[{"type":"output_text","text":"checking"}]},{"type":"function_call","call_id":"c1","name":"read","arguments":"{\"path\":\"a.txt\"}"},{"type":"function_call_output","call_id":"c1","output":"alpha"},{"role":"user","content":[{"type":"input_text","text":"second"}]}],"tools":[{"type":"function","name":"read","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"function","name":"ls","description":"List","parameters":{"type":"object"}}]}
    ;
    try std.testing.expectEqualStrings(expected, body);
}

test "body keeps the text-only form stable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&.{.{ .role = .user, .content = "hi" }}, &.{}));
    try std.testing.expectEqualStrings(
        \\{"model":"gpt-test","stream":true,"store":false,"instructions":"sys","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}]}
    , body);
}

test "body drops empty assistant turns and orphan outputs; sampling and options are optional" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "" },
        .{ .role = .tool, .content = "stray", .tool_call_id = "zzz" },
    };
    var req = testRequest(&msgs, &.{});
    req.system = "";
    req.temperature = 0.5;
    req.max_output_tokens = 99;
    req.provider_options = "{\"reasoning\":{\"effort\":\"low\"}}";
    const body = try buildBody(arena, req);
    try std.testing.expectEqualStrings(
        \\{"model":"gpt-test","stream":true,"store":false,"input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"temperature":0.5,"max_output_tokens":99,"reasoning":{"effort":"low"}}
    , body);
}

test "body sends user images as input_image data URLs after the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const imgs = [_]core_types.ImagePart{.{ .media_type = "image/png", .data_base64 = tiny_png }};
    const msgs = [_]core_types.ChatMessage{.{ .role = .user, .content = "what is this", .images = &imgs }};
    var req = testRequest(&msgs, &.{});
    req.system = "";
    const body = try buildBody(arena, req);
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-test\",\"stream\":true,\"store\":false,\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"what is this\"},{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64," ++ tiny_png ++ "\"}]}]}",
        body,
    );
}

test "capabilities reports reasoning" {
    try std.testing.expect(instance.capabilities().reasoning);
    try std.testing.expect(instance.capabilities().tool_use);
}

test "stream: text, reasoning, incremental function call, usage, done in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "event: response.created\n" ++
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"delta\":\"Thinking.\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"Let me \"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"look.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_a\",\"name\":\"read\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"{\\\"path\\\":\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"\\\"a.txt\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_a\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_2\",\"call_id\":\"call_b\",\"name\":\"ls\",\"arguments\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":120,\"output_tokens\":30,\"input_tokens_details\":{\"cached_tokens\":100}}}}\n\n";

    const c = try testing.streamFixture(std.testing.io, arena, @This(), body);
    try std.testing.expect(c.failure == null);
    try std.testing.expectEqualStrings("Let me look.", c.text.items);
    try std.testing.expectEqualStrings("Thinking.", c.reasoning.items);
    try std.testing.expectEqual(@as(usize, 2), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_a", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", c.tool_calls.items[0].arguments_json);
    try std.testing.expectEqualStrings("call_b", c.tool_calls.items[1].id);
    try std.testing.expectEqualStrings("{}", c.tool_calls.items[1].arguments_json);
    const u = c.usage.?;
    try std.testing.expectEqual(@as(u64, 120), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 30), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), u.cache_read_tokens);

    try std.testing.expect(c.firstIndexOf(.reasoning_delta).? < c.firstIndexOf(.content_delta).?);
    try std.testing.expect(c.lastIndexOf(.content_delta).? < c.firstIndexOf(.tool_call).?);
    try std.testing.expect(c.lastIndexOf(.tool_call).? < c.firstIndexOf(.usage).?);
    try std.testing.expectEqual(@as(usize, c.events.items.len - 1), c.firstIndexOf(.done).?);
}

test "stream: response.failed, response.incomplete and error events become failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const limited = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"slow down\"}}}\n\n");
    try std.testing.expect(!limited.done);
    try std.testing.expectEqualStrings("slow down", limited.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.rate_limited, limited.failure_kind.?);

    const server = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}\n\n");
    try std.testing.expectEqual(core_types.ProviderFailureKind.server_error, server.failure_kind.?);

    const invalid = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"invalid_prompt\",\"message\":\"bad\"}}}\n\n");
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, invalid.failure_kind.?);

    const unknown = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"weird\",\"message\":\"?\"}}}\n\n");
    try std.testing.expectEqual(core_types.ProviderFailureKind.other, unknown.failure_kind.?);

    const incomplete = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n");
    try std.testing.expectEqualStrings("max_output_tokens", incomplete.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.other, incomplete.failure_kind.?);

    const err_event = try testing.streamFixture(io, arena, @This(), "data: {\"type\":\"error\",\"code\":\"invalid_request_error\",\"message\":\"context too long\"}\n\n");
    try std.testing.expectEqualStrings("context too long", err_event.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, err_event.failure_kind.?);
}

test "stream: a 429 keeps Retry-After and the provider message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c = try testing.streamFixtureWith(
        std.testing.io,
        arena,
        @This(),
        "429 Too Many Requests",
        "Content-Type: application/json\r\nRetry-After: 7\r\n",
        "{\"error\":{\"message\":\"slow down\"}}",
    );
    try std.testing.expect(!c.done);
    try std.testing.expectEqualStrings("slow down", c.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.rate_limited, c.failure_kind.?);
    try std.testing.expectEqual(@as(?u32, 7), c.retry_after_s);
}
