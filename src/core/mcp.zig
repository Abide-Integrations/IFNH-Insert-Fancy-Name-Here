//! MCP client: stdio transport, JSON-RPC framing, server registry
//! (M1-T05, DECISIONS section J).
//!
//! Scope: stdio servers spawned lazily on first use (J138), one request in
//! flight at a time, tools surfaced through the `mcp_list` and `mcp_call`
//! tools. Remote HTTP servers and OAuth are follow-ups (J135/J140). All
//! MCP tool calls pass the permission engine (J141, default ask).

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const protocol_version = "2024-11-05";
pub const max_frame_bytes: usize = 1024 * 1024;

pub const McpTool = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema_json: []const u8 = "{}",
};

pub const CallResult = struct {
    text: []const u8,
    is_error: bool,
};

/// One spawned stdio MCP server. Sequential request/response only.
pub const Client = struct {
    io: std.Io,
    alloc: std.mem.Allocator, // registry-lifetime arena contract
    name: []const u8,
    child: ?std.process.Child = null,
    next_id: u64 = 1,
    out_buf: [64 * 1024]u8 = undefined,
    in_buf: [64 * 1024]u8 = undefined,
    out_file_writer: ?std.Io.File.Writer = null,
    in_file_reader: ?std.Io.File.Reader = null,

    pub const InitError = error{ SpawnFailed, OutOfMemory };

    /// Spawn the server process (lazy; called on first use, J138).
    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        extra_env: []const [2][]const u8,
    ) InitError!Client {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, command);
        for (args) |a| try argv.append(alloc, a);

        // Filtered environment: minimal + caller-provided extras (J140).
        var env = try alloc.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(alloc);
        try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try env.put("HOME", "/tmp");
        for (extra_env) |kv| try env.put(kv[0], kv[1]);

        const child = std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;

        return .{ .io = io, .alloc = alloc, .name = name, .child = child };
    }

    fn writer(self: *Client) !*std.Io.Writer {
        if (self.out_file_writer == null) {
            const f = self.child.?.stdin orelse return error.SpawnFailed;
            self.out_file_writer = f.writer(self.io, &self.out_buf);
        }
        return &self.out_file_writer.?.interface;
    }

    fn reader(self: *Client) !*std.Io.Reader {
        if (self.in_file_reader == null) {
            const f = self.child.?.stdout orelse return error.SpawnFailed;
            self.in_file_reader = f.reader(self.io, &self.in_buf);
        }
        return &self.in_file_reader.?.interface;
    }

    /// Send a JSON-RPC request and wait for the matching response line.
    fn request(self: *Client, arena: std.mem.Allocator, method: []const u8, params_json: []const u8) !std.json.Value {
        const w = try self.writer();
        const id = self.next_id;
        self.next_id += 1;
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try w.print("{d}", .{id});
        try w.writeAll(",\"method\":");
        try std.json.Stringify.value(method, .{}, w);
        try w.writeAll(",\"params\":");
        try w.writeAll(params_json);
        try w.writeAll("}\n");
        try w.flush();

        const r = try self.reader();
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            const line_raw = r.takeDelimiterInclusive('\n') catch return error.ServerClosed;
            var line = line_raw;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
            if (line.len > max_frame_bytes) return error.FrameTooLarge;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
            if (v != .object) continue;
            const id_v = v.object.get("id") orelse continue; // notification
            if (id_v != .integer or @as(u64, @intCast(id_v.integer)) != id) continue;
            return v;
        }
        return error.NoResponse;
    }

    pub fn initialize(self: *Client, arena: std.mem.Allocator) !void {
        const params = try std.fmt.allocPrint(arena, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"ifnh\",\"version\":\"0.0.1\"}}}}", .{protocol_version});
        const resp = try self.request(arena, "initialize", params);
        if (resp.object.get("error") != null) return error.ServerRejected;
        // initialized notification (no response expected).
        const w = try self.writer();
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
        try w.flush();
    }

    pub fn listTools(self: *Client, arena: std.mem.Allocator) ![]McpTool {
        const resp = try self.request(arena, "tools/list", "{}");
        const result = resp.object.get("result") orelse return error.ServerRejected;
        if (result != .object) return error.ServerRejected;
        const tools_v = result.object.get("tools") orelse return &.{};
        if (tools_v != .array) return &.{};

        var out: std.ArrayListUnmanaged(McpTool) = .empty;
        for (tools_v.array.items) |item| {
            if (item != .object) continue;
            const name_v = item.object.get("name") orelse continue;
            if (name_v != .string) continue;
            var desc: []const u8 = "";
            if (item.object.get("description")) |d| {
                if (d == .string) desc = try arena.dupe(u8, d.string);
            }
            var schema: []const u8 = "{}";
            if (item.object.get("inputSchema")) |s| {
                var aw: std.Io.Writer.Allocating = .init(arena);
                std.json.Stringify.value(s, .{}, &aw.writer) catch {};
                schema = aw.written();
            }
            try out.append(arena, .{
                .name = try arena.dupe(u8, name_v.string),
                .description = desc,
                .input_schema_json = schema,
            });
        }
        return out.items;
    }

    pub fn callTool(self: *Client, arena: std.mem.Allocator, tool: []const u8, arguments_json: []const u8) !CallResult {
        var params_stream: std.Io.Writer.Allocating = .init(arena);
        try params_stream.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool, .{}, &params_stream.writer);
        try params_stream.writer.writeAll(",\"arguments\":");
        try params_stream.writer.writeAll(if (arguments_json.len > 0) arguments_json else "{}");
        try params_stream.writer.writeAll("}");
        const params = params_stream.written();
        const resp = try self.request(arena, "tools/call", params);
        if (resp.object.get("error")) |e| {
            const msg = if (e == .object) blk: {
                if (e.object.get("message")) |m| {
                    if (m == .string) break :blk m.string;
                }
                break :blk "mcp error";
            } else "mcp error";
            return .{ .text = msg, .is_error = true };
        }
        const result = resp.object.get("result") orelse return error.ServerRejected;
        if (result != .object) return error.ServerRejected;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        var is_error = false;
        if (result.object.get("isError")) |ie| {
            if (ie == .bool and ie.bool) is_error = true;
        }
        if (result.object.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |item| {
                    if (item != .object) continue;
                    if (item.object.get("text")) |t| {
                        if (t == .string) {
                            if (text.items.len > 0) text.append(arena, '\n') catch {};
                            text.appendSlice(arena, t.string) catch {};
                        }
                    }
                }
            }
        }
        return .{ .text = text.items, .is_error = is_error };
    }

    pub fn deinit(self: *Client) void {
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
    }
};

// ---------------------------------------------------------------- registry

pub const ServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8,
    required: bool = false,
};

pub const ServerTool = struct {
    server: []const u8,
    tool: McpTool,
};

pub const Registry = struct {
    io: std.Io,
    alloc: std.mem.Allocator, // registry-lifetime arena
    configs: []ServerConfig,
    clients: std.ArrayListUnmanaged(*Client) = .empty,

    /// Parse `mcp_servers` from a config store (std.json.Value object:
    /// name -> {command, args?, env?, required?}).
    pub fn fromConfig(arena: std.mem.Allocator, v: ?std.json.Value) !Registry {
        var configs: std.ArrayListUnmanaged(ServerConfig) = .empty;
        if (v) |val| {
            if (val == .object) {
                var it = val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    const o = entry.value_ptr.object;
                    const cmd_v = o.get("command") orelse continue;
                    if (cmd_v != .string) continue;
                    var args: std.ArrayListUnmanaged([]const u8) = .empty;
                    if (o.get("args")) |a| {
                        if (a == .array) {
                            for (a.array.items) |item| {
                                if (item == .string) try args.append(arena, item.string);
                            }
                        }
                    }
                    var env: std.ArrayListUnmanaged([2][]const u8) = .empty;
                    if (o.get("env")) |e| {
                        if (e == .object) {
                            var eit = e.object.iterator();
                            while (eit.next()) |kv| {
                                if (kv.value_ptr.* == .string) {
                                    try env.append(arena, .{
                                        try arena.dupe(u8, kv.key_ptr.*),
                                        try arena.dupe(u8, kv.value_ptr.string),
                                    });
                                }
                            }
                        }
                    }
                    try configs.append(arena, .{
                        .name = try arena.dupe(u8, entry.key_ptr.*),
                        .command = try arena.dupe(u8, cmd_v.string),
                        .args = args.items,
                        .env = env.items,
                        .required = if (o.get("required")) |r| (r == .bool and r.bool) else false,
                    });
                }
            }
        }
        return .{ .io = undefined, .alloc = arena, .configs = configs.items };
    }

    pub fn init(io: std.Io, arena: std.mem.Allocator, v: ?std.json.Value) !Registry {
        var self = try fromConfig(arena, v);
        self.io = io;
        return self;
    }

    fn clientFor(self: *Registry, server: []const u8) !*Client {
        for (self.clients.items) |c| {
            if (std.mem.eql(u8, c.name, server)) return c;
        }
        // Lazy spawn (J138).
        for (self.configs) |cfg| {
            if (!std.mem.eql(u8, cfg.name, server)) continue;
            const c = try self.alloc.create(Client);
            c.* = try Client.init(self.io, self.alloc, cfg.name, cfg.command, cfg.args, cfg.env);
            c.initialize(self.alloc) catch {
                c.deinit();
                return error.ServerRejected;
            };
            try self.clients.append(self.alloc, c);
            return c;
        }
        return error.UnknownServer;
    }

    /// All tools across all configured servers (best-effort; failures skip).
    pub fn allTools(self: *Registry, arena: std.mem.Allocator) []ServerTool {
        var out: std.ArrayListUnmanaged(ServerTool) = .empty;
        for (self.configs) |cfg| {
            const c = self.clientFor(cfg.name) catch continue;
            const tools = c.listTools(arena) catch continue;
            for (tools) |t| {
                out.append(arena, .{ .server = cfg.name, .tool = t }) catch {};
            }
        }
        return out.items;
    }

    pub fn call(self: *Registry, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) !CallResult {
        const c = try self.clientFor(server);
        return c.callTool(arena, tool, arguments_json);
    }

    pub fn deinit(self: *Registry) void {
        for (self.clients.items) |c| c.deinit();
        self.clients.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------- tests

fn writeFakeServer(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const script =
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"id":1'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake"}}}' ;;
        \\    *'"id":2'*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo back","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"id":3'*) echo '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"echoed-ok"}]}}' ;;
        \\    *) echo '{"jsonrpc":"2.0","id":99,"error":{"code":-32601,"message":"method not found"}}' ;;
        \\  esac
        \\done
        \\
    ;
    try dir.writeFile(io, .{ .sub_path = "fake-mcp.sh", .data = script });
    const path = try arena.alloc(u8, 4096);
    const n = try dir.realPathFile(io, "fake-mcp.sh", path);
    // Make executable via shell.
    const chmod = std.process.run(arena, io, .{ .argv = &.{ "chmod", "+x", path[0..n] } }) catch null;
    _ = chmod;
    return path[0..n];
}

test "mcp client: initialize, list tools, call tool" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const script_path = try writeFakeServer(tmp.dir, io, arena);

    var client = try Client.init(io, arena, "fake", script_path, &.{}, &.{});
    defer client.deinit();
    try client.initialize(arena);

    const tools = try client.listTools(arena);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("echo", tools[0].name);

    const res = try client.callTool(arena, "echo", "{}");
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("echoed-ok", res.text);
}

test "registry parses config and dispatches calls" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const script_path = try writeFakeServer(tmp.dir, io, arena);
    const cfg_json = try std.fmt.allocPrint(arena, "{{\"fake\":{{\"command\":\"{s}\",\"args\":[]}}}}", .{script_path});
    const cfg_val = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json, .{});

    var reg = try Registry.init(io, arena, cfg_val);
    defer reg.deinit();

    const tools = reg.allTools(arena);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("fake", tools[0].server);

    const res = try reg.call(arena, "fake", "echo", "{}");
    try std.testing.expectEqualStrings("echoed-ok", res.text);
}
