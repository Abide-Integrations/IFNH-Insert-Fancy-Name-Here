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
        const self = try arena.create(FakeServer);
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var srv = try addr.listen(io, .{ .reuse_address = true });
        const port = srv.socket.address.getPort();

        const head = try std.fmt.allocPrint(arena, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n", .{body.len});
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
const provider_mod = @import("provider.zig");
const core_types = @import("../core/types.zig");

const Collector = struct {
    arena: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    tool_calls: std.ArrayListUnmanaged(core_types.ToolCall) = .empty,
    failure: ?[]const u8 = null,
    done: bool = false,

    fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .content_delta => |d| self.text.appendSlice(self.arena, d) catch {},
            .tool_call => |tc| {
                self.tool_calls.append(self.arena, tc) catch {};
            },
            .failure => |f| self.failure = f.message,
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
