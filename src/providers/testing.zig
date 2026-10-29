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

const openai_adapter = @import("openai.zig");
const anthropic_adapter = @import("anthropic.zig");
const provider_mod = @import("provider.zig");
const core_types = @import("../core/types.zig");

const EventKind = enum { content_delta, tool_call, usage, failure, done };

const Collector = struct {
    arena: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    tool_calls: std.ArrayListUnmanaged(core_types.ToolCall) = .empty,
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    failure: ?[]const u8 = null,
    failure_kind: ?core_types.ProviderFailureKind = null,
    retry_after_s: ?u32 = null,
    done: bool = false,

    fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const kind: EventKind = switch (ev) {
            .content_delta => .content_delta,
            .tool_call => .tool_call,
            .usage => .usage,
            .failure => .failure,
            .done => .done,
            else => return,
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
            else => {},
        }
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

test "anthropic adapter emits tool call as its block closes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"after\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try anthropic_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expectEqualSlices(EventKind, &.{ .tool_call, .content_delta, .done }, collector.events.items);
    try std.testing.expectEqual(@as(usize, 1), collector.tool_calls.items.len);
    const tc = collector.tool_calls.items[0];
    try std.testing.expectEqualStrings("tu1", tc.id);
    try std.testing.expectEqualStrings("read", tc.name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", tc.arguments_json);
}

test "anthropic adapter emits interleaved tool blocks in index order" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu0\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu1\",\"name\":\"bash\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try anthropic_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expectEqualSlices(EventKind, &.{ .tool_call, .tool_call, .done }, collector.events.items);
    try std.testing.expectEqual(@as(usize, 2), collector.tool_calls.items.len);
    try std.testing.expectEqualStrings("tu0", collector.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", collector.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", collector.tool_calls.items[0].arguments_json);
    try std.testing.expectEqualStrings("tu1", collector.tool_calls.items[1].id);
    try std.testing.expectEqualStrings("bash", collector.tool_calls.items[1].name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", collector.tool_calls.items[1].arguments_json);
}

test "anthropic adapter fallback flush emits a torn tool block once" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"torn\",\"name\":\"write\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":1}\"}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});

    try anthropic_adapter.streamFn(undefined, arena, io, .{
        .model = "test-model",
        .base_url = base,
        .api_key = "test-key",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });

    srv.wait();
    try std.testing.expectEqualSlices(EventKind, &.{ .tool_call, .done }, collector.events.items);
    try std.testing.expectEqual(@as(usize, 1), collector.tool_calls.items.len);
    try std.testing.expectEqualStrings("torn", collector.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("write", collector.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"x\":1}", collector.tool_calls.items[0].arguments_json);
}

test "openai adapter emits each tool call at its close" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"x\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"c2\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"marker\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n";
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
    try std.testing.expectEqualSlices(EventKind, &.{ .tool_call, .content_delta, .tool_call, .done }, collector.events.items);
    try std.testing.expectEqual(@as(usize, 2), collector.tool_calls.items.len);
    try std.testing.expectEqualStrings("c1", collector.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("read", collector.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", collector.tool_calls.items[0].arguments_json);
    try std.testing.expectEqualStrings("c2", collector.tool_calls.items[1].id);
    try std.testing.expectEqualStrings("bash", collector.tool_calls.items[1].name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", collector.tool_calls.items[1].arguments_json);
}
