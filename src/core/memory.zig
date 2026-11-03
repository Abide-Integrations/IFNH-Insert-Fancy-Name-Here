//! Advisory memory (ACTIVE_PLAN E-05a, DECISIONS Q223-232).
//!
//! Off by default. When `memory.adapter` is `file` or `mcp`, the model may
//! call `memory_recall`, `memory_remember` and `memory_forget`; nothing is ever
//! injected into the prompt on its own (Q231). `Adapter` is a plain struct of
//! function pointers. Two implementations ship: JSONL files (`FileAdapter`)
//! and a proxy to tools on a configured MCP server (`McpAdapter`, Q232), which
//! reuses `core/mcp.zig` rather than a second transport.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const mcp_mod = @import("mcp.zig");
const config_mod = @import("config/config.zig");

pub const Scope = enum { project, user };

pub const max_text_bytes: usize = 4096;
pub const max_recall_snippets: usize = 8;
pub const max_recall_bytes: usize = 4096;
/// Largest memory file read in one go.
const max_file_bytes: usize = 4 * 1024 * 1024;

/// Why the last adapter call failed, in words a user can act on. Set on every
/// error return; the error value itself only classifies.
pub const Diag = struct { message: []const u8 = "" };

pub const Entry = struct {
    text: []const u8,
    /// Who wrote it: "tool" (the model), "cli"...
    source: []const u8 = "tool",
};

pub const Snippet = struct {
    id: []const u8,
    /// ISO-8601 UTC.
    ts: []const u8,
    text: []const u8,
};

pub const RecallOptions = struct {
    max_snippets: usize = max_recall_snippets,
    max_bytes: usize = max_recall_bytes,
};

pub const Recall = struct {
    snippets: []const Snippet = &.{},
    /// Malformed lines that were passed over.
    skipped: usize = 0,
    /// An adapter that answers in prose (MCP) returns that text instead.
    text: ?[]const u8 = null,
};

pub const Forgot = struct {
    count: usize = 0,
    /// An adapter that cannot report a count returns the server's reply.
    text: ?[]const u8 = null,
};

pub const QueryKind = enum { substring, server };

pub const Capabilities = struct {
    query: QueryKind,
    scopes: []const []const u8,
    delete: bool,
};

pub const Adapter = struct {
    ctx: *anyopaque,
    recall_fn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, query: []const u8, scope: Scope, opts: RecallOptions) anyerror!Recall,
    remember_fn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, entry: Entry, scope: Scope) anyerror![]const u8,
    forget_fn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, scope: Scope, id: ?[]const u8) anyerror!Forgot,
    capabilities_fn: *const fn (ctx: *anyopaque) Capabilities,

    pub fn recall(self: Adapter, arena: std.mem.Allocator, io: std.Io, diag: *Diag, query: []const u8, scope: Scope, opts: RecallOptions) anyerror!Recall {
        return self.recall_fn(self.ctx, arena, io, diag, query, scope, opts);
    }

    /// Store `entry`; returns its id (or the server's reply for MCP).
    pub fn remember(self: Adapter, arena: std.mem.Allocator, io: std.Io, diag: *Diag, entry: Entry, scope: Scope) anyerror![]const u8 {
        return self.remember_fn(self.ctx, arena, io, diag, entry, scope);
    }

    /// Delete one entry by `id`, or the whole scope when `id` is null.
    pub fn forget(self: Adapter, arena: std.mem.Allocator, io: std.Io, diag: *Diag, scope: Scope, id: ?[]const u8) anyerror!Forgot {
        return self.forget_fn(self.ctx, arena, io, diag, scope, id);
    }

    pub fn capabilities(self: Adapter) Capabilities {
        return self.capabilities_fn(self.ctx);
    }
};

// ---------------------------------------------------------------- file adapter

var id_counter: std.atomic.Value(u32) = .init(0);

/// JSONL files, one `{"id","ts","scope","text","source"}` object per line.
/// Project scope: `<workspace>/.ifnh/memory/project.jsonl`. User scope:
/// `<user config dir>/memory/user.jsonl`.
pub const FileAdapter = struct {
    workspace: std.Io.Dir,
    /// `<config dir>/memory`; null when there is no home directory.
    user_dir: ?[]const u8,

    pub fn adapter(self: *FileAdapter) Adapter {
        return .{
            .ctx = self,
            .recall_fn = recallImpl,
            .remember_fn = rememberImpl,
            .forget_fn = forgetImpl,
            .capabilities_fn = capabilitiesImpl,
        };
    }

    const Location = struct { dir: std.Io.Dir, dir_path: []const u8, file_path: []const u8 };

    fn locate(self: *FileAdapter, arena: std.mem.Allocator, diag: *Diag, scope: Scope) !Location {
        switch (scope) {
            .project => return .{ .dir = self.workspace, .dir_path = ".ifnh/memory", .file_path = ".ifnh/memory/project.jsonl" },
            .user => {
                const base = self.user_dir orelse {
                    diag.message = "user memory needs a home directory (HOME is not set)";
                    return error.NoUserDir;
                };
                return .{
                    .dir = std.Io.Dir.cwd(),
                    .dir_path = base,
                    .file_path = try std.fmt.allocPrint(arena, "{s}/user.jsonl", .{base}),
                };
            },
        }
    }

    /// Whole file, or "" when it does not exist yet.
    fn readFile(loc: Location, arena: std.mem.Allocator, io: std.Io, diag: *Diag) ![]const u8 {
        return fsutil.readSmallFile(loc.dir, io, arena, loc.file_path, max_file_bytes) catch |err| switch (err) {
            error.FileNotFound => return "",
            error.TooLarge => {
                diag.message = "memory file is larger than 4 MiB; clear it with `ifnh memory purge`";
                return err;
            },
            else => return err,
        };
    }

    const Stored = struct { id: []const u8, ts: []const u8, text: []const u8 };

    /// Valid entries of one line, or null for a malformed one.
    fn parseLine(arena: std.mem.Allocator, line: []const u8) ?Stored {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
        if (v != .object) return null;
        const id = v.object.get("id") orelse return null;
        const text = v.object.get("text") orelse return null;
        if (id != .string or text != .string or id.string.len == 0) return null;
        const ts = v.object.get("ts") orelse std.json.Value{ .string = "" };
        return .{ .id = id.string, .ts = if (ts == .string) ts.string else "", .text = text.string };
    }

    fn recallImpl(ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, query: []const u8, scope: Scope, opts: RecallOptions) anyerror!Recall {
        const self: *FileAdapter = @ptrCast(@alignCast(ctx));
        const loc = try self.locate(arena, diag, scope);
        const content = try readFile(loc, arena, io, diag);

        // Newest first: the file is append-only, so the last line is newest.
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0) try lines.append(arena, line);
        }
        var out: std.ArrayListUnmanaged(Snippet) = .empty;
        var skipped: usize = 0;
        var budget: usize = 0;
        var full = false;
        var i = lines.items.len;
        while (i > 0) {
            i -= 1;
            const stored = parseLine(arena, lines.items[i]) orelse {
                skipped += 1;
                continue;
            };
            if (full) continue; // keep counting malformed lines
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(stored.text, query) == null) continue;
            if (out.items.len >= opts.max_snippets or budget + stored.text.len > opts.max_bytes) {
                full = true;
                continue;
            }
            budget += stored.text.len;
            try out.append(arena, .{ .id = stored.id, .ts = stored.ts, .text = stored.text });
        }
        return .{ .snippets = out.items, .skipped = skipped };
    }

    fn rememberImpl(ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, entry: Entry, scope: Scope) anyerror![]const u8 {
        const self: *FileAdapter = @ptrCast(@alignCast(ctx));
        if (std.mem.trim(u8, entry.text, " \t\r\n").len == 0) {
            diag.message = "memory text is empty";
            return error.EmptyText;
        }
        if (entry.text.len > max_text_bytes) {
            diag.message = try std.fmt.allocPrint(arena, "memory text is {d} bytes; the limit is {d}", .{ entry.text.len, max_text_bytes });
            return error.TextTooLarge;
        }
        const loc = try self.locate(arena, diag, scope);

        const now_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
        const id = try std.fmt.allocPrint(arena, "{x}-{x}", .{ now_ms, id_counter.fetchAdd(1, .monotonic) });
        var ts_buf: [20]u8 = undefined;

        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, w);
        try w.writeAll(",\"ts\":");
        try std.json.Stringify.value(fsutil.isoUtc(&ts_buf, now_ms / 1000), .{}, w);
        try w.writeAll(",\"scope\":");
        try std.json.Stringify.value(@tagName(scope), .{}, w);
        try w.writeAll(",\"text\":");
        try std.json.Stringify.value(entry.text, .{}, w);
        try w.writeAll(",\"source\":");
        try std.json.Stringify.value(entry.source, .{}, w);
        try w.writeAll("}\n");

        try loc.dir.createDirPath(io, loc.dir_path);
        const file = try loc.dir.createFile(io, loc.file_path, .{ .truncate = false, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(io);
        const stat = try file.stat(io);
        try file.writePositionalAll(io, aw.written(), stat.size);
        return id;
    }

    fn forgetImpl(ctx: *anyopaque, arena: std.mem.Allocator, io: std.Io, diag: *Diag, scope: Scope, id: ?[]const u8) anyerror!Forgot {
        const self: *FileAdapter = @ptrCast(@alignCast(ctx));
        const loc = try self.locate(arena, diag, scope);
        const content = try readFile(loc, arena, io, diag);

        var kept: std.ArrayListUnmanaged(u8) = .empty;
        var removed: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const stored = parseLine(arena, line);
            if (id) |want| {
                // Only the named entry goes; malformed lines are left alone.
                if (stored) |s| {
                    if (std.mem.eql(u8, s.id, want)) {
                        removed += 1;
                        continue;
                    }
                }
                try kept.appendSlice(arena, line);
                try kept.append(arena, '\n');
            } else if (stored != null) {
                removed += 1;
            }
        }
        if (removed == 0) return .{};
        try fsutil.atomicWriteFile(loc.dir, io, arena, loc.file_path, kept.items);
        return .{ .count = removed };
    }

    fn capabilitiesImpl(_: *anyopaque) Capabilities {
        return .{ .query = .substring, .scopes = &.{ "project", "user" }, .delete = true };
    }
};

// ---------------------------------------------------------------- MCP adapter

pub const ToolNames = struct {
    recall: []const u8 = "memory_recall",
    remember: []const u8 = "memory_remember",
    forget: []const u8 = "memory_forget",
};

/// Proxies to tools of one configured MCP server. The server decides what
/// "recall" means, so replies are passed through as text.
pub const McpAdapter = struct {
    registry: *mcp_mod.Registry,
    server: []const u8,
    tools: ToolNames = .{},
    /// Tools already seen in the server's tool list (recall, remember, forget).
    checked: [3]bool = .{ false, false, false },

    pub fn adapter(self: *McpAdapter) Adapter {
        return .{
            .ctx = self,
            .recall_fn = recallImpl,
            .remember_fn = rememberImpl,
            .forget_fn = forgetImpl,
            .capabilities_fn = capabilitiesImpl,
        };
    }

    /// Call tool number `which` (0 recall, 1 remember, 2 forget) and return
    /// its text. A missing server or tool is a clear error, not a crash.
    fn call(self: *McpAdapter, arena: std.mem.Allocator, diag: *Diag, which: usize, tool: []const u8, args_json: []const u8) ![]const u8 {
        if (!self.checked[which]) {
            const found = self.registry.describe(arena, self.server, tool) catch |err| {
                diag.message = switch (err) {
                    error.UnknownServer => try std.fmt.allocPrint(arena, "memory server '{s}' is not configured or not enabled for this agent (mcp_servers)", .{self.server}),
                    else => try std.fmt.allocPrint(arena, "memory server '{s}' is unavailable: {s}{s}{s}", .{
                        self.server,
                        @errorName(err),
                        if (self.registry.detail.len > 0) " " else "",
                        self.registry.detail,
                    }),
                };
                return error.ServerUnavailable;
            };
            if (found == null) {
                diag.message = try std.fmt.allocPrint(arena, "memory tool '{s}' not found on MCP server '{s}' (set memory.tools)", .{ tool, self.server });
                return error.ToolMissing;
            }
            self.checked[which] = true;
        }
        const res = self.registry.call(arena, self.server, tool, args_json) catch |err| {
            diag.message = try std.fmt.allocPrint(arena, "memory call to {s}.{s} failed: {s}", .{ self.server, tool, @errorName(err) });
            return error.CallFailed;
        };
        if (res.is_error) {
            diag.message = try std.fmt.allocPrint(arena, "memory server error from {s}.{s}: {s}", .{ self.server, tool, res.text });
            return error.CallFailed;
        }
        return res.text;
    }

    fn recallImpl(ctx: *anyopaque, arena: std.mem.Allocator, _: std.Io, diag: *Diag, query: []const u8, scope: Scope, opts: RecallOptions) anyerror!Recall {
        const self: *McpAdapter = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.writeAll("{\"query\":");
        try std.json.Stringify.value(query, .{}, &aw.writer);
        try aw.writer.print(",\"scope\":\"{s}\",\"limit\":{d}}}", .{ @tagName(scope), opts.max_snippets });
        return .{ .text = try self.call(arena, diag, 0, self.tools.recall, aw.written()) };
    }

    fn rememberImpl(ctx: *anyopaque, arena: std.mem.Allocator, _: std.Io, diag: *Diag, entry: Entry, scope: Scope) anyerror![]const u8 {
        const self: *McpAdapter = @ptrCast(@alignCast(ctx));
        if (std.mem.trim(u8, entry.text, " \t\r\n").len == 0) {
            diag.message = "memory text is empty";
            return error.EmptyText;
        }
        if (entry.text.len > max_text_bytes) {
            diag.message = try std.fmt.allocPrint(arena, "memory text is {d} bytes; the limit is {d}", .{ entry.text.len, max_text_bytes });
            return error.TextTooLarge;
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.writeAll("{\"text\":");
        try std.json.Stringify.value(entry.text, .{}, &aw.writer);
        try aw.writer.print(",\"scope\":\"{s}\"}}", .{@tagName(scope)});
        return self.call(arena, diag, 1, self.tools.remember, aw.written());
    }

    fn forgetImpl(ctx: *anyopaque, arena: std.mem.Allocator, _: std.Io, diag: *Diag, scope: Scope, id: ?[]const u8) anyerror!Forgot {
        const self: *McpAdapter = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{{\"scope\":\"{s}\"", .{@tagName(scope)});
        if (id) |i| {
            try aw.writer.writeAll(",\"id\":");
            try std.json.Stringify.value(i, .{}, &aw.writer);
        }
        try aw.writer.writeByte('}');
        const text = try self.call(arena, diag, 2, self.tools.forget, aw.written());
        // A bare number is a count; anything else is shown as the server said it.
        if (std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t\r\n"), 10)) |n| return .{ .count = n } else |_| {}
        return .{ .text = text };
    }

    fn capabilitiesImpl(_: *anyopaque) Capabilities {
        return .{ .query = .server, .scopes = &.{ "project", "user" }, .delete = true };
    }
};

// ---------------------------------------------------------------- config + handle

pub const Kind = enum { none, file, mcp };

pub const Settings = struct {
    kind: Kind = .none,
    scope: Scope = .project,
    server: []const u8 = "",
    tools: ToolNames = .{},
};

/// `memory.*` from a validated config (unknown values fall back to the
/// defaults; `Store.validate` has already reported them).
pub fn settingsFrom(cfg: *const config_mod.Store) Settings {
    return .{
        .kind = std.meta.stringToEnum(Kind, cfg.getString("memory.adapter", "none")) orelse .none,
        .scope = std.meta.stringToEnum(Scope, cfg.getString("memory.scope", "project")) orelse .project,
        .server = cfg.getOptionalString("memory.server") orelse "",
        .tools = .{
            .recall = cfg.getOptionalString("memory.tools.recall") orelse "memory_recall",
            .remember = cfg.getOptionalString("memory.tools.remember") orelse "memory_remember",
            .forget = cfg.getOptionalString("memory.tools.forget") orelse "memory_forget",
        },
    };
}

/// An open adapter plus the context its tool hooks need. Allocate it once
/// (it points into itself) and share it with subagents; `mutex` serializes
/// calls because the MCP adapter owns one connection.
pub const Handle = struct {
    io: std.Io,
    scope: Scope,
    file: FileAdapter,
    mcp: McpAdapter,
    adapter: Adapter,
    mutex: std.Io.Mutex = .init,
};

/// Open the adapter `settings` names, or null when memory is off. The MCP
/// adapter needs `registry`; without one it reports itself unavailable on use.
pub fn open(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    settings: Settings,
    registry: ?*mcp_mod.Registry,
) ?*Handle {
    if (settings.kind == .none) return null;
    const h = arena.create(Handle) catch return null;
    h.* = .{
        .io = io,
        .scope = settings.scope,
        .file = .{
            .workspace = workspace,
            .user_dir = if (config_mod.userConfigDir(arena, environ)) |d|
                (std.fmt.allocPrint(arena, "{s}/memory", .{d}) catch null)
            else
                null,
        },
        .mcp = .{ .registry = registry orelse &no_registry, .server = settings.server, .tools = settings.tools },
        .adapter = undefined,
    };
    h.adapter = if (settings.kind == .mcp) h.mcp.adapter() else h.file.adapter();
    return h;
}

/// Stand-in for an MCP adapter opened without a registry: no servers.
var no_registry: mcp_mod.Registry = .{ .io = undefined, .alloc = undefined, .configs = &.{} };

// ---------------------------------------------------------------- tool hooks
//
// Model-facing text. The `memory_*` tools call these through `ToolContext`.

fn failText(arena: std.mem.Allocator, err: anyerror, diag: Diag) []const u8 {
    const why = if (diag.message.len > 0) diag.message else @errorName(err);
    return std.fmt.allocPrint(arena, "error: {s}", .{why}) catch "error: memory failed";
}

/// Cut `text` at a UTF-8 boundary to at most `max` bytes.
fn capUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn recallHook(ctx: *anyopaque, arena: std.mem.Allocator, query: []const u8) []const u8 {
    const h: *Handle = @ptrCast(@alignCast(ctx));
    h.mutex.lock(h.io) catch return "error: cancelled";
    defer h.mutex.unlock(h.io);
    var diag = Diag{};
    const res = h.adapter.recall(arena, h.io, &diag, query, h.scope, .{}) catch |err| return failText(arena, err, diag);
    return formatRecall(arena, res);
}

pub fn formatRecall(arena: std.mem.Allocator, res: Recall) []const u8 {
    if (res.text) |t| {
        const capped = capUtf8(t, max_recall_bytes);
        return if (capped.len == 0) "no memory matches" else capped;
    }
    if (res.snippets.len == 0) return "no memory matches";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (res.snippets) |s| {
        out.print(arena, "- {s} ({s}): ", .{ s.id, s.ts }) catch break;
        // One line per snippet.
        for (s.text) |c| out.append(arena, if (c == '\n' or c == '\r') ' ' else c) catch break;
        out.append(arena, '\n') catch break;
    }
    if (res.skipped > 0) out.print(arena, "[{d} malformed line(s) skipped]\n", .{res.skipped}) catch {};
    return out.items;
}

pub fn rememberHook(ctx: *anyopaque, arena: std.mem.Allocator, text: []const u8) []const u8 {
    const h: *Handle = @ptrCast(@alignCast(ctx));
    h.mutex.lock(h.io) catch return "error: cancelled";
    defer h.mutex.unlock(h.io);
    var diag = Diag{};
    const id = h.adapter.remember(arena, h.io, &diag, .{ .text = text, .source = "tool" }, h.scope) catch |err| return failText(arena, err, diag);
    return capUtf8(id, max_recall_bytes);
}

pub fn forgetHook(ctx: *anyopaque, arena: std.mem.Allocator, id: ?[]const u8) []const u8 {
    const h: *Handle = @ptrCast(@alignCast(ctx));
    h.mutex.lock(h.io) catch return "error: cancelled";
    defer h.mutex.unlock(h.io);
    var diag = Diag{};
    const res = h.adapter.forget(arena, h.io, &diag, h.scope, id) catch |err| return failText(arena, err, diag);
    if (res.text) |t| return capUtf8(t, max_recall_bytes);
    return std.fmt.allocPrint(arena, "{d}", .{res.count}) catch "0";
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn tmpFileAdapter(tmp: *testing.TmpDir, user_dir: ?[]const u8) FileAdapter {
    return .{ .workspace = tmp.dir, .user_dir = user_dir };
}

test "memory file adapter: remember then recall round-trips through JSONL" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fa = tmpFileAdapter(&tmp, null);
    const a = fa.adapter();
    var diag = Diag{};
    const id = try a.remember(arena, io, &diag, .{ .text = "deploys go through \"make ship\"\nnever on Friday", .source = "cli" }, .project);
    try testing.expect(id.len > 0);

    const res = try a.recall(arena, io, &diag, "MAKE SHIP", .project, .{});
    try testing.expectEqual(@as(usize, 1), res.snippets.len);
    try testing.expectEqualStrings(id, res.snippets[0].id);
    try testing.expectEqualStrings("deploys go through \"make ship\"\nnever on Friday", res.snippets[0].text);
    try testing.expectEqual(@as(usize, 20), res.snippets[0].ts.len);

    // The file holds exactly one object per line with the documented keys.
    const raw = try tmp.dir.readFileAlloc(io, ".ifnh/memory/project.jsonl", arena, .limited(1 << 16));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "\n"));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    for ([_][]const u8{ "id", "ts", "scope", "text", "source" }) |k| try testing.expect(v.object.get(k) != null);
    try testing.expectEqualStrings("project", v.object.get("scope").?.string);
    try testing.expectEqualStrings("cli", v.object.get("source").?.string);

    // A second entry is appended, not rewritten; ids are distinct.
    const id2 = try a.remember(arena, io, &diag, .{ .text = "second" }, .project);
    try testing.expect(!std.mem.eql(u8, id, id2));
    const raw2 = try tmp.dir.readFileAlloc(io, ".ifnh/memory/project.jsonl", arena, .limited(1 << 16));
    try testing.expect(std.mem.startsWith(u8, raw2, raw));
}

test "memory recall: newest first, 8 snippet cap, 4 KiB budget" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fa = tmpFileAdapter(&tmp, null);
    const a = fa.adapter();
    var diag = Diag{};
    for (0..12) |n| {
        _ = try a.remember(arena, io, &diag, .{ .text = try std.fmt.allocPrint(arena, "note {d}", .{n}) }, .project);
    }
    const res = try a.recall(arena, io, &diag, "note", .project, .{});
    try testing.expectEqual(@as(usize, 8), res.snippets.len);
    try testing.expectEqualStrings("note 11", res.snippets[0].text);
    try testing.expectEqualStrings("note 4", res.snippets[7].text);
    const none = try a.recall(arena, io, &diag, "absent", .project, .{});
    try testing.expectEqual(@as(usize, 0), none.snippets.len);

    // Byte budget: 1500-byte entries, three would be 4500 > 4096.
    _ = try a.forget(arena, io, &diag, .project, null);
    for (0..4) |n| {
        const text = try std.fmt.allocPrint(arena, "big{d}{s}", .{ n, "x" ** 1496 });
        _ = try a.remember(arena, io, &diag, .{ .text = text }, .project);
    }
    const big = try a.recall(arena, io, &diag, "", .project, .{});
    try testing.expectEqual(@as(usize, 2), big.snippets.len);
    try testing.expect(std.mem.startsWith(u8, big.snippets[0].text, "big3"));
}

test "memory recall: a missing file is empty and malformed lines are skipped and counted" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fa = tmpFileAdapter(&tmp, null);
    const a = fa.adapter();
    var diag = Diag{};
    const missing = try a.recall(arena, io, &diag, "x", .project, .{});
    try testing.expectEqual(@as(usize, 0), missing.snippets.len);
    try testing.expectEqual(@as(usize, 0), missing.skipped);
    try testing.expect(!fsutil.fileExists(tmp.dir, io, ".ifnh/memory"));

    try tmp.dir.createDirPath(io, ".ifnh/memory");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/memory/project.jsonl", .data = "{\"id\":\"a\",\"ts\":\"t\",\"scope\":\"project\",\"text\":\"keep me\",\"source\":\"tool\"}\nnot json\n{\"id\":\"b\"}\n[1]\n\n" });
    const res = try a.recall(arena, io, &diag, "keep", .project, .{});
    try testing.expectEqual(@as(usize, 1), res.snippets.len);
    try testing.expectEqual(@as(usize, 3), res.skipped);
}

test "memory forget: by id, by scope, and nothing to delete is 0" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fa = tmpFileAdapter(&tmp, null);
    const a = fa.adapter();
    var diag = Diag{};
    try testing.expectEqual(@as(usize, 0), (try a.forget(arena, io, &diag, .project, null)).count);
    try testing.expectEqual(@as(usize, 0), (try a.forget(arena, io, &diag, .project, "nope")).count);

    const one = try a.remember(arena, io, &diag, .{ .text = "one" }, .project);
    _ = try a.remember(arena, io, &diag, .{ .text = "two" }, .project);
    // A malformed line survives a forget-by-id untouched.
    const path = ".ifnh/memory/project.jsonl";
    const before = try tmp.dir.readFileAlloc(io, path, arena, .limited(1 << 16));
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = try std.fmt.allocPrint(arena, "{s}garbage line\n", .{before}) });

    try testing.expectEqual(@as(usize, 0), (try a.forget(arena, io, &diag, .project, "nope")).count);
    try testing.expectEqual(@as(usize, 1), (try a.forget(arena, io, &diag, .project, one)).count);
    const left = try a.recall(arena, io, &diag, "", .project, .{});
    try testing.expectEqual(@as(usize, 1), left.snippets.len);
    try testing.expectEqualStrings("two", left.snippets[0].text);
    try testing.expectEqual(@as(usize, 1), left.skipped);

    try testing.expectEqual(@as(usize, 1), (try a.forget(arena, io, &diag, .project, null)).count);
    const gone = try a.recall(arena, io, &diag, "", .project, .{});
    try testing.expectEqual(@as(usize, 0), gone.snippets.len);
    try testing.expectEqual(@as(usize, 0), (try a.forget(arena, io, &diag, .project, null)).count);
}

test "memory remember rejects empty and oversized text; user scope needs a directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fa = tmpFileAdapter(&tmp, null);
    const a = fa.adapter();
    var diag = Diag{};
    try testing.expectError(error.EmptyText, a.remember(arena, io, &diag, .{ .text = " \n" }, .project));
    try testing.expectEqualStrings("memory text is empty", diag.message);
    try testing.expectError(error.TextTooLarge, a.remember(arena, io, &diag, .{ .text = "x" ** (max_text_bytes + 1) }, .project));
    try testing.expect(std.mem.indexOf(u8, diag.message, "4096") != null);
    _ = try a.remember(arena, io, &diag, .{ .text = "y" ** max_text_bytes }, .project); // exactly the limit
    try testing.expectError(error.NoUserDir, a.remember(arena, io, &diag, .{ .text = "z" }, .user));
    try testing.expect(std.mem.indexOf(u8, diag.message, "HOME") != null);
    // Nothing was written for the rejected texts.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try tmp.dir.readFileAlloc(io, ".ifnh/memory/project.jsonl", arena, .limited(1 << 16)), "\n"));
}

test "memory user scope lives under the user directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, ".", &path_buf);
    const user_dir = try std.fmt.allocPrint(arena, "{s}/cfg/memory", .{path_buf[0..n]});
    var fa = tmpFileAdapter(&tmp, user_dir);
    const a = fa.adapter();
    var diag = Diag{};
    _ = try a.remember(arena, io, &diag, .{ .text = "prefers tabs" }, .user);
    try testing.expect(fsutil.fileExists(tmp.dir, io, "cfg/memory/user.jsonl"));
    try testing.expect(!fsutil.fileExists(tmp.dir, io, ".ifnh/memory/project.jsonl"));
    const res = try a.recall(arena, io, &diag, "tabs", .user, .{});
    try testing.expectEqual(@as(usize, 1), res.snippets.len);
    try testing.expectEqual(@as(usize, 0), (try a.recall(arena, io, &diag, "tabs", .project, .{})).snippets.len);
}

test "memory capabilities" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fa = tmpFileAdapter(&tmp, null);
    const caps = fa.adapter().capabilities();
    try testing.expectEqual(QueryKind.substring, caps.query);
    try testing.expect(caps.delete);
    try testing.expectEqual(@as(usize, 2), caps.scopes.len);
    try testing.expectEqualStrings("project", caps.scopes[0]);
    try testing.expectEqualStrings("user", caps.scopes[1]);
}

test "memory tool hooks print ids, matches and counts" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h = open(arena, io, tmp.dir, null, .{ .kind = .file }, null).?;
    try testing.expectEqualStrings("no memory matches", recallHook(h, arena, "anything"));
    const id = rememberHook(h, arena, "line one\nline two");
    try testing.expect(!std.mem.startsWith(u8, id, "error"));
    const text = recallHook(h, arena, "line");
    try testing.expect(std.mem.startsWith(u8, text, try std.fmt.allocPrint(arena, "- {s} (", .{id})));
    try testing.expect(std.mem.indexOf(u8, text, "): line one line two\n") != null);
    try testing.expectEqualStrings("error: memory text is empty", rememberHook(h, arena, ""));
    try testing.expectEqualStrings("1", forgetHook(h, arena, null));
    try testing.expectEqualStrings("0", forgetHook(h, arena, id));
    try testing.expect(open(arena, io, tmp.dir, null, .{ .kind = .none }, null) == null);
}

/// A stdio MCP server that echoes each `tools/call` request line back as its
/// text, and lists only the recall and remember tools.
const memory_server_script =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  [ -n "$id" ] || continue
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\"}}}" ;;
    \\    *'"method":"tools/list"'*) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"memory_recall\",\"description\":\"r\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"mem_put\",\"description\":\"w\",\"inputSchema\":{\"type\":\"object\"}}]}}" ;;
    \\    *'"method":"tools/call"'*)
    \\      esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
    \\      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"$esc\"}]}}" ;;
    \\    *) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}" ;;
    \\  esac
    \\done
    \\
;

test "memory mcp adapter maps recall and remember to the configured tools; a missing tool is a clean error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "mem-mcp.sh", .data = memory_server_script });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "mem-mcp.sh", &path_buf);
    const script = path_buf[0..n];
    _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "+x", script } }) catch {};

    const cfg_json = try std.fmt.allocPrint(arena, "{{\"mem\":{{\"command\":\"{s}\"}}}}", .{script});
    const servers = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json, .{});
    var registry = try mcp_mod.Registry.init(io, arena, servers, "parent");
    defer registry.deinit();

    var ma = McpAdapter{ .registry = &registry, .server = "mem", .tools = .{ .remember = "mem_put" } };
    const a = ma.adapter();
    var diag = Diag{};

    const recalled = try a.recall(arena, io, &diag, "deploy \"it\"", .user, .{});
    try testing.expect(recalled.text != null);
    try testing.expect(std.mem.indexOf(u8, recalled.text.?, "\"name\":\"memory_recall\"") != null);
    try testing.expect(std.mem.indexOf(u8, recalled.text.?, "\"query\":\"deploy \\\"it\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, recalled.text.?, "\"scope\":\"user\",\"limit\":8") != null);

    const stored = try a.remember(arena, io, &diag, .{ .text = "likes zig" }, .project);
    try testing.expect(std.mem.indexOf(u8, stored, "\"name\":\"mem_put\"") != null);
    try testing.expect(std.mem.indexOf(u8, stored, "\"text\":\"likes zig\",\"scope\":\"project\"") != null);

    // memory_forget is not on this server.
    try testing.expectError(error.ToolMissing, a.forget(arena, io, &diag, .project, "x"));
    try testing.expect(std.mem.indexOf(u8, diag.message, "memory_forget") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "'mem'") != null);

    // A server that is not configured is a clear error too.
    var ghost = McpAdapter{ .registry = &registry, .server = "ghost" };
    try testing.expectError(error.ServerUnavailable, ghost.adapter().recall(arena, io, &diag, "q", .project, .{}));
    try testing.expect(std.mem.indexOf(u8, diag.message, "'ghost'") != null);
    try testing.expectEqual(QueryKind.server, a.capabilities().query);
}
