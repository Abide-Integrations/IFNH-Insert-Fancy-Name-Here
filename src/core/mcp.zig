//! MCP client: stdio and Streamable HTTP transports, JSON-RPC framing,
//! server registry (M1-T05, DECISIONS section J, ACTIVE_PLAN E-03).
//!
//! Scope: stdio servers spawned lazily on first use (J138) and remote
//! Streamable HTTP servers (`url`), one request in flight at a time, tools
//! surfaced through the `mcp_list`, `mcp_describe` and `mcp_call` tools.
//! A server may be limited to some agent identities (`agents`). OAuth is a
//! follow-up (J140). All MCP tool calls pass the permission engine (J141,
//! default ask).

const std = @import("std");
const fsutil = @import("fsutil.zig");
const sse = @import("../providers/sse.zig");
const transport = @import("../providers/transport.zig");

pub const protocol_version = "2024-11-05";
pub const max_frame_bytes: usize = 1024 * 1024;
/// Notifications an HTTP event stream may carry before the response we wait
/// for; a server that never answers cannot hold the call open forever.
const max_skipped_events: usize = 1024;

/// Agent identities a server can be limited to: the top-level agent and the
/// subagent roles (`subagent.Role`).
pub const agent_identities = [_][]const u8{ "parent", "research", "implement", "review" };

pub const McpTool = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema_json: []const u8 = "{}",
};

pub const CallResult = struct {
    text: []const u8,
    is_error: bool,
};

/// Streamable HTTP state of a remote server.
const Http = struct {
    client: std.http.Client,
    uri: std.Uri,
    headers: []const [2][]const u8,
    /// `Mcp-Session-Id` from `initialize`, sent on every later request.
    session_id: ?[]const u8 = null,
    /// `initialize` answered; later requests carry `MCP-Protocol-Version`.
    initialized: bool = false,
};

/// One MCP server connection: a spawned stdio process or a Streamable HTTP
/// endpoint. Sequential request/response only.
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
    http: ?Http = null,
    /// Why the last request failed when the error name alone says too little
    /// (the HTTP status of a rejection); "" otherwise.
    detail: []const u8 = "",

    pub const InitError = error{ SpawnFailed, InvalidUrl, OutOfMemory };

    /// A Streamable HTTP server at `url`. Nothing is sent until `initialize`.
    pub fn initHttp(
        io: std.Io,
        alloc: std.mem.Allocator,
        name: []const u8,
        url: []const u8,
        headers: []const [2][]const u8,
    ) InitError!Client {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        return .{
            .io = io,
            .alloc = alloc,
            .name = name,
            .http = .{ .client = .{ .allocator = alloc, .io = io }, .uri = uri, .headers = headers },
        };
    }

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
        const id = self.next_id;
        self.next_id += 1;
        if (self.http != null) {
            const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, std.json.fmt(method, .{}), params_json });
            return (try self.exchange(arena, body, id)).?;
        }
        const w = try self.writer();
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
        if (self.http) |*h| {
            h.initialized = true;
            _ = try self.exchange(arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", null);
            return;
        }
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

    /// POST one JSON-RPC message. With `want_id` the reply (a JSON body or an
    /// event stream) is read until the object carrying that id; a notification
    /// (`null`) only needs a 2xx status. The server's `Mcp-Session-Id` is kept.
    fn exchange(self: *Client, arena: std.mem.Allocator, body: []const u8, want_id: ?u64) !?std.json.Value {
        const h = &self.http.?;
        var extra = try self.headerList(arena, h);
        try extra.append(arena, .{ .name = "accept", .value = "application/json, text/event-stream" });

        const connection = try transport.openConnection(&h.client, h.uri, transport.default_limits);
        var creq = h.client.request(.POST, h.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                // The reply is read raw, so ask for it unencoded.
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = extra.items,
            .redirect_behavior = .unhandled,
            .connection = connection,
        }) catch |err| {
            h.client.connection_pool.release(connection, self.io);
            return err;
        };
        defer creq.deinit();
        try creq.sendBodyComplete(@constCast(body));

        var redirect_buf: [8192]u8 = undefined;
        var response = try creq.receiveHead(&redirect_buf);
        const status = @intFromEnum(response.head.status);
        if (response.head.status.class() != .success) {
            self.detail = try std.fmt.allocPrint(self.alloc, "HTTP {d}", .{status});
            return error.ServerRejected;
        }
        // Everything borrowed from the head is read before the body reader
        // refills the connection buffer.
        if (h.session_id == null) {
            var it = response.head.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                    h.session_id = try self.alloc.dupe(u8, header.value);
                    break;
                }
            }
        }
        const id = want_id orelse return null;
        const is_sse = if (response.head.content_type) |ct| std.ascii.startsWithIgnoreCase(ct, "text/event-stream") else false;

        var transfer: [16 * 1024]u8 = undefined;
        const r = response.reader(&transfer);
        if (!is_sse) {
            const raw = r.allocRemaining(arena, .limited(max_frame_bytes + 1)) catch return error.ServerClosed;
            if (raw.len > max_frame_bytes) return error.FrameTooLarge;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.NoResponse;
            if (isReplyTo(v, id)) return v;
            return error.NoResponse;
        }
        var parser = sse.Parser{ .reader = r, .max_event_bytes = max_frame_bytes };
        var seen: usize = 0;
        while (seen < max_skipped_events) : (seen += 1) {
            const payload = (parser.next(arena) catch |err| return switch (err) {
                error.StreamTooLong => error.FrameTooLarge,
                else => error.ServerClosed,
            }) orelse return error.NoResponse;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch continue;
            if (isReplyTo(v, id)) return v;
        }
        return error.NoResponse;
    }

    /// Headers every HTTP request carries: the configured ones, the session
    /// and, once `initialize` has answered, the protocol version.
    fn headerList(self: *Client, arena: std.mem.Allocator, h: *const Http) !std.ArrayListUnmanaged(std.http.Header) {
        _ = self;
        var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
        for (h.headers) |kv| try list.append(arena, .{ .name = kv[0], .value = kv[1] });
        if (h.session_id) |sid| try list.append(arena, .{ .name = "mcp-session-id", .value = sid });
        if (h.initialized) try list.append(arena, .{ .name = "mcp-protocol-version", .value = protocol_version });
        return list;
    }

    /// End the server-side session (best effort; every failure is ignored).
    fn closeSession(self: *Client, h: *Http) void {
        if (h.session_id == null) return;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const extra = (self.headerList(arena, h) catch return).items;
        const connection = transport.openConnection(&h.client, h.uri, transport.default_limits) catch return;
        var creq = h.client.request(.DELETE, h.uri, .{
            .extra_headers = extra,
            .redirect_behavior = .unhandled,
            .connection = connection,
        }) catch {
            h.client.connection_pool.release(connection, self.io);
            return;
        };
        defer creq.deinit();
        creq.sendBodiless() catch return;
        var redirect_buf: [8192]u8 = undefined;
        _ = creq.receiveHead(&redirect_buf) catch return;
    }

    pub fn deinit(self: *Client) void {
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
        if (self.http) |*h| {
            self.closeSession(h);
            h.client.deinit();
            self.http = null;
        }
    }
};

/// A JSON-RPC response object carrying `id`; notifications and replies to
/// other requests do not match.
fn isReplyTo(v: std.json.Value, id: u64) bool {
    if (v != .object) return false;
    const id_v = v.object.get("id") orelse return false;
    return id_v == .integer and id_v.integer >= 0 and @as(u64, @intCast(id_v.integer)) == id;
}

// ---------------------------------------------------------------- registry

pub const ServerConfig = struct {
    name: []const u8,
    /// Stdio server: the program to spawn. Empty for an HTTP server.
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    required: bool = false,
    /// Streamable HTTP endpoint; empty for a stdio server.
    url: []const u8 = "",
    /// Extra request headers for an HTTP server.
    headers: []const [2][]const u8 = &.{},
    /// Agent identities this server is limited to; empty means every agent.
    agents: []const []const u8 = &.{},

    /// Whether the agent `identity` may use this server.
    pub fn allows(self: ServerConfig, identity: []const u8) bool {
        if (self.agents.len == 0) return true;
        for (self.agents) |a| {
            if (std.mem.eql(u8, a, identity)) return true;
        }
        return false;
    }
};

pub const ServerTool = struct {
    server: []const u8,
    tool: McpTool,
};

fn stringPairs(arena: std.mem.Allocator, v: ?std.json.Value) ![]const [2][]const u8 {
    var out: std.ArrayListUnmanaged([2][]const u8) = .empty;
    if (v) |val| {
        if (val == .object) {
            var it = val.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .string) {
                    try out.append(arena, .{
                        try arena.dupe(u8, kv.key_ptr.*),
                        try arena.dupe(u8, kv.value_ptr.string),
                    });
                }
            }
        }
    }
    return out.items;
}

fn filterFor(arena: std.mem.Allocator, all: []const ServerConfig, identity: []const u8) ![]ServerConfig {
    var out: std.ArrayListUnmanaged(ServerConfig) = .empty;
    for (all) |c| {
        if (c.allows(identity)) try out.append(arena, c);
    }
    return out.items;
}

pub const Registry = struct {
    io: std.Io,
    alloc: std.mem.Allocator, // registry-lifetime arena
    /// The servers `agent` may use; everything else behaves as unknown.
    configs: []ServerConfig,
    /// Every configured server, for `forAgent` and for telling "denied" from
    /// "unknown".
    all_configs: []ServerConfig = &.{},
    /// Identity of the agent this registry serves: "parent" or a subagent role.
    agent: []const u8 = "parent",
    clients: std.ArrayListUnmanaged(*Client) = .empty,
    /// HTTP status or similar behind the last failed `call`/`clientFor`.
    detail: []const u8 = "",

    /// Parse `mcp_servers` from a config store (std.json.Value object:
    /// name -> {command | url, args?, env?, headers?, agents?, required?}),
    /// keeping the servers `agent` is allowlisted for.
    pub fn fromConfig(arena: std.mem.Allocator, v: ?std.json.Value, agent: []const u8) !Registry {
        var all: std.ArrayListUnmanaged(ServerConfig) = .empty;
        if (v) |val| {
            if (val == .object) {
                var it = val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    const o = entry.value_ptr.object;
                    const cmd_v = o.get("command");
                    const url_v = o.get("url");
                    const is_stdio = cmd_v != null and cmd_v.? == .string;
                    const is_http = url_v != null and url_v.? == .string;
                    if (!is_stdio and !is_http) continue;
                    var args: std.ArrayListUnmanaged([]const u8) = .empty;
                    if (o.get("args")) |a| {
                        if (a == .array) {
                            for (a.array.items) |item| {
                                if (item == .string) try args.append(arena, item.string);
                            }
                        }
                    }
                    var agents: std.ArrayListUnmanaged([]const u8) = .empty;
                    if (o.get("agents")) |a| {
                        if (a == .array) {
                            for (a.array.items) |item| {
                                if (item == .string) try agents.append(arena, try arena.dupe(u8, item.string));
                            }
                        }
                    }
                    try all.append(arena, .{
                        .name = try arena.dupe(u8, entry.key_ptr.*),
                        .command = if (is_stdio) try arena.dupe(u8, cmd_v.?.string) else "",
                        .args = args.items,
                        .env = try stringPairs(arena, o.get("env")),
                        .required = if (o.get("required")) |r| (r == .bool and r.bool) else false,
                        .url = if (!is_stdio) try arena.dupe(u8, url_v.?.string) else "",
                        .headers = if (!is_stdio) try stringPairs(arena, o.get("headers")) else &.{},
                        .agents = agents.items,
                    });
                }
            }
        }
        return .{
            .io = undefined,
            .alloc = arena,
            .configs = try filterFor(arena, all.items, agent),
            .all_configs = all.items,
            .agent = agent,
        };
    }

    pub fn init(io: std.Io, arena: std.mem.Allocator, v: ?std.json.Value, agent: []const u8) !Registry {
        var self = try fromConfig(arena, v, agent);
        self.io = io;
        return self;
    }

    /// A registry for another agent identity over the same server list. It
    /// starts with no live clients, so a child never shares the parent's
    /// spawned processes or HTTP sessions; the caller deinits it.
    pub fn forAgent(self: *const Registry, arena: std.mem.Allocator, name: []const u8) Registry {
        return .{
            .io = self.io,
            .alloc = arena,
            .configs = filterFor(arena, self.all_configs, name) catch &.{},
            .all_configs = self.all_configs,
            .agent = name,
        };
    }

    /// True for a configured server this agent is not allowlisted for.
    pub fn isDenied(self: *const Registry, server: []const u8) bool {
        for (self.configs) |c| {
            if (std.mem.eql(u8, c.name, server)) return false;
        }
        for (self.all_configs) |c| {
            if (std.mem.eql(u8, c.name, server)) return true;
        }
        return false;
    }

    fn clientFor(self: *Registry, server: []const u8) !*Client {
        for (self.clients.items) |c| {
            if (std.mem.eql(u8, c.name, server)) return c;
        }
        // Lazy spawn (J138). Only servers in `configs` are ever started.
        for (self.configs) |cfg| {
            if (!std.mem.eql(u8, cfg.name, server)) continue;
            const c = try self.alloc.create(Client);
            c.* = if (cfg.url.len > 0)
                try Client.initHttp(self.io, self.alloc, cfg.name, cfg.url, cfg.headers)
            else
                try Client.init(self.io, self.alloc, cfg.name, cfg.command, cfg.args, cfg.env);
            c.initialize(self.alloc) catch {
                self.detail = c.detail;
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

    /// One tool's metadata and input schema, on demand (A-08/F-A08).
    pub fn describe(self: *Registry, arena: std.mem.Allocator, server: []const u8, tool: []const u8) !?McpTool {
        const c = try self.clientFor(server);
        const tools = try c.listTools(arena);
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, tool)) return t;
        }
        return null;
    }

    /// `describe` rendered for the model: description and input schema, or an
    /// `error: ...` line (the `mcp_describe` tool reports that prefix as failed).
    pub fn describeText(self: *Registry, arena: std.mem.Allocator, server: []const u8, tool: []const u8) []const u8 {
        const found = self.describe(arena, server, tool) catch
            return std.fmt.allocPrint(arena, "error: server '{s}' unavailable", .{server}) catch "error: server unavailable";
        const t = found orelse
            return std.fmt.allocPrint(arena, "error: unknown tool {s}.{s}", .{ server, tool }) catch "error: unknown tool";
        return std.fmt.allocPrint(arena, "{s}.{s}: {s}\ninput schema: {s}", .{ server, t.name, t.description, t.input_schema_json }) catch "error: oom";
    }

    pub fn call(self: *Registry, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) !CallResult {
        const c = try self.clientFor(server);
        return c.callTool(arena, tool, arguments_json) catch |err| {
            self.detail = c.detail;
            return err;
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.clients.items) |c| c.deinit();
        self.clients.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------- tool hooks
//
// The `mcp_*` tool hooks over a `*Registry` context. The parent run and every
// child agent share them; each passes its own (agent-filtered) registry.

pub fn listHook(ctx: *anyopaque, arena: std.mem.Allocator) []const u8 {
    const reg: *Registry = @ptrCast(@alignCast(ctx));
    if (reg.all_configs.len == 0) return "no MCP servers configured";
    if (reg.configs.len == 0) return std.fmt.allocPrint(arena, "no MCP servers for agent '{s}'", .{reg.agent}) catch "no MCP servers for this agent";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (reg.allTools(arena)) |st| {
        buf.print(arena, "{s}.{s}: {s}\n", .{ st.server, st.tool.name, st.tool.description }) catch {};
    }
    if (buf.items.len == 0) return "no MCP tools available";
    return buf.items;
}

pub fn describeHook(ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8) []const u8 {
    const reg: *Registry = @ptrCast(@alignCast(ctx));
    if (reg.all_configs.len == 0) return "error: no MCP servers configured";
    return reg.describeText(arena, server, tool);
}

pub fn callHook(ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) []const u8 {
    const reg: *Registry = @ptrCast(@alignCast(ctx));
    if (reg.isDenied(server)) {
        return std.fmt.allocPrint(arena, "error: mcp server '{s}' is not enabled for agent '{s}'", .{ server, reg.agent }) catch "error: mcp server is not enabled for this agent";
    }
    const res = reg.call(arena, server, tool, arguments_json) catch |err| {
        if (reg.detail.len > 0) {
            return std.fmt.allocPrint(arena, "error: mcp call failed: {s} ({s})", .{ @errorName(err), reg.detail }) catch "error: mcp call failed";
        }
        return std.fmt.allocPrint(arena, "error: mcp call failed: {s}", .{@errorName(err)}) catch "error: mcp call failed";
    };
    if (res.is_error) {
        return std.fmt.allocPrint(arena, "mcp error: {s}", .{res.text}) catch res.text;
    }
    return res.text;
}

// ---------------------------------------------------------------- tests

fn writeFakeServer(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return writeFakeServerWith(dir, io, arena, "fake-mcp.sh", "");
}

/// The stdio fixture, with `startup` (shell lines) run before it answers: a
/// test can make the script leave a marker proving it was spawned.
pub fn writeFakeServerWith(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, file_name: []const u8, startup: []const u8) ![]const u8 {
    const script = try std.mem.concat(arena, u8, &.{ "#!/bin/sh\n", startup, "\n", fake_server_loop });
    try dir.writeFile(io, .{ .sub_path = file_name, .data = script });
    const path = try arena.alloc(u8, 4096);
    const n = try dir.realPathFile(io, file_name, path);
    // Make executable via shell.
    const chmod = std.process.run(arena, io, .{ .argv = &.{ "chmod", "+x", path[0..n] } }) catch null;
    _ = chmod;
    return path[0..n];
}

const fake_server_loop =
    \\# Answers by JSON-RPC method and echoes the request's own id.
    \\while IFS= read -r line; do
    \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  [ -n "$id" ] || continue
    \\  case "$line" in
    \\    *'"method":"initialize"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\"}}}" ;;
    \\    *'"method":"tools/list"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo back\",\"inputSchema\":{\"type\":\"object\"}}]}}" ;;
    \\    *'"method":"tools/call"'*) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echoed-ok\"}]}}" ;;
    \\    *) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}" ;;
    \\  esac
    \\done
    \\
;

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

    var reg = try Registry.init(io, arena, cfg_val, "parent");
    defer reg.deinit();

    const tools = reg.allTools(arena);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("fake", tools[0].server);

    const res = try reg.call(arena, "fake", "echo", "{}");
    try std.testing.expectEqualStrings("echoed-ok", res.text);

    // On-demand schema lookup (A-08): known tool resolves, unknown is null.
    const described = (try reg.describe(arena, "fake", "echo")).?;
    try std.testing.expectEqualStrings("Echo back", described.description);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", described.input_schema_json);
    try std.testing.expect((try reg.describe(arena, "fake", "nope")) == null);
    try std.testing.expectError(error.UnknownServer, reg.describe(arena, "ghost", "echo"));

    // The text the model sees: description plus the schema as compact JSON.
    try std.testing.expectEqualStrings(
        "fake.echo: Echo back\ninput schema: {\"type\":\"object\"}",
        reg.describeText(arena, "fake", "echo"),
    );
    try std.testing.expectEqualStrings("error: unknown tool fake.nope", reg.describeText(arena, "fake", "nope"));
    try std.testing.expectEqualStrings("error: server 'ghost' unavailable", reg.describeText(arena, "ghost", "echo"));
}

// ------------------------------------------------- Streamable HTTP fixture

/// Local server speaking the Streamable HTTP flavour of MCP: one request per
/// connection, answered by JSON-RPC method (`providers/testing.zig` pattern,
/// but it serves several connections and records what it received).
const HttpFixture = struct {
    thread: ?std.Thread = null,
    server: std.Io.net.Server,
    io: std.Io,
    port: u16,
    /// Connections to serve before the thread exits.
    expected: usize,
    /// Answer `initialize` with a 500.
    reject_initialize: bool,
    arena_state: std.heap.ArenaAllocator,
    /// Lower-cased request head and the body of each request, in order.
    heads: std.ArrayListUnmanaged([]const u8) = .empty,
    bodies: std.ArrayListUnmanaged([]const u8) = .empty,

    fn start(io: std.Io, arena: std.mem.Allocator, expected: usize, reject_initialize: bool) !*HttpFixture {
        const self = try arena.create(HttpFixture);
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const srv = try addr.listen(io, .{ .reuse_address = true });
        self.* = .{
            .server = srv,
            .io = io,
            .port = srv.socket.address.getPort(),
            .expected = expected,
            .reject_initialize = reject_initialize,
            .arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Join the server thread (it exits after `expected` connections). The
    /// recorded requests stay readable until `deinit`.
    fn finish(self: *HttpFixture) void {
        if (self.thread) |t| t.join();
        self.thread = null;
        self.server.deinit(self.io);
    }

    fn deinit(self: *HttpFixture) void {
        self.arena_state.deinit();
    }

    fn url(self: *const HttpFixture, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{self.port});
    }

    fn run(self: *HttpFixture) void {
        var served: usize = 0;
        while (served < self.expected) : (served += 1) {
            const conn = self.server.accept(self.io) catch return;
            defer conn.socket.close(self.io);
            self.serve(conn) catch {};
        }
    }

    fn serve(self: *HttpFixture, conn: std.Io.net.Stream) !void {
        const a = self.arena_state.allocator();
        var rbuf: [4096]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        var head: std.ArrayListUnmanaged(u8) = .empty;
        while (!std.mem.endsWith(u8, head.items, "\r\n\r\n")) try head.append(a, try r.interface.takeByte());
        const lower = try std.ascii.allocLowerString(a, head.items);
        var body_len: usize = 0;
        if (std.mem.indexOf(u8, lower, "content-length:")) |pos| {
            const rest = lower[pos + "content-length:".len ..];
            body_len = std.fmt.parseInt(usize, std.mem.trim(u8, rest[0 .. std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len], " "), 10) catch 0;
        }
        const body = try a.alloc(u8, body_len);
        for (body) |*b| b.* = try r.interface.takeByte();
        try self.heads.append(a, lower);
        try self.bodies.append(a, body);

        const id = idOf(body);
        const reply: []const u8 = blk: {
            if (std.mem.startsWith(u8, lower, "delete ")) break :blk "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            if (std.mem.indexOf(u8, body, "\"method\":\"initialize\"") != null) {
                if (self.reject_initialize) break :blk "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                break :blk try jsonReply(a, "Mcp-Session-Id: sess-42\r\n", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"http-fake\"}}", id);
            }
            if (std.mem.indexOf(u8, body, "\"id\":") == null) break :blk "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            if (std.mem.indexOf(u8, body, "\"method\":\"tools/list\"") != null) {
                // A comment, a notification, then the answer.
                const events = try std.fmt.allocPrint(a, ": keep-alive\n\n" ++
                    "event: message\ndata: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{{\"level\":\"info\"}}}}\n\n" ++
                    "event: message\ndata: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"echo\",\"description\":\"Echo back\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}\n\n", .{id});
                break :blk try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ events.len, events });
            }
            break :blk try jsonReply(a, "", "{\"content\":[{\"type\":\"text\",\"text\":\"http-ok\"}]}", id);
        };
        var wbuf: [4096]u8 = undefined;
        var w = conn.writer(self.io, &wbuf);
        try w.interface.writeAll(reply);
        try w.interface.flush();
    }

    fn jsonReply(a: std.mem.Allocator, extra_headers: []const u8, result: []const u8, id: u64) ![]const u8 {
        const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result });
        return std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ extra_headers, body.len, body });
    }

    fn idOf(body: []const u8) u64 {
        const pos = std.mem.indexOf(u8, body, "\"id\":") orelse return 0;
        const from = pos + "\"id\":".len;
        var end = from;
        while (end < body.len and std.ascii.isDigit(body[end])) end += 1;
        return std.fmt.parseInt(u64, body[from..end], 10) catch 0;
    }
};

test "http client: session id, protocol header, SSE and JSON replies, DELETE on deinit" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // initialize, initialized, tools/list, tools/call, DELETE.
    const fx = try HttpFixture.start(io, arena, 5, false);
    defer fx.deinit();
    const url = try fx.url(arena);
    const headers = [_][2][]const u8{.{ "X-Test", "yes" }};

    var client = try Client.initHttp(io, arena, "remote", url, &headers);
    try client.initialize(arena);
    const tools = try client.listTools(arena);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("echo", tools[0].name);
    const res = try client.callTool(arena, "echo", "{}");
    try std.testing.expect(!res.is_error);
    try std.testing.expectEqualStrings("http-ok", res.text);
    client.deinit();
    fx.finish();

    try std.testing.expectEqual(@as(usize, 5), fx.heads.items.len);
    const h = fx.heads.items;
    // initialize: JSON in, both reply types accepted, our header, no session yet.
    try std.testing.expect(std.mem.startsWith(u8, h[0], "post /mcp "));
    try std.testing.expect(std.mem.indexOf(u8, h[0], "content-type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, h[0], "accept: application/json, text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, h[0], "x-test: yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, h[0], "mcp-session-id") == null);
    try std.testing.expect(std.mem.indexOf(u8, h[0], "mcp-protocol-version") == null);
    // Every later request carries the session and the protocol version.
    for (h[1..4]) |head| {
        try std.testing.expect(std.mem.indexOf(u8, head, "mcp-session-id: sess-42") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "mcp-protocol-version: 2024-11-05") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "x-test: yes") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, fx.bodies.items[1], "notifications/initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, fx.bodies.items[2], "\"method\":\"tools/list\"") != null);
    // Teardown: DELETE with the session id.
    try std.testing.expect(std.mem.startsWith(u8, h[4], "delete /mcp "));
    try std.testing.expect(std.mem.indexOf(u8, h[4], "mcp-session-id: sess-42") != null);
}

test "http client: a non-2xx initialize is ServerRejected naming the status" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fx = try HttpFixture.start(io, arena, 2, true);
    defer fx.deinit();
    const url = try fx.url(arena);

    var client = try Client.initHttp(io, arena, "remote", url, &.{});
    try std.testing.expectError(error.ServerRejected, client.initialize(arena));
    try std.testing.expectEqualStrings("HTTP 500", client.detail);
    client.deinit();

    // Through the registry the same failure surfaces on the registry and in
    // the text the model sees.
    var cfg_json: std.Io.Writer.Allocating = .init(arena);
    try cfg_json.writer.print("{{\"remote\":{{\"url\":\"{s}\"}}}}", .{url});
    const cfg_val = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json.written(), .{});
    var reg = try Registry.init(io, arena, cfg_val, "parent");
    defer reg.deinit();
    const out = callHook(&reg, arena, "remote", "echo", "{}");
    try std.testing.expectEqualStrings("error: mcp call failed: ServerRejected (HTTP 500)", out);
    fx.finish();
}

test "http client: url is read from config with headers and agents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"remote":{"url":"http://h/mcp","headers":{"Authorization":"Bearer t","N":1},"agents":["research"]},"local":{"command":"x"}}
    , .{});
    const reg = try Registry.fromConfig(arena, v, "research");
    try std.testing.expectEqual(@as(usize, 2), reg.configs.len);
    var remote: ServerConfig = undefined;
    for (reg.configs) |c| {
        if (std.mem.eql(u8, c.name, "remote")) remote = c;
    }
    try std.testing.expectEqualStrings("http://h/mcp", remote.url);
    try std.testing.expectEqualStrings("", remote.command);
    try std.testing.expectEqual(@as(usize, 1), remote.headers.len); // the non-string value is dropped
    try std.testing.expectEqualStrings("Authorization", remote.headers[0][0]);
    try std.testing.expectEqualStrings("Bearer t", remote.headers[0][1]);
}

// ------------------------------------------------------- per-agent allowlists

test "allowlists filter servers per agent identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"open":{"command":"a"},"none":{"command":"b","agents":[]},
        \\ "parent_only":{"command":"c","agents":["parent"]},
        \\ "research_only":{"command":"d","agents":["research"]},
        \\ "both":{"command":"e","agents":["parent","review"]}}
    , .{});

    const cases = [_]struct { agent: []const u8, count: usize }{
        .{ .agent = "parent", .count = 4 }, // open, none, parent_only, both
        .{ .agent = "research", .count = 3 }, // open, none, research_only
        .{ .agent = "implement", .count = 2 }, // open, none
        .{ .agent = "review", .count = 3 }, // open, none, both
        .{ .agent = "someday", .count = 2 }, // an unknown identity only gets unrestricted servers
    };
    for (cases) |c| {
        const reg = try Registry.fromConfig(arena, v, c.agent);
        try std.testing.expectEqual(c.count, reg.configs.len);
        try std.testing.expectEqual(@as(usize, 5), reg.all_configs.len);
        try std.testing.expectEqualStrings(c.agent, reg.agent);
    }

    // forAgent re-filters the full list: it is not limited to what the parent sees.
    const parent = try Registry.fromConfig(arena, v, "parent");
    const research = parent.forAgent(arena, "research");
    try std.testing.expectEqual(@as(usize, 3), research.configs.len);
    try std.testing.expectEqual(@as(usize, 0), research.clients.items.len);
    try std.testing.expect(research.isDenied("parent_only"));
    try std.testing.expect(!research.isDenied("research_only"));
    try std.testing.expect(!research.isDenied("ghost")); // unknown is not "denied"
    try std.testing.expectEqual(@as(usize, 4), parent.configs.len); // the parent keeps its set
}

test "a denied server is never spawned and reads like an unknown one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir_buf: [4096]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const marker = try std.fmt.allocPrint(arena, "{s}/spawned", .{dir_buf[0..dir_len]});
    const script = try writeFakeServerWith(tmp.dir, io, arena, "marker-mcp.sh", try std.fmt.allocPrint(arena, "touch '{s}'", .{marker}));
    const cfg_json = try std.fmt.allocPrint(arena, "{{\"s\":{{\"command\":\"{s}\",\"agents\":[\"research\"]}}}}", .{script});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json, .{});

    var parent = try Registry.init(io, arena, v, "parent");
    defer parent.deinit();
    try std.testing.expectEqual(@as(usize, 0), parent.configs.len);
    try std.testing.expectEqual(@as(usize, 0), parent.allTools(arena).len);
    try std.testing.expectError(error.UnknownServer, parent.describe(arena, "s", "echo"));
    try std.testing.expectError(error.UnknownServer, parent.call(arena, "s", "echo", "{}"));
    try std.testing.expectEqualStrings("error: server 's' unavailable", parent.describeText(arena, "s", "echo"));
    try std.testing.expectEqualStrings("error: mcp server 's' is not enabled for agent 'parent'", callHook(&parent, arena, "s", "echo", "{}"));
    // A truly unknown server keeps the old wording.
    try std.testing.expectEqualStrings("error: mcp call failed: UnknownServer", callHook(&parent, arena, "ghost", "echo", "{}"));
    try std.testing.expectEqual(@as(usize, 0), parent.clients.items.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "spawned", .{}));

    // The research view is the only one that starts it.
    var research = parent.forAgent(arena, "research");
    defer research.deinit();
    try std.testing.expectEqualStrings("echoed-ok", callHook(&research, arena, "s", "echo", "{}"));
    try tmp.dir.access(io, "spawned", .{});
}

test "mcp_list wording: no servers, none for this agent, and the tool list" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var empty = try Registry.init(io, arena, null, "parent");
    try std.testing.expectEqualStrings("no MCP servers configured", listHook(&empty, arena));

    const script = try writeFakeServer(tmp.dir, io, arena);
    const cfg_json = try std.fmt.allocPrint(arena, "{{\"s\":{{\"command\":\"{s}\",\"agents\":[\"research\"]}}}}", .{script});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json, .{});
    var parent = try Registry.init(io, arena, v, "parent");
    defer parent.deinit();
    try std.testing.expectEqualStrings("no MCP servers for agent 'parent'", listHook(&parent, arena));

    var research = parent.forAgent(arena, "research");
    defer research.deinit();
    try std.testing.expectEqualStrings("s.echo: Echo back\n", listHook(&research, arena));
}
