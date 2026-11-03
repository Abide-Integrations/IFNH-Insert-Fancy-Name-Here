//! In-process fake HTTP server for provider adapter tests (DESIGN §8,
//! DECISIONS U286, M0-T21). Listens on an ephemeral localhost port, drains
//! one request, replies with a canned response, and closes. Runs the
//! socket work on a dedicated thread so tests stay synchronous.

const std = @import("std");

pub const FakeServer = struct {
    thread: ?std.Thread = null,
    server: std.Io.net.Server,
    io: std.Io,
    response: []const u8,
    port: u16,
    done: std.atomic.Value(bool) = .init(false),

    /// Start the server with `body` as the HTTP response payload.
    /// `status_line`/`headers` default to a 200 text/event-stream.
    pub fn start(
        io: std.Io,
        arena: std.mem.Allocator,
        body: []const u8,
    ) !*FakeServer {
        return startWith(io, arena, "200 OK", "Content-Type: text/event-stream\r\n", body);
    }

    /// Start with a custom status line and extra headers (each ending in
    /// `\r\n`). Used to exercise provider error paths.
    pub fn startWith(
        io: std.Io,
        arena: std.mem.Allocator,
        status_line: []const u8,
        extra_headers: []const u8,
        body: []const u8,
    ) !*FakeServer {
        const self = try arena.create(FakeServer);
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(io, .{ .reuse_address = true });
        const port = srv.socket.address.getPort();

        const head = try std.fmt.allocPrint(arena, "HTTP/1.1 {s}\r\n{s}" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n", .{ status_line, extra_headers, body.len });
        const full = try std.mem.concat(arena, u8, &.{ head, body });

        self.* = .{
            .server = srv,
            .io = io,
            .response = full,
            .port = port,
        };
        self.thread = try std.Thread.spawn(.{}, main, .{self});
        return self;
    }

    fn main(self: *FakeServer) void {
        const conn = self.server.accept(self.io) catch return;
        defer {
            conn.socket.close(self.io);
            self.done.store(true, .release);
        }

        // Drain the request head (and body if Content-Length is present).
        var rbuf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        var head_end: usize = 0;
        var seen: [4]u8 = .{ 0, 0, 0, 0 };
        var content_length: usize = 0;
        var head_accum: [8192]u8 = undefined;
        var head_len: usize = 0;

        drain: while (true) {
            const b = r.interface.takeByte() catch break;
            if (head_len < head_accum.len) {
                head_accum[head_len] = b;
                head_len += 1;
            }
            seen[0] = seen[1];
            seen[1] = seen[2];
            seen[2] = seen[3];
            seen[3] = b;
            if (std.mem.eql(u8, &seen, "\r\n\r\n")) {
                head_end = head_len;
                break :drain;
            }
        }
        if (head_end > 0) {
            if (std.ascii.indexOfIgnoreCase(head_accum[0..head_end], "content-length:")) |pos| {
                const rest = head_accum[pos + "content-length:".len .. head_end];
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len], " \t"), 10) catch 0;
            }
        }
        var remaining = content_length;
        while (remaining > 0) {
            const b = r.interface.takeByte() catch break;
            remaining -|= 1;
            _ = b;
        }

        // Send the canned response and close.
        var wbuf: [8192]u8 = undefined;
        var w = conn.writer(self.io, &wbuf);
        w.interface.writeAll(self.response) catch {};
        w.interface.flush() catch {};
    }

    pub fn wait(self: *FakeServer) void {
        while (!self.done.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn stop(self: *FakeServer) void {
        self.server.deinit(self.io);
    }
};

// ---------------------------------------------------------------- tests

const anthropic_adapter = @import("anthropic.zig");
const openai_adapter = @import("openai.zig");
const provider_mod = @import("provider.zig");
const core_types = @import("../core/types.zig");

/// Event kinds in arrival order, so tests can prove *when* a `tool_call`
/// was emitted rather than only that it eventually was.
pub const EventKind = enum { content_delta, reasoning_delta, reasoning_block, tool_call, usage, done, failure };

pub const Collector = struct {
    arena: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    reasoning_block: ?core_types.ReasoningBlock = null,
    tool_calls: std.ArrayListUnmanaged(core_types.ToolCall) = .empty,
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    failure: ?[]const u8 = null,
    failure_kind: ?core_types.ProviderFailureKind = null,
    retry_after_s: ?u32 = null,
    usage: ?core_types.Usage = null,
    done: bool = false,

    fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const kind: EventKind = switch (ev) {
            .content_delta => .content_delta,
            .reasoning_delta => .reasoning_delta,
            .reasoning_block => .reasoning_block,
            .tool_call => .tool_call,
            .usage => .usage,
            .done => .done,
            .failure => .failure,
        };
        self.events.append(self.arena, kind) catch {};
        switch (ev) {
            .content_delta => |d| self.text.appendSlice(self.arena, d) catch {},
            .tool_call => |tc| {
                self.tool_calls.append(self.arena, tc) catch {};
            },
            .failure => |f| {
                self.failure = f.message;
                self.failure_kind = f.kind;
                self.retry_after_s = f.retry_after_s;
            },
            .done => self.done = true,
            .usage => |u| self.usage = u,
            .reasoning_delta => |d| self.reasoning.appendSlice(self.arena, d) catch {},
            .reasoning_block => |b| self.reasoning_block = .{
                .text = self.arena.dupe(u8, b.text) catch "",
                .signature = self.arena.dupe(u8, b.signature) catch "",
                .redacted = b.redacted,
            },
        }
    }

    pub fn firstIndexOf(self: *const Collector, kind: EventKind) ?usize {
        return std.mem.indexOfScalar(EventKind, self.events.items, kind);
    }

    pub fn lastIndexOf(self: *const Collector, kind: EventKind) ?usize {
        return std.mem.lastIndexOfScalar(EventKind, self.events.items, kind);
    }
};

test "openai adapter streams against fake HTTP server" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try openai_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key-1234567890",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expect(collector.done);
    try std.testing.expectEqualStrings("hello world", collector.text.items);
    try std.testing.expect(collector.failure == null);
}

fn runOpenAiOnce(
    io: std.Io,
    arena: std.mem.Allocator,
    client: ?*std.http.Client,
    srv: *FakeServer,
    base: []const u8,
) !Collector {
    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    try openai_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key-1234567890",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
        .client = client,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });
    srv.wait();
    return collector;
}

test "supplied HTTP client is reused across rounds; null falls back" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    // Two rounds through one supplied client.
    const srv1 = try FakeServer.start(io, arena, body);
    defer srv1.stop();
    const base1 = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv1.port});
    const c1 = try runOpenAiOnce(io, arena, &client, srv1, base1);
    try std.testing.expect(c1.done);

    const srv2 = try FakeServer.start(io, arena, body);
    defer srv2.stop();
    const base2 = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv2.port});
    const c2 = try runOpenAiOnce(io, arena, &client, srv2, base2);
    try std.testing.expect(c2.done);

    // A null client takes the per-request fallback path.
    const srv3 = try FakeServer.start(io, arena, body);
    defer srv3.stop();
    const base3 = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv3.port});
    const c3 = try runOpenAiOnce(io, arena, null, srv3, base3);
    try std.testing.expect(c3.done);
}

test "openai adapter reports rate limit and Retry-After" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const srv = try FakeServer.startWith(
        io,
        arena,
        "429 Too Many Requests",
        "Content-Type: application/json\r\nRetry-After: 7\r\n",
        "{\"error\":{\"message\":\"slow down\"}}",
    );
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try openai_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key-1234567890",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expect(!collector.done);
    try std.testing.expectEqualStrings("slow down", collector.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.rate_limited, collector.failure_kind.?);
    try std.testing.expectEqual(@as(?u32, 7), collector.retry_after_s);
}

test "openai adapter accumulates tool calls from stream" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"x\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try openai_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expectEqual(@as(usize, 1), collector.tool_calls.items.len);
    const tc = collector.tool_calls.items[0];
    try std.testing.expectEqualStrings("c1", tc.id);
    try std.testing.expectEqualStrings("read", tc.name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", tc.arguments_json);
}

/// Serve `body` as raw SSE bytes and run one adapter round against it.
pub fn streamFixture(
    io: std.Io,
    arena: std.mem.Allocator,
    comptime adapter: type,
    body: []const u8,
) !Collector {
    return streamFixtureWith(io, arena, adapter, "200 OK", "Content-Type: text/event-stream\r\n", body);
}

/// `streamFixture` with a custom status line and headers (error paths).
pub fn streamFixtureWith(
    io: std.Io,
    arena: std.mem.Allocator,
    comptime adapter: type,
    status_line: []const u8,
    extra_headers: []const u8,
    body: []const u8,
) !Collector {
    const srv = try FakeServer.startWith(io, arena, status_line, extra_headers, body);
    defer srv.stop();
    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    try adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key-1234567890",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });
    srv.wait();
    return collector;
}

test "wire sse openai fixture: text, two interleaved tool calls, usage, DONE" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Raw Chat Completions stream: role-only first chunk, a keep-alive
    // comment, a text split across chunks, two tool calls whose arguments
    // arrive in fragments, a finish chunk and a trailing usage chunk.
    const body =
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
        ": keep-alive\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Let me \"}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"look.\"}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"a.txt\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"pattern\\\":\\\"x\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":30,\"total_tokens\":150,\"prompt_tokens_details\":{\"cached_tokens\":100}}}\n\n" ++
        "data: [DONE]\n\n";

    const c = try streamFixture(std.testing.io, arena, openai_adapter, body);
    try std.testing.expect(c.failure == null);
    try std.testing.expect(c.done);
    try std.testing.expectEqualStrings("Let me look.", c.text.items);

    try std.testing.expectEqual(@as(usize, 2), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("call_a", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", c.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", c.tool_calls.items[0].arguments_json);
    try std.testing.expectEqualStrings("call_b", c.tool_calls.items[1].id);
    try std.testing.expectEqualStrings("grep", c.tool_calls.items[1].name);
    try std.testing.expectEqualStrings("{\"pattern\":\"x\"}", c.tool_calls.items[1].arguments_json);

    const u = c.usage.?;
    try std.testing.expectEqual(@as(u64, 120), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 30), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), u.cache_read_tokens);

    // Order: text first, tool calls after it, `done` last.
    try std.testing.expect(c.lastIndexOf(.content_delta).? < c.firstIndexOf(.tool_call).?);
    try std.testing.expectEqual(EventKind.done, c.events.items[c.events.items.len - 1]);
}

test "wire sse openai fixture: an error event ends the stream with a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"par\"}}]}\n\n" ++
        "data: {\"error\":{\"message\":\"context length exceeded\"}}\n\n";
    const c = try streamFixture(std.testing.io, arena, openai_adapter, body);
    try std.testing.expect(!c.done);
    try std.testing.expectEqualStrings("par", c.text.items);
    try std.testing.expectEqualStrings("context length exceeded", c.failure.?);
    try std.testing.expectEqual(core_types.ProviderFailureKind.invalid_request, c.failure_kind.?);
}

test "wire sse anthropic fixture: text block, tool_use block, usage, message_stop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Raw Messages stream with `event:` lines, a ping, a text block, a
    // tool_use block whose input arrives as partial JSON, and the closing
    // message_delta / message_stop pair.
    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":25,\"cache_read_input_tokens\":10,\"cache_creation_input_tokens\":5,\"output_tokens\":1}}}\n\n" ++
        "event: ping\n" ++
        "data: {\"type\":\"ping\"}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Checking \"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"the file.\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"a.txt\\\"}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const c = try streamFixture(std.testing.io, arena, anthropic_adapter, body);
    try std.testing.expect(c.failure == null);
    try std.testing.expect(c.done);
    try std.testing.expectEqualStrings("Checking the file.", c.text.items);

    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("toolu_1", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", c.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", c.tool_calls.items[0].arguments_json);

    const u = c.usage.?;
    try std.testing.expectEqual(@as(u64, 25), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 42), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 10), u.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 5), u.cache_write_tokens);

    try std.testing.expect(c.lastIndexOf(.content_delta).? < c.firstIndexOf(.tool_call).?);
    try std.testing.expect(c.firstIndexOf(.tool_call).? < c.firstIndexOf(.usage).?);
    try std.testing.expectEqual(EventKind.done, c.events.items[c.events.items.len - 1]);
}

test "wire sse anthropic fixture: a torn tool_use block is still flushed once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No content_block_stop and no message_stop: the stream just ends.
    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"ls\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n";
    const c = try streamFixture(std.testing.io, arena, anthropic_adapter, body);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("toolu_9", c.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("{}", c.tool_calls.items[0].arguments_json);
    try std.testing.expect(c.done);
}

test "wire sse anthropic fixture: thinking deltas, signature, then a tool_use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":9}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me \"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"think.\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"SIG\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"NATURE\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"OPAQUE\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const c = try streamFixture(std.testing.io, arena, anthropic_adapter, body);
    try std.testing.expect(c.failure == null);
    try std.testing.expectEqualStrings("Let me think.", c.reasoning.items);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(EventKind, c.events.items, &.{.reasoning_delta}));
    // The last block seen is the redacted one; the signed block came first.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(EventKind, c.events.items, &.{.reasoning_block}));
    try std.testing.expectEqualStrings("OPAQUE", c.reasoning_block.?.signature);
    try std.testing.expect(c.reasoning_block.?.redacted);
    try std.testing.expectEqual(@as(usize, 1), c.tool_calls.items.len);
    try std.testing.expectEqualStrings("toolu_1", c.tool_calls.items[0].id);
    try std.testing.expect(c.lastIndexOf(.reasoning_block).? < c.firstIndexOf(.tool_call).?);
    try std.testing.expect(c.done);
}

test "wire sse anthropic fixture: a signed thinking block is delivered whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hm\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"SIGNATURE\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const c = try streamFixture(std.testing.io, arena, anthropic_adapter, body);
    try std.testing.expectEqualStrings("hm", c.reasoning_block.?.text);
    try std.testing.expectEqualStrings("SIGNATURE", c.reasoning_block.?.signature);
    try std.testing.expect(!c.reasoning_block.?.redacted);
}
