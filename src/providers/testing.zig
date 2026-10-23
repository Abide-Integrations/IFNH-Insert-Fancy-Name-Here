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
    usage: core_types.Usage = .{},

    fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .content_delta => |d| self.text.appendSlice(self.arena, d) catch {},
            .tool_call => |tc| {
                self.tool_calls.append(self.arena, tc) catch {};
            },
            .usage => |u| {
                self.usage.input_tokens += u.input_tokens;
                self.usage.output_tokens += u.output_tokens;
                self.usage.cache_read_tokens += u.cache_read_tokens;
                self.usage.cache_write_tokens += u.cache_write_tokens;
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

// ------------------------------------------------- B-02 shared client

const anthropic_adapter = @import("anthropic.zig");

fn sharedClientIsReused(comptime adapter: anytype, comptime request: anytype) !void {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One session client, two requests against two servers: the adapter must
    // take the supplied client (never own or close it) and must hand the
    // connection back to the pool so shutdown can deinit it safely.
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    var cancel = std.atomic.Value(bool).init(false);

    for (0..2) |_| {
        const srv = try FakeServer.start(io, arena, request.body);
        defer srv.stop();
        var collector = Collector{ .arena = arena };
        const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
        try adapter.streamFn(undefined, arena, io, .{
            .model = "test-model",
            .base_url = base,
            .api_key = "test-key-1234567890",
            .system = "",
            .messages = &.{},
            .cancel = &cancel,
            .client = &client,
        }, .{ .ctx = &collector, .emit_fn = Collector.emit });
        srv.wait();
        try std.testing.expect(collector.done);
        // No live request left behind: deinit would assert otherwise.
        try std.testing.expect(client.connection_pool.used.first == null);
    }
    client.deinit();
}

test "openai adapter uses the session client and leaves the pool clean (B-02)" {
    try sharedClientIsReused(openai_adapter, .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" ++ "data: [DONE]\n\n" });
}

test "anthropic adapter uses the session client and leaves the pool clean (B-02)" {
    try sharedClientIsReused(anthropic_adapter, .{ .body = "event: content_block_delta\n" ++ "data: {\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++ "event: message_stop\n" ++ "data: {}\n\n" });
}

// ------------------------------------------------ B-03 prompt caching

const instructions_mod = @import("../core/instructions.zig");

const golden = struct {
    /// Two turns of the same session that differ only in their focus dirs.
    const Turns = struct {
        first: instructions_mod.Assembled,
        second: instructions_mod.Assembled,
    };

    fn assembleTurns(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) !Turns {
        try dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });
        for ([_]struct { path: []const u8, body: []const u8 }{
            .{ .path = "src/AGENTS.md", .body = "src rules" },
            .{ .path = "docs/AGENTS.md", .body = "docs rules" },
        }) |f| {
            if (std.fs.path.dirname(f.path)) |d| try dir.createDirPath(io, d);
            try dir.writeFile(io, .{ .sub_path = f.path, .data = f.body });
        }
        return .{
            .first = try instructions_mod.assemble(dir, io, arena, "builtin prompt", &.{"src"}),
            .second = try instructions_mod.assemble(dir, io, arena, "builtin prompt", &.{"docs"}),
        };
    }

    /// OpenAI carries the system prompt as messages[0] with role "system".
    fn systemMessageOf(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        const msgs = v.object.get("messages") orelse return error.NoMessages;
        const first = msgs.array.items[0];
        try std.testing.expectEqualStrings("system", first.object.get("role").?.string);
        return first.object.get("content").?.string;
    }

    fn systemOf(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        const sys = v.object.get("system") orelse return error.NoSystem;
        switch (sys) {
            .string => |s| return s,
            .array => |a| {
                // Concatenation of the text blocks is the full system prompt.
                var out: std.ArrayListUnmanaged(u8) = .empty;
                for (a.items) |block| {
                    const t = block.object.get("text") orelse return error.NoText;
                    try out.appendSlice(arena, t.string);
                }
                return out.items;
            },
            else => return error.NoSystem,
        }
    }
};

test "openai body keeps the stable system prefix across turns (B-03)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turns = try golden.assembleTurns(tmp.dir, io, arena);
    var cancel = std.atomic.Value(bool).init(false);
    const base: provider_mod.ModelRequest = .{
        .model = "gpt-test",
        .base_url = "http://127.0.0.1:1",
        .api_key = "k",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    };

    var a = base;
    a.system = turns.first.text;
    a.system_stable_len = turns.first.stable_len;
    var b = base;
    b.system = turns.second.text;
    b.system_stable_len = turns.second.stable_len;

    const sa = try golden.systemMessageOf(arena, try openai_adapter.buildBody(arena, a));
    const sb = try golden.systemMessageOf(arena, try openai_adapter.buildBody(arena, b));

    // Same bytes up to the breakpoint; the tails differ (src vs docs rules).
    try std.testing.expectEqual(turns.first.stable_len, turns.second.stable_len);
    try std.testing.expectEqualStrings(sa[0..turns.first.stable_len], sb[0..turns.second.stable_len]);
    try std.testing.expect(!std.mem.eql(u8, sa, sb));
    try std.testing.expect(std.mem.indexOf(u8, sa[turns.first.stable_len..], "src rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, sb[turns.second.stable_len..], "docs rules") != null);
}

test "anthropic body caches the stable block and leaves the tail volatile (B-03)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turns = try golden.assembleTurns(tmp.dir, io, arena);
    var cancel = std.atomic.Value(bool).init(false);
    const base: provider_mod.ModelRequest = .{
        .model = "claude-test",
        .base_url = "http://127.0.0.1:1",
        .api_key = "k",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    };

    var a = base;
    a.system = turns.first.text;
    a.system_stable_len = turns.first.stable_len;
    var b = base;
    b.system = turns.second.text;
    b.system_stable_len = turns.second.stable_len;
    const body_a = try anthropic_adapter.buildBody(arena, a);
    const body_b = try anthropic_adapter.buildBody(arena, b);

    const va = try std.json.parseFromSliceLeaky(std.json.Value, arena, body_a, .{});
    const vb = try std.json.parseFromSliceLeaky(std.json.Value, arena, body_b, .{});
    const sys_a = va.object.get("system").?;
    const sys_b = vb.object.get("system").?;
    try std.testing.expect(sys_a == .array and sys_b == .array);

    const stable_a = sys_a.array.items[0];
    const stable_b = sys_b.array.items[0];
    // The cached block is byte-identical and marked ephemeral.
    try std.testing.expectEqualStrings(
        stable_a.object.get("text").?.string,
        stable_b.object.get("text").?.string,
    );
    const cc = stable_a.object.get("cache_control").?;
    try std.testing.expectEqualStrings("ephemeral", cc.object.get("type").?.string);
    try std.testing.expect(stable_b.object.get("cache_control") != null);

    // The volatile tail follows the breakpoint and differs between turns.
    const tail_a = sys_a.array.items[1].object.get("text").?.string;
    const tail_b = sys_b.array.items[1].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, tail_a, "src rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_b, "docs rules") != null);

    // Concatenated blocks are still the full prompt, unchanged.
    try std.testing.expectEqualStrings(turns.first.text, try golden.systemOf(arena, body_a));
    try std.testing.expectEqualStrings(turns.second.text, try golden.systemOf(arena, body_b));
}

test "anthropic usage carries cache read/write tokens (B-03)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":900,\"cache_creation_input_tokens\":40}}}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n" ++
        "event: message_stop\ndata: {}\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    try anthropic_adapter.streamFn(undefined, arena, io, .{
        .model = "claude-test",
        .base_url = base,
        .api_key = "k",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });
    srv.wait();
    try std.testing.expectEqual(@as(u64, 900), collector.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 40), collector.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 12), collector.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), collector.usage.output_tokens);
}

test "openai usage carries cached prompt tokens (B-03)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1000,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":896}}}\n\n" ++
        "data: [DONE]\n\n";
    const srv = try FakeServer.start(io, arena, body);
    defer srv.stop();

    var cancel = std.atomic.Value(bool).init(false);
    var collector = Collector{ .arena = arena };
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{srv.port});
    try openai_adapter.streamFn(undefined, arena, io, .{
        .model = "gpt-test",
        .base_url = base,
        .api_key = "k",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = Collector.emit });
    srv.wait();
    try std.testing.expectEqual(@as(u64, 896), collector.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 1000), collector.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), collector.usage.cache_write_tokens);
}
