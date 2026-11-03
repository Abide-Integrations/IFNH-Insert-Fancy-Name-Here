//! Native Gemini adapter (ACTIVE_PLAN E-02).
//!
//! Streams SSE from `{base_url}/models/{model}:streamGenerateContent?alt=sse`.
//! Each `data:` payload is a whole `GenerateContentResponse` chunk, so there
//! is no event name to dispatch on: parts, usage and the finish reason are
//! read from every chunk. Conversation turns map to `user`/`model` contents;
//! tool results are `functionResponse` parts on a `user` turn.
//!
//! Credentials: `auth = .api_key` sends `x-goog-api-key`; `.oauth` sends the
//! same string as `Authorization: Bearer` (a Google OAuth access token). There
//! is no login flow here: the token comes from the configured key env var.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const transport = @import("transport.zig");
const openai = @import("openai.zig");
const trace_mod = @import("../core/trace.zig");
const core_types = @import("../core/types.zig");
const wire_log = @import("../core/wire_log.zig");
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
    // The model id is part of the URL path: a `/` or `?` would redirect the
    // request to another endpoint.
    if (std.mem.indexOfAny(u8, req.model, "/?") != null) return error.InvalidModel;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try std.fmt.allocPrint(arena, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ openai.trimSlash(req.base_url), req.model });
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    var build_span = trace_mod.Span.begin(req.trace, "provider.request_build");
    const body = try buildBody(arena, req);
    build_span.end("");

    var fallback_client: std.http.Client = .{ .allocator = alloc, .io = io };
    const client = req.client orelse &fallback_client;
    defer if (req.client == null) fallback_client.deinit();

    var stream_span = trace_mod.Span.begin(req.trace, "provider.stream");
    defer stream_span.end("");

    // An empty key sends no credential; the server answers 401.
    const bearer = req.auth == .oauth and req.api_key.len > 0;
    const auth_header = if (bearer) try std.fmt.allocPrint(arena, "Bearer {s}", .{req.api_key}) else "";
    var extra_buf: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    extra_buf[extra_len] = .{ .name = "accept", .value = "text/event-stream" };
    extra_len += 1;
    if (req.auth == .api_key and req.api_key.len > 0) {
        extra_buf[extra_len] = .{ .name = "x-goog-api-key", .value = req.api_key };
        extra_len += 1;
    }
    if (req.wire) |w| {
        var wire_headers: [3]wire_log.Header = undefined;
        var n: usize = 0;
        if (bearer) {
            wire_headers[n] = .{ .name = "authorization", .value = auth_header };
            n += 1;
        } else if (req.api_key.len > 0) {
            wire_headers[n] = .{ .name = "x-goog-api-key", .value = req.api_key };
            n += 1;
        }
        wire_headers[n] = .{ .name = "content-type", .value = "application/json" };
        wire_headers[n + 1] = .{ .name = "accept", .value = "text/event-stream" };
        w.request("gemini", url, wire_headers[0 .. n + 2], body, req.api_key);
    }

    const connection = transport.openConnection(client, uri, transport.default_limits) catch |err| {
        sink.emit(.{ .failure = transport.failureFor(err, null) });
        return;
    };
    var creq = client.request(.POST, uri, .{
        .headers = .{
            .authorization = if (bearer) .{ .override = auth_header } else .omit,
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = extra_buf[0..extra_len],
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
        const status: u16 = @intFromEnum(response.head.status);
        const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
        const retry_after_s = transport.retryAfterFromHead(response.head, now_s);
        var err_body: [16 * 1024]u8 = undefined;
        const r = response.reader(&err_body);
        const text = r.allocRemaining(arena, .limited(16 * 1024)) catch "";
        const detail = extractErrorMessage(arena, text) catch std.mem.trim(u8, text, " \t\r\n");
        sink.emit(.{ .failure = .{
            .kind = provider.failureKindForStatus(status),
            .message = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, detail }),
            .retry_after_s = retry_after_s,
        } });
        return;
    }

    var transfer_buffer: [transfer_buffer_size]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var parser = sse.Parser{ .reader = reader };

    // Calls already emitted, as `name\x00args`: Gemini may repeat a
    // functionCall in the final chunk.
    var seen_calls: std.ArrayListUnmanaged([]const u8) = .empty;
    var call_count: usize = 0;
    var usage: ?core_types.Usage = null;
    var finish: []const u8 = "";
    var block_reason: []const u8 = "";

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

        if (o.get("promptFeedback")) |pf| {
            if (pf == .object) {
                const reason = openai.strOrEmpty(pf.object.get("blockReason"));
                if (reason.len > 0) block_reason = reason;
            }
        }
        if (o.get("usageMetadata")) |u| usage = parseUsage(u);

        const candidates = o.get("candidates") orelse continue;
        if (candidates != .array or candidates.array.items.len == 0) continue;
        const cand = candidates.array.items[0];
        if (cand != .object) continue;
        if (cand.object.get("content")) |content| {
            if (content == .object) {
                if (content.object.get("parts")) |parts| {
                    if (parts == .array) {
                        for (parts.array.items) |part| {
                            try handlePart(arena, sink, part, &seen_calls, &call_count);
                        }
                    }
                }
            }
        }
        const reason = openai.strOrEmpty(cand.object.get("finishReason"));
        if (reason.len > 0) finish = reason;
    }

    // Usage first, then exactly one terminal event.
    if (usage) |u| sink.emit(.{ .usage = u });
    if (block_reason.len > 0) {
        sink.emit(.{ .failure = .{
            .kind = .invalid_request,
            .message = try std.fmt.allocPrint(arena, "prompt blocked: {s}", .{block_reason}),
        } });
    } else if (isFailureFinish(finish)) {
        sink.emit(.{ .failure = .{
            .kind = .invalid_request,
            .message = try std.fmt.allocPrint(arena, "finish reason: {s}", .{finish}),
        } });
    } else {
        sink.emit(.done);
    }
}

/// STOP and MAX_TOKENS end a response normally (truncation is not an error);
/// every other reason (SAFETY, RECITATION, BLOCKLIST, PROHIBITED_CONTENT,
/// OTHER, MALFORMED_FUNCTION_CALL, ...) means the answer was refused or cut
/// off by the service. A stream without a finish reason ends as `done`.
fn isFailureFinish(reason: []const u8) bool {
    if (reason.len == 0) return false;
    return !(std.mem.eql(u8, reason, "STOP") or
        std.mem.eql(u8, reason, "MAX_TOKENS") or
        std.mem.eql(u8, reason, "FINISH_REASON_UNSPECIFIED"));
}

fn handlePart(
    arena: std.mem.Allocator,
    sink: provider.Sink,
    part: std.json.Value,
    seen_calls: *std.ArrayListUnmanaged([]const u8),
    call_count: *usize,
) !void {
    if (part != .object) return;
    if (part.object.get("functionCall")) |fc| {
        if (fc != .object) return;
        const name = openai.strOrEmpty(fc.object.get("name"));
        if (name.len == 0) return;
        var args: []const u8 = "{}";
        if (fc.object.get("args")) |a| {
            if (a == .object) {
                var aw: std.Io.Writer.Allocating = .init(arena);
                try std.json.Stringify.value(a, .{}, &aw.writer);
                args = aw.written();
            }
        }
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ name, args });
        for (seen_calls.items) |seen| {
            if (std.mem.eql(u8, seen, key)) return;
        }
        try seen_calls.append(arena, key);
        call_count.* += 1;
        sink.emit(.{ .tool_call = .{
            .id = try std.fmt.allocPrint(arena, "call_{d}", .{call_count.*}),
            .name = name,
            .arguments_json = args,
        } });
        return;
    }
    const text = openai.strOrEmpty(part.object.get("text"));
    if (text.len == 0) return;
    const thought = if (part.object.get("thought")) |t| t == .bool and t.bool else false;
    if (thought) {
        sink.emit(.{ .reasoning_delta = text });
    } else {
        sink.emit(.{ .content_delta = text });
    }
}

/// `usageMetadata`: reasoning ("thoughts") tokens are billed as output.
fn parseUsage(u: std.json.Value) core_types.Usage {
    if (u != .object) return .{};
    const o = u.object;
    return .{
        .input_tokens = openai.intOf(o.get("promptTokenCount")) orelse 0,
        .output_tokens = (openai.intOf(o.get("candidatesTokenCount")) orelse 0) +
            (openai.intOf(o.get("thoughtsTokenCount")) orelse 0),
        .cache_read_tokens = openai.intOf(o.get("cachedContentTokenCount")) orelse 0,
    };
}

/// `{"error":{"code":..,"message":..,"status":..}}` -> message.
fn extractErrorMessage(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (v == .object) {
        if (v.object.get("error")) |e| {
            if (e == .object) {
                const m = openai.strOrEmpty(e.object.get("message"));
                if (m.len > 0) return m;
            }
        }
    }
    return error.NotFound;
}

fn writeTurnOpen(w: *std.Io.Writer, first: *bool, role: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll("{\"role\":\"");
    try w.writeAll(role);
    try w.writeAll("\",\"parts\":[");
}

/// A tool result payload: JSON objects and arrays pass through as JSON,
/// anything else (including bare numbers and `true`) stays a string.
fn writeResultValue(w: *std.Io.Writer, arena: std.mem.Allocator, content: []const u8) !void {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len > 1 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{})) |_| {
            try w.writeAll(trimmed);
            return;
        } else |_| {}
    }
    try std.json.Stringify.value(content, .{}, w);
}

/// Name of the call `id` from the nearest assistant message before `before`.
fn callNameFor(arena: std.mem.Allocator, messages: []const core_types.ChatMessage, before: usize, id: []const u8) ?[]const u8 {
    var i = before;
    while (i > 0) {
        i -= 1;
        const m = messages[i];
        if (m.role != .assistant) continue;
        const tcj = m.tool_calls_json orelse continue;
        const tcv = std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{}) catch continue;
        if (tcv != .array) continue;
        for (tcv.array.items) |item| {
            if (item != .object) continue;
            if (!std.mem.eql(u8, openai.strOrEmpty(item.object.get("id")), id)) continue;
            const name = openai.strOrEmpty(item.object.get("name"));
            if (name.len > 0) return name;
        }
    }
    return null;
}

/// Request body. Key order is fixed: contents, systemInstruction,
/// generationConfig, tools. `req.system_stable_len` is ignored on purpose:
/// this adapter has no Gemini context-cache support, so the system prompt is
/// always one block.
fn buildBody(arena: std.mem.Allocator, req: provider.ModelRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"contents\":[");
    var first = true;
    for (req.messages, 0..) |msg, idx| {
        switch (msg.role) {
            .system, .user => {
                // Gemini has no system turn in `contents`: a stray system
                // message travels as user text.
                const has_images = msg.role == .user and msg.images.len > 0;
                if (msg.content.len == 0 and !has_images) continue;
                try writeTurnOpen(w, &first, "user");
                var parts: usize = 0;
                if (msg.content.len > 0) {
                    try w.writeAll("{\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, w);
                    try w.writeByte('}');
                    parts += 1;
                }
                if (msg.role == .user) {
                    for (msg.images) |img| {
                        if (parts > 0) try w.writeByte(',');
                        parts += 1;
                        try w.writeAll("{\"inlineData\":{\"mimeType\":");
                        try std.json.Stringify.value(img.media_type, .{}, w);
                        try w.writeAll(",\"data\":");
                        try std.json.Stringify.value(img.data_base64, .{}, w);
                        try w.writeAll("}}");
                    }
                }
                try w.writeAll("]}");
            },
            .assistant => {
                var turn: std.Io.Writer.Allocating = .init(arena);
                var parts: usize = 0;
                if (msg.content.len > 0) {
                    try turn.writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(msg.content, .{}, &turn.writer);
                    try turn.writer.writeByte('}');
                    parts += 1;
                }
                if (msg.tool_calls_json) |tcj| {
                    if (std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{})) |tcv| {
                        if (tcv == .array) {
                            for (tcv.array.items) |item| {
                                if (item != .object) continue;
                                const name = openai.strOrEmpty(item.object.get("name"));
                                if (name.len == 0) continue;
                                if (parts > 0) try turn.writer.writeByte(',');
                                parts += 1;
                                try turn.writer.writeAll("{\"functionCall\":{\"name\":");
                                try std.json.Stringify.value(name, .{}, &turn.writer);
                                try turn.writer.writeAll(",\"args\":");
                                try turn.writer.writeAll(openai.toolArguments(arena, item.object.get("arguments_json")));
                                try turn.writer.writeAll("}}");
                            }
                        }
                    } else |_| {}
                }
                if (parts == 0) continue; // an empty turn is invalid on the wire
                try writeTurnOpen(w, &first, "model");
                try w.writeAll(turn.written());
                try w.writeAll("]}");
            },
            .tool => {
                // The name comes from the message, else from the call it
                // answers; with neither the result is dropped rather than
                // sent under an invented name.
                const name = msg.tool_name orelse blk: {
                    const id = msg.tool_call_id orelse continue;
                    break :blk callNameFor(arena, req.messages, idx, id) orelse continue;
                };
                try writeTurnOpen(w, &first, "user");
                try w.writeAll("{\"functionResponse\":{\"name\":");
                try std.json.Stringify.value(name, .{}, w);
                try w.writeAll(",\"response\":{");
                try w.writeAll(if (msg.is_error) "\"error\":" else "\"result\":");
                try writeResultValue(w, arena, msg.content);
                try w.writeAll("}}}]}");
            },
        }
    }
    try w.writeByte(']');

    if (req.system.len > 0) {
        try w.writeAll(",\"systemInstruction\":{\"parts\":[{\"text\":");
        try std.json.Stringify.value(req.system, .{}, w);
        try w.writeAll("}]}");
    }

    const opts = options_mod.members(req.provider_options);
    if (req.temperature != null or req.max_output_tokens != null or opts.len > 0) {
        try w.writeAll(",\"generationConfig\":{");
        var gc_first = true;
        if (req.temperature) |t| {
            try w.print("\"temperature\":{d}", .{t});
            gc_first = false;
        }
        if (req.max_output_tokens) |t| {
            if (!gc_first) try w.writeByte(',');
            try w.print("\"maxOutputTokens\":{d}", .{t});
            gc_first = false;
        }
        if (opts.len > 0) {
            if (!gc_first) try w.writeByte(',');
            try w.writeAll(opts);
        }
        try w.writeByte('}');
    }

    if (req.tools.len > 0) {
        try w.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (req.tools, 0..) |spec, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(spec.name, .{}, w);
            try w.writeAll(",\"description\":");
            try std.json.Stringify.value(spec.description, .{}, w);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(spec.parameters_json);
            try w.writeByte('}');
        }
        try w.writeAll("]}]");
    }
    try w.writeByte('}');
    return aw.written();
}

pub var instance_context: u8 = 0;

pub const instance = provider.Provider{
    .ctx = &instance_context,
    .stream_fn = streamFn,
    .capabilities_fn = capabilities,
};

/// Thought parts stream as `reasoning_delta` events.
fn capabilities() provider.Capabilities {
    return .{ .streaming = true, .tool_use = true, .reasoning = true };
}

// ---------------------------------------------------------------- tests

const testing = @import("testing.zig");

/// 1x1 transparent PNG, base64.
const tiny_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

fn testRequest(msgs: []const core_types.ChatMessage, tools: []const core_types.ToolSpec) provider.ModelRequest {
    return .{
        .model = "gemini-test",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .api_key = "k",
        .system = "sys",
        .messages = msgs,
        .tools = tools,
        .cancel = undefined,
    };
}

test "wire golden gemini body is byte-stable (text only)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildBody(arena, testRequest(&.{.{ .role = .user, .content = "hi" }}, &.{}));
    try std.testing.expectEqualStrings(
        \\{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"systemInstruction":{"parts":[{"text":"sys"}]}}
    , body);
}

test "wire golden gemini body with tools, images and system is byte-stable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const imgs = [_]core_types.ImagePart{.{ .media_type = "image/png", .data_base64 = tiny_png }};
    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "what is this", .images = &imgs },
        .{ .role = .assistant, .content = "checking", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}]" },
        .{ .role = .tool, .content = "alpha", .tool_call_id = "c1", .tool_name = "read" },
        .{ .role = .user, .content = "second" },
    };
    const tools = [_]core_types.ToolSpec{
        .{ .name = "read", .description = "Read a file", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}" },
        .{ .name = "ls", .description = "List", .parameters_json = "{\"type\":\"object\"}" },
    };
    var req = testRequest(&msgs, &tools);
    req.temperature = 0.5;
    req.max_output_tokens = 99;
    req.provider_options = "{\"thinkingConfig\":{\"thinkingBudget\":8,\"includeThoughts\":true}}";
    req.system_stable_len = 1; // no split: Gemini caching is not supported here
    const body = try buildBody(arena, req);
    try std.testing.expectEqualStrings(
        "{\"contents\":[" ++
            "{\"role\":\"user\",\"parts\":[{\"text\":\"what is this\"},{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"" ++ tiny_png ++ "\"}}]}," ++
            "{\"role\":\"model\",\"parts\":[{\"text\":\"checking\"},{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a.txt\"}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"read\",\"response\":{\"result\":\"alpha\"}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"text\":\"second\"}]}]," ++
            "\"systemInstruction\":{\"parts\":[{\"text\":\"sys\"}]}," ++
            "\"generationConfig\":{\"temperature\":0.5,\"maxOutputTokens\":99,\"thinkingConfig\":{\"thinkingBudget\":8,\"includeThoughts\":true}}," ++
            "\"tools\":[{\"functionDeclarations\":[" ++
            "{\"name\":\"read\",\"description\":\"Read a file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}}," ++
            "{\"name\":\"ls\",\"description\":\"List\",\"parameters\":{\"type\":\"object\"}}]}]}",
        body,
    );
}

test "body renders a tool result with the name recovered from tool_call_id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]core_types.ChatMessage{
        .{ .role = .assistant, .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{}\"},{\"id\":\"c2\",\"name\":\"ls\",\"arguments_json\":\"{}\"}]" },
        .{ .role = .tool, .content = "{\"lines\":3}", .tool_call_id = "c2" },
        .{ .role = .tool, .content = "no such file", .tool_call_id = "c1", .is_error = true },
        // No name on the message and no matching call: dropped, never invented.
        .{ .role = .tool, .content = "stray", .tool_call_id = "zzz" },
        .{ .role = .tool, .content = "42", .tool_call_id = "c1" },
    };
    var req = testRequest(&msgs, &.{});
    req.system = "";
    const body = try buildBody(arena, req);
    try std.testing.expectEqualStrings(
        "{\"contents\":[" ++
            "{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"read\",\"args\":{}}},{\"functionCall\":{\"name\":\"ls\",\"args\":{}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"ls\",\"response\":{\"result\":{\"lines\":3}}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"read\",\"response\":{\"error\":\"no such file\"}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"read\",\"response\":{\"result\":\"42\"}}}]}]}",
        body,
    );
}

test "body omits empty assistant turns and unset sampling fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]core_types.ChatMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "" },
        .{ .role = .user, .content = "again" },
    };
    var req = testRequest(&msgs, &.{});
    req.system = "";
    const body = try buildBody(arena, req);
    // Two consecutive user turns are kept as they are.
    try std.testing.expectEqualStrings(
        \\{"contents":[{"role":"user","parts":[{"text":"hi"}]},{"role":"user","parts":[{"text":"again"}]}]}
    , body);
    try std.testing.expect(std.mem.indexOf(u8, body, "generationConfig") == null);
}

test "capabilities report streaming, tool use and reasoning" {
    const caps = instance.capabilities();
    try std.testing.expect(caps.streaming);
    try std.testing.expect(caps.tool_use);
    try std.testing.expect(caps.reasoning);
}

const Run = struct { c: testing.Collector, head: []const u8 };

/// One adapter round against a canned response; returns the events and the
/// request head the server saw.
fn runWith(
    arena: std.mem.Allocator,
    status_line: []const u8,
    extra_headers: []const u8,
    body: []const u8,
    api_key: []const u8,
    auth: provider.Auth,
    model: []const u8,
) !Run {
    const io = std.testing.io;
    const srv = try testing.FakeServer.startWith(io, arena, status_line, extra_headers, body);
    defer srv.stop();
    var cancel = std.atomic.Value(bool).init(false);
    var collector = testing.Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1beta", .{srv.port});
    try streamFn(undefined, arena, io, .{
        .model = model,
        .base_url = base,
        .api_key = api_key,
        .auth = auth,
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = testing.Collector.emit });
    srv.wait();
    return .{ .c = collector, .head = try arena.dupe(u8, srv.requestHead()) };
}

fn sseRun(arena: std.mem.Allocator, body: []const u8) !testing.Collector {
    return (try runWith(arena, "200 OK", "Content-Type: text/event-stream\r\n", body, "k", .api_key, "gemini-test")).c;
}

test "stream: text, thoughts, one functionCall, usage, STOP in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hmm.\",\"thought\":true}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Let me \"}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"look.\"},{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a.txt\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":120,\"candidatesTokenCount\":20,\"thoughtsTokenCount\":10,\"cachedContentTokenCount\":100}}\n\n";
    const c = try sseRun(arena, body);
    try std.testing.expect(c.failure == null);
    try std.testing.expectEqualStrings("Let me look.", c.text.items);
    try std.testing.expectEqualStrings("Hmm.", c.reasoning.items);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", c.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", c.tool_calls.items[0].arguments_json);
    const u = c.usage.?;
    try std.testing.expectEqual(@as(u64, 120), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 30), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), u.cache_read_tokens);

    try std.testing.expect(c.firstIndexOf(.reasoning_delta).? < c.firstIndexOf(.content_delta).?);
    try std.testing.expect(c.lastIndexOf(.content_delta).? < c.firstIndexOf(.tool_call).?);
    try std.testing.expect(c.lastIndexOf(.tool_call).? < c.firstIndexOf(.usage).?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(testing.EventKind, c.events.items, &.{.done}));
    try std.testing.expectEqual(@as(usize, c.events.items.len - 1), c.firstIndexOf(.done).?);
}

test "stream: a functionCall repeated in the final chunk is emitted once; a missing args is {}" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a\"}}},{\"functionCall\":{\"name\":\"ls\"}}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\",\"args\":{\"path\":\"a\"}}}]},\"finishReason\":\"STOP\"}]}\n\n";
    const c = try sseRun(arena, body);
    try std.testing.expectEqual(@as(usize, 2), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("call_2", c.tool_calls.items[1].id);
    try std.testing.expectEqualStrings("{}", c.tool_calls.items[1].arguments_json);
    try std.testing.expect(c.done);
}

test "stream: MAX_TOKENS ends normally; SAFETY and friends are failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const truncated = try sseRun(arena, "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"cut\"}]},\"finishReason\":\"MAX_TOKENS\"}]}\n\n");
    try std.testing.expect(truncated.done);
    try std.testing.expect(truncated.failure == null);

    const safety = try sseRun(arena, "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"par\"}]},\"finishReason\":\"SAFETY\"}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":1}}\n\n");
    try std.testing.expect(!safety.done);
    try std.testing.expectEqualStrings("finish reason: SAFETY", safety.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, safety.failure_kind.?);
    try std.testing.expectEqualStrings("par", safety.text.items);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(testing.EventKind, safety.events.items, &.{.failure}));

    for ([_][]const u8{ "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "OTHER" }) |reason| {
        const chunk = try std.fmt.allocPrint(arena, "data: {{\"candidates\":[{{\"finishReason\":\"{s}\"}}]}}\n\n", .{reason});
        const c = try sseRun(arena, chunk);
        try std.testing.expect(!c.done);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "finish reason: {s}", .{reason}), c.failure.?);
    }
}

test "stream: promptFeedback.blockReason fails even with no candidates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c = try sseRun(arena, "data: {\"promptFeedback\":{\"blockReason\":\"PROHIBITED_CONTENT\"},\"usageMetadata\":{\"promptTokenCount\":3}}\n\n");
    try std.testing.expect(!c.done);
    try std.testing.expect(std.mem.indexOf(u8, c.failure.?, "PROHIBITED_CONTENT") != null);
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, c.failure_kind.?);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(testing.EventKind, c.events.items, &.{.failure}));
}

test "stream: a 429 keeps Retry-After and the provider message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try runWith(arena, "429 Too Many Requests", "Content-Type: application/json\r\nRetry-After: 7\r\n", "{\"error\":{\"code\":429,\"message\":\"slow down\",\"status\":\"RESOURCE_EXHAUSTED\"}}", "k", .api_key, "gemini-test");
    try std.testing.expect(!r.c.done);
    try std.testing.expectEqualStrings("HTTP 429: slow down", r.c.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.rate_limited, r.c.failure_kind.?);
    try std.testing.expectEqual(@as(?u32, 7), r.c.retry_after_s);
}

test "stream: a 400 JSON error body becomes HTTP 400 invalid_request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try runWith(arena, "400 Bad Request", "Content-Type: application/json\r\n", "{\"error\":{\"code\":400,\"message\":\"API key not valid.\",\"status\":\"INVALID_ARGUMENT\"}}", "k", .api_key, "gemini-test");
    try std.testing.expectEqualStrings("HTTP 400: API key not valid.", r.c.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, r.c.failure_kind.?);
}

test "request: api_key mode sends x-goog-api-key to the streamGenerateContent path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try runWith(arena, "200 OK", "Content-Type: text/event-stream\r\n", "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n", "secret-key", .api_key, "gemini-2.5-pro");
    try std.testing.expect(r.c.done);
    try std.testing.expect(std.mem.startsWith(u8, r.head, "POST /v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse HTTP/1.1"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "x-goog-api-key: secret-key") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "authorization:") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "accept: text/event-stream") != null);
}

test "request: oauth mode sends a Bearer token and no x-goog-api-key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try runWith(arena, "200 OK", "Content-Type: text/event-stream\r\n", "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n", "ya29.token", .oauth, "gemini-test");
    try std.testing.expect(r.c.done);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "authorization: Bearer ya29.token") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "x-goog-api-key") == null);
}

test "request: a missing key sends no credential and the 401 is unauthorized" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try runWith(arena, "401 Unauthorized", "Content-Type: application/json\r\n", "{\"error\":{\"code\":401,\"message\":\"missing credentials\",\"status\":\"UNAUTHENTICATED\"}}", "", .api_key, "gemini-test");
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "x-goog-api-key") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.head, "authorization") == null);
    try std.testing.expectEqual(core_types.ProviderFailureKind.unauthorized, r.c.failure_kind.?);
    try std.testing.expectEqualStrings("HTTP 401: missing credentials", r.c.failure.?);
}

test "request: a model id with / or ? is rejected before any connection" {
    var cancel = std.atomic.Value(bool).init(false);
    var collector = testing.Collector{ .arena = std.testing.allocator };
    const sink = provider.Sink{ .ctx = &collector, .emit_fn = testing.Collector.emit };
    for ([_][]const u8{ "models/evil", "gemini?key=x" }) |model| {
        try std.testing.expectError(error.InvalidModel, streamFn(undefined, std.testing.allocator, std.testing.io, .{
            .model = model,
            .base_url = "http://127.0.0.1:1",
            .api_key = "k",
            .system = "",
            .messages = &.{},
            .cancel = &cancel,
        }, sink));
    }
}
