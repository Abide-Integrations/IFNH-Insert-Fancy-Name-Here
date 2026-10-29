//! Tool contract, registry, and dispatch (DESIGN §3.2).
//!
//! M0 tools: read, glob, grep, edit, write, bash, git. Tool arguments are
//! JSON objects decoded with std.json. Mutating tools journal their file
//! operations (bash/git side effects are opaque and not journaled — they
//! are gated by approvals instead, DECISIONS M185-186).
//!
//! Every tool result is model-facing text, UTF-8-safe, and capped.

const std = @import("std");
const builtin = @import("builtin");
const core_types = @import("../core/types.zig");
const engine_mod = @import("../core/permissions/engine.zig");
const journal_mod = @import("../core/journal.zig");
const globm = @import("../core/permissions/glob.zig");

pub const max_tool_output_bytes: usize = 64 * 1024;
pub const max_file_size_bytes: usize = 1024 * 1024;

pub const Status = enum { ok, denied, failed, timeout };

/// Tools that only read the workspace and never prompt for approval. These
/// may run concurrently as one batch (DECISIONS #58 leadingParallelGroup).
pub fn isReadOnly(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "grep");
}

pub const ApprovalRequest = struct {
    pub const Grant = union(enum) {
        none,
        command_prefix: []const u8,
        path_write: []const u8,
    };

    title: []const u8,
    detail: []const u8, // command line or path
    /// What a session-scope approval should grant.
    grant: Grant = .none,
};

pub const ApprovalResponse = enum { approved_once, approved_session, denied };

pub const ToolContext = struct {
    io: std.Io,
    /// Scratch arena for this tool call only.
    arena: std.mem.Allocator,
    workspace: std.Io.Dir,
    engine: *engine_mod.Engine,
    journal: ?*journal_mod.Journal,
    max_file_read_bytes: usize,
    /// Approval callback wired to the UI; used when the engine says `ask`.
    approval_ctx: *anyopaque,
    approval_fn: *const fn (ctx: *anyopaque, req: ApprovalRequest) ApprovalResponse,
    /// Subagent runtime hook (wired by the host; null disables spawning).
    agent_spawn_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, parent_depth: usize, arguments_json: []const u8) AgentSpawnResult = null,
    agent_spawn_ctx: ?*anyopaque = null,
    /// Background-execution hooks (wired by the host; null disables them).
    exec_start_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) []const u8 = null,
    exec_query_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, action: []const u8, id: []const u8) []const u8 = null,
    exec_ctx: ?*anyopaque = null,
    /// Skill loader hook (wired by the host; null disables the tool).
    skill_load_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 = null,
    skill_ctx: ?*anyopaque = null,
    /// MCP registry hooks (wired by the host; null disables MCP).
    mcp_list_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator) []const u8 = null,
    mcp_call_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) []const u8 = null,
    mcp_describe_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8) []const u8 = null,
    mcp_ctx: ?*anyopaque = null,
    /// Turn cancel flag (A-T06). `runCaptured` kills the child process group
    /// when it flips; null when nothing can cancel.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Wall-clock limit for one captured command (`agents.timeout_tool_s`).
    timeout_s: u32 = 120,
    /// Delegation depth of the agent owning this context (0 = parent).
    agent_depth: usize = 0,
    /// Display label for approval provenance ("parent", "research-1"...).
    agent_label: []const u8 = "",

    pub fn requestApproval(self: *ToolContext, title: []const u8, detail: []const u8, grant: ApprovalRequest.Grant) bool {
        const resp = self.approval_fn(self.approval_ctx, .{ .title = title, .detail = detail, .grant = grant });
        switch (resp) {
            .approved_once, .approved_session => return true,
            .denied => return false,
        }
    }
};

pub const ToolResult = struct {
    output: []const u8,
    status: Status = .ok,
};

/// Result of a subagent run (defined here to avoid an import cycle).
pub const AgentSpawnResult = struct {
    pub const SpawnStatus = enum { completed, failed };

    status: SpawnStatus = .completed,
    summary: []const u8 = "",
    report_path: []const u8 = "",
    tool_calls: usize = 0,
};

pub const Spec = core_types.ToolSpec;

/// Tool specs advertised to the model (order = advertisement order).
pub const specs = [_]Spec{
    .{ .name = "read", .description = "Read a text file with line numbers. Supports offset/limit for paging.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"0-based start line"},"limit":{"type":"integer"}},"required":["path"]}
    },
    .{ .name = "glob", .description = "List files matching a glob pattern (** crosses directories, * stays within one).", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}
    },
    .{ .name = "grep", .description = "Literal substring search across repository text files.", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"subdirectory to search"}},"required":["pattern"]}
    },
    .{ .name = "edit", .description = "Replace exactly one occurrence of old_string with new_string in a file. Refuses if the text appears zero or multiple times.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}
    },
    .{ .name = "write", .description = "Create a file or overwrite it entirely. Prefer edit for existing files.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    },
    .{ .name = "bash", .description = "Run a shell command with the user's shell. Read-only commands run freely; anything that changes state requires approval. Use background for long-running commands and poll them with the exec tool.", .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string"},"background":{"type":"boolean","description":"start detached and return an execution id"},"timeout_s":{"type":"integer","description":"wall-clock limit in seconds, capped by the session limit"}},"required":["command"]}
    },
    .{ .name = "skill", .description = "Load a named skill's full instructions from the installed skills catalog.", .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    },
    .{ .name = "mcp_list", .description = "List configured MCP servers and their tools.", .parameters_json =
    \\{"type":"object","properties":{}}
    },
    .{ .name = "mcp_describe", .description = "Show an MCP tool's description and input schema. Use it before mcp_call when the arguments are unclear.", .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"}},"required":["server","tool"]}
    },
    .{ .name = "mcp_call", .description = "Call an MCP server tool. Server/tool must be permitted; calls require approval unless allowlisted.", .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"},"arguments":{"type":"object"}},"required":["server","tool"]}
    },
    .{ .name = "agent", .description = "Delegate a self-contained task to a child agent. Roles: research (read-only), implement (may edit), review (read-only findings). The child works independently and returns a summary; its full report is stored under .ifnh/reports/.", .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string"},"role":{"type":"string","enum":["research","implement","review"]},"model":{"type":"string"}},"required":["task","role"]}
    },
    .{ .name = "exec", .description = "Manage background executions: status/output/stop/list by execution id.", .parameters_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["status","output","stop","list"]},"id":{"type":"integer"}},"required":["action"]}
    },
    .{ .name = "read_tool_result", .description = "Read a stored oversized tool output artifact by id, with optional offset/limit paging.", .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["id"]}
    },
    .{ .name = "git", .description = "Run a git subcommand in the workspace (porcelain operations only).", .parameters_json =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}}},"required":["args"]}
    },
};

// ---------------------------------------------------------------- helpers

fn truncateUtf8(arena: std.mem.Allocator, text: []const u8, marker: []const u8) ![]const u8 {
    if (text.len <= max_tool_output_bytes) return text;
    var end = max_tool_output_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\n...[{s}: {d} bytes truncated]\n", .{ text[0..end], marker, text.len - end });
}

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ToolResult {
    const msg = std.fmt.allocPrint(arena, "error: " ++ fmt, args) catch "error: out of memory";
    return .{ .output = msg, .status = .failed };
}

fn deniedResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ToolResult {
    const msg = std.fmt.allocPrint(arena, "permission denied: " ++ fmt, args) catch "permission denied";
    return .{ .output = msg, .status = .denied };
}

const Args = struct {
    obj: std.json.ObjectMap,

    fn str(self: Args, key: []const u8) ?[]const u8 {
        const v = self.obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn int(self: Args, key: []const u8) ?usize {
        const v = self.obj.get(key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0) @as(usize, @intCast(i)) else null,
            else => null,
        };
    }
};

/// Dispatch a tool call by name. `args_json` must be a JSON object.
pub fn execute(name: []const u8, args_json: []const u8, ctx: *ToolContext) ToolResult {
    const V = std.json.Value;
    const args: V = std.json.parseFromSliceLeaky(V, ctx.arena, args_json, .{}) catch
        return errResult(ctx.arena, "invalid JSON arguments", .{});
    if (args != .object) return errResult(ctx.arena, "arguments must be a JSON object", .{});
    const a = Args{ .obj = args.object };

    if (std.mem.eql(u8, name, "read")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "read: missing path", .{});
        return toolRead(path, a.int("offset"), a.int("limit"), ctx);
    } else if (std.mem.eql(u8, name, "glob")) {
        const pattern = a.str("pattern") orelse return errResult(ctx.arena, "glob: missing pattern", .{});
        return toolGlob(pattern, ctx);
    } else if (std.mem.eql(u8, name, "grep")) {
        const pattern = a.str("pattern") orelse return errResult(ctx.arena, "grep: missing pattern", .{});
        const root = a.str("path") orelse "";
        return toolGrep(pattern, root, ctx);
    } else if (std.mem.eql(u8, name, "edit")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "edit: missing path", .{});
        const old_s = a.str("old_string") orelse return errResult(ctx.arena, "edit: missing old_string", .{});
        const new_s = a.str("new_string") orelse return errResult(ctx.arena, "edit: missing new_string", .{});
        return toolEdit(path, old_s, new_s, ctx);
    } else if (std.mem.eql(u8, name, "write")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "write: missing path", .{});
        const content = a.str("content") orelse return errResult(ctx.arena, "write: missing content", .{});
        return toolWrite(path, content, ctx);
    } else if (std.mem.eql(u8, name, "bash")) {
        const command = a.str("command") orelse return errResult(ctx.arena, "bash: missing command", .{});
        const background = if (a.obj.get("background")) |b| (b == .bool and b.bool) else false;
        const timeout_s: u32 = blk: {
            const v = a.obj.get("timeout_s") orelse break :blk 0;
            if (v != .integer or v.integer <= 0 or v.integer > 86_400) break :blk 0;
            break :blk @intCast(v.integer);
        };
        return toolBash(command, background, timeout_s, ctx);
    } else if (std.mem.eql(u8, name, "skill")) {
        const load_fn = ctx.skill_load_fn orelse
            return errResult(ctx.arena, "skill: skills not available", .{});
        const skill_name = a.str("name") orelse return errResult(ctx.arena, "skill: missing name", .{});
        const body = load_fn(ctx.skill_ctx orelse ctx.approval_ctx, ctx.arena, skill_name) orelse
            return errResult(ctx.arena, "skill: '{s}' not found in catalog", .{skill_name});
        return .{ .output = body, .status = .ok };
    } else if (std.mem.eql(u8, name, "exec")) {
        const query_fn = ctx.exec_query_fn orelse
            return errResult(ctx.arena, "exec: background executions not available", .{});
        const action = a.str("action") orelse return errResult(ctx.arena, "exec: missing action", .{});
        var id_buf: [32]u8 = undefined;
        var id_str: []const u8 = "";
        if (a.obj.get("id")) |idv| {
            switch (idv) {
                .integer => |n| id_str = std.fmt.bufPrint(&id_buf, "{d}", .{n}) catch "",
                .string => |s| id_str = s,
                else => {},
            }
        }
        return .{ .output = query_fn(ctx.exec_ctx orelse ctx.approval_ctx, ctx.arena, action, id_str), .status = .ok };
    } else if (std.mem.eql(u8, name, "read_tool_result")) {
        const artifact_id = a.str("id") orelse return errResult(ctx.arena, "read_tool_result: missing id", .{});
        return toolReadResult(artifact_id, a.int("offset"), a.int("limit"), ctx);
    } else if (std.mem.eql(u8, name, "mcp_list")) {
        const list_fn = ctx.mcp_list_fn orelse
            return errResult(ctx.arena, "mcp_list: MCP not configured", .{});
        return .{ .output = list_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena), .status = .ok };
    } else if (std.mem.eql(u8, name, "mcp_describe")) {
        const describe_fn = ctx.mcp_describe_fn orelse
            return errResult(ctx.arena, "mcp_describe: MCP not configured", .{});
        const server = a.str("server") orelse return errResult(ctx.arena, "mcp_describe: missing server", .{});
        const mcp_tool = a.str("tool") orelse return errResult(ctx.arena, "mcp_describe: missing tool", .{});
        const out = describe_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena, server, mcp_tool);
        return .{ .output = out, .status = if (std.mem.startsWith(u8, out, "error:")) .failed else .ok };
    } else if (std.mem.eql(u8, name, "mcp_call")) {
        const call_fn = ctx.mcp_call_fn orelse
            return errResult(ctx.arena, "mcp_call: MCP not configured", .{});
        const server = a.str("server") orelse return errResult(ctx.arena, "mcp_call: missing server", .{});
        const mcp_tool = a.str("tool") orelse return errResult(ctx.arena, "mcp_call: missing tool", .{});
        var arguments_json: []const u8 = "{}";
        if (a.obj.get("arguments")) |av| {
            var aw: std.Io.Writer.Allocating = .init(ctx.arena);
            std.json.Stringify.value(av, .{}, &aw.writer) catch {};
            arguments_json = aw.written();
        }
        switch (ctx.engine.decide(.{ .mcp = .{ .server = server, .tool = mcp_tool } })) {
            .allow => {},
            .deny => return deniedResult(ctx.arena, "mcp {s}.{s}", .{ server, mcp_tool }),
            .ask => {
                const label = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ server, mcp_tool }) catch "?";
                if (!ctx.requestApproval("call MCP tool", label, .none))
                    return deniedResult(ctx.arena, "mcp {s}.{s} (declined)", .{ server, mcp_tool });
            },
        }
        const out = call_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena, server, mcp_tool, arguments_json);
        return .{ .output = out, .status = .ok };
    } else if (std.mem.eql(u8, name, "agent")) {
        const spawn_fn = ctx.agent_spawn_fn orelse
            return errResult(ctx.arena, "agent: delegation disabled", .{});
        const res = spawn_fn(ctx.agent_spawn_ctx orelse ctx.approval_ctx, ctx.arena, ctx.agent_depth, args_json);
        return .{
            .output = res.summary,
            .status = if (res.status == .completed) .ok else .failed,
        };
    } else if (std.mem.eql(u8, name, "git")) {
        const args_v = a.obj.get("args") orelse return errResult(ctx.arena, "git: missing args", .{});
        if (args_v != .array) return errResult(ctx.arena, "git: args must be an array of strings", .{});
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        argv.append(ctx.arena, "git") catch return errResult(ctx.arena, "oom", .{});
        for (args_v.array.items) |item| {
            if (item != .string) return errResult(ctx.arena, "git: args must be strings", .{});
            argv.append(ctx.arena, item.string) catch return errResult(ctx.arena, "oom", .{});
        }
        return toolGit(argv.items, ctx);
    }
    return errResult(ctx.arena, "unknown tool '{s}'", .{name});
}

// ---------------------------------------------------------------- read

/// `.env` / `.env.*` hold credentials; reads are gated by
/// `permissions.read_dotenv` (A-T07).
fn isDotenvPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, ".env") or std.mem.startsWith(u8, base, ".env.");
}

fn toolRead(path: []const u8, offset: ?usize, limit: ?usize, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, path)) {
        .allow => {},
        .ask => return deniedResult(ctx.arena, "read '{s}' not covered by read policy", .{path}),
        .deny => return deniedResult(ctx.arena, "read '{s}'", .{path}),
    }
    if (!ctx.engine.read_dotenv and isDotenvPath(path)) {
        return deniedResult(ctx.arena, "read '{s}' (permissions.read_dotenv is false)", .{path});
    }
    const stat = ctx.workspace.statFile(ctx.io, path, .{}) catch
        return errResult(ctx.arena, "read: cannot stat '{s}'", .{path});
    if (stat.kind == .directory) return errResult(ctx.arena, "read: '{s}' is a directory", .{path});

    const cap = ctx.max_file_read_bytes;
    const data = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(cap)) catch |err| switch (err) {
        error.StreamTooLong => return errResult(ctx.arena, "read: '{s}' exceeds {d} byte cap; use offset/limit paging", .{ path, cap }),
        else => return errResult(ctx.arena, "read: cannot read '{s}': {s}", .{ path, @errorName(err) }),
    };

    const start_line: usize = offset orelse 0;
    var max_lines: usize = limit orelse 2000;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (max_lines == 0) {
            // Only mention truncation when real content remains.
            var more = false;
            if (line.len > 0) more = true else {
                var rest = it;
                while (rest.next()) |l2| {
                    if (l2.len > 0) {
                        more = true;
                        break;
                    }
                }
            }
            if (more) out.appendSlice(ctx.arena, "...[more lines; call read again with offset]") catch {};
            break;
        }
        out.print(ctx.arena, "{d: >6}| {s}\n", .{ line_no + 1, std.mem.trimEnd(u8, line, "\r") }) catch {};
        max_lines -= 1;
    }
    const body = truncateUtf8(ctx.arena, out.items, "read output truncated") catch out.items;
    return .{ .output = body, .status = .ok };
}

// ---------------------------------------------------------------- filesystem walk

const WalkLimits = struct {
    max_files: usize = 20_000,
    max_depth: usize = 16,
    max_matches: usize = 500,
};

const skip_dirs = [_][]const u8{
    ".git",        "node_modules", "zig-cache", "zig-out", ".ifnh/sessions",
    ".ifnh/cache", "__pycache__",  "target",    "dist",    "build",
};

fn shouldSkipDir(rel: []const u8) bool {
    for (skip_dirs) |sd| {
        if (std.mem.eql(u8, rel, sd)) return true;
        if (std.mem.endsWith(u8, rel, sd) and
            (rel.len == sd.len or rel[rel.len - sd.len - 1] == '/')) return true;
    }
    return false;
}

fn collectMatching(
    ctx: *ToolContext,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: usize,
    limits: *WalkLimits,
    out: *std.ArrayListUnmanaged([]const u8),
    pattern: []const u8,
) void {
    if (depth > limits.max_depth or out.items.len >= limits.max_matches or limits.max_files == 0) return;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (out.items.len >= limits.max_matches or limits.max_files == 0) return;
        const child_rel = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ rel_prefix, entry.name }) catch return;
        limits.max_files -|= 1;
        if (entry.kind == .directory) {
            if (shouldSkipDir(child_rel)) continue;
            const sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(ctx.io);
            const next_prefix = std.fmt.allocPrint(ctx.arena, "{s}/", .{child_rel}) catch return;
            collectMatching(ctx, sub, next_prefix, depth + 1, limits, out, pattern);
        } else if (globm.match(pattern, child_rel)) {
            out.append(ctx.arena, child_rel) catch return;
        }
    }
}

fn toolGlob(pattern: []const u8, ctx: *ToolContext) ToolResult {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var limits = WalkLimits{};
    collectMatching(ctx, ctx.workspace, "", 0, &limits, &out, pattern);
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    const body = std.mem.join(ctx.arena, "\n", out.items) catch return errResult(ctx.arena, "oom", .{});
    return .{ .output = truncateUtf8(ctx.arena, body, "glob results") catch body, .status = .ok };
}

// ---------------------------------------------------------------- grep

fn toolGrep(pattern: []const u8, root: []const u8, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, root)) {
        .allow => {},
        else => return deniedResult(ctx.arena, "grep under '{s}'", .{root}),
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var limits = WalkLimits{ .max_matches = 200 };
    grepDir(ctx, ctx.workspace, root, pattern, &limits, &out, 0);
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    return .{ .output = truncateUtf8(ctx.arena, out.items, "grep results") catch out.items, .status = .ok };
}

fn grepDir(
    ctx: *ToolContext,
    dir: std.Io.Dir,
    rel: []const u8,
    pattern: []const u8,
    limits: *WalkLimits,
    out: *std.ArrayListUnmanaged(u8),
    depth: usize,
) void {
    if (depth > limits.max_depth or limits.max_matches == 0 or limits.max_files == 0) return;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (limits.max_matches == 0 or limits.max_files == 0) return;
        const child_rel = if (rel.len == 0)
            std.fmt.allocPrint(ctx.arena, "{s}", .{entry.name}) catch return
        else
            std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ rel, entry.name }) catch return;
        limits.max_files -|= 1;
        if (entry.kind == .directory) {
            if (shouldSkipDir(child_rel)) continue;
            const sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(ctx.io);
            grepDir(ctx, sub, child_rel, pattern, limits, out, depth + 1);
        } else {
            grepFile(ctx, child_rel, pattern, limits, out);
        }
    }
}

/// Longest grep line that is buffered and matched. Longer lines are matched
/// on this prefix and the remainder is discarded without being buffered.
const max_grep_line_bytes: usize = 8 * 1024;

fn grepLineHit(
    ctx: *ToolContext,
    rel: []const u8,
    line_no: usize,
    line: []const u8,
    pattern: []const u8,
    limits: *WalkLimits,
    out: *std.ArrayListUnmanaged(u8),
    file_hits: *usize,
) bool {
    if (file_hits.* >= 10 or limits.max_matches == 0) return false;
    if (std.mem.indexOf(u8, line, pattern) != null) {
        out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, std.mem.trimEnd(u8, line, "\r") }) catch return false;
        file_hits.* += 1;
        limits.max_matches -= 1;
    }
    return true;
}

/// Accept a valid UTF-8 buffer, or one whose final code point was cut by the
/// line cap. Used only for truncated overlong lines.
fn isTruncatedUtf8(data: []const u8) bool {
    if (std.unicode.utf8ValidateSlice(data)) return true;
    var end = data.len;
    var trimmed: usize = 0;
    while (trimmed < 3 and end > 0) : (trimmed += 1) {
        end -= 1;
        if (std.unicode.utf8ValidateSlice(data[0..end])) return true;
    }
    return false;
}

const DiscardResult = enum { newline, eof, failed };

/// Discard the rest of an overlong line without buffering it.
fn discardGrepLine(r: *std.Io.Reader) DiscardResult {
    while (true) {
        _ = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                r.tossBuffered();
                continue;
            },
            error.EndOfStream => {
                r.tossBuffered();
                return .eof;
            },
            error.ReadFailed => return .failed,
        };
        return .newline;
    }
}

fn grepRollback(out: *std.ArrayListUnmanaged(u8), out_start: usize, limits: *WalkLimits, matches_start: usize) void {
    out.shrinkRetainingCapacity(out_start);
    limits.max_matches = matches_start;
}

fn grepFile(ctx: *ToolContext, rel: []const u8, pattern: []const u8, limits: *WalkLimits, out: *std.ArrayListUnmanaged(u8)) void {
    if (!ctx.engine.read_dotenv and isDotenvPath(rel)) return;
    const file = ctx.workspace.openFile(ctx.io, rel, .{}) catch return;
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return;
    if (stat.size > max_file_size_bytes) return;

    const out_start = out.items.len;
    const matches_start = limits.max_matches;
    var file_hits: usize = 0;
    var line_no: usize = 0;
    var saw_line = false;
    var ended_newline = false;
    var buf: [max_grep_line_bytes]u8 = undefined;
    var file_reader = file.reader(ctx.io, &buf);
    const r = &file_reader.interface;

    while (true) {
        if (file_hits >= 10 or limits.max_matches == 0) return;
        const maybe_line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const buffered = r.buffered();
                const line = buffered[0..@min(buffered.len, max_grep_line_bytes)];
                r.tossBuffered();
                if (!isTruncatedUtf8(line)) {
                    grepRollback(out, out_start, limits, matches_start);
                    return;
                }
                if (!grepLineHit(ctx, rel, line_no, line, pattern, limits, out, &file_hits)) return;
                saw_line = true;
                line_no += 1;
                switch (discardGrepLine(r)) {
                    .newline => {
                        ended_newline = true;
                        continue;
                    },
                    .eof => return,
                    .failed => return,
                }
            },
            error.EndOfStream => {
                const rest = r.buffered();
                if (rest.len == 0) {
                    // splitScalar semantics: a file ending in a newline (or an
                    // empty file) has one final empty line.
                    if (!saw_line or ended_newline) {
                        _ = grepLineHit(ctx, rel, line_no, "", pattern, limits, out, &file_hits);
                    }
                    return;
                }
                r.tossBuffered();
                if (!std.unicode.utf8ValidateSlice(rest)) {
                    grepRollback(out, out_start, limits, matches_start);
                    return;
                }
                _ = grepLineHit(ctx, rel, line_no, rest, pattern, limits, out, &file_hits);
                return;
            },
            error.ReadFailed => return,
        };
        const line = if (maybe_line.len > 0 and maybe_line[maybe_line.len - 1] == '\n')
            maybe_line[0 .. maybe_line.len - 1]
        else
            maybe_line;
        if (!std.unicode.utf8ValidateSlice(line)) {
            grepRollback(out, out_start, limits, matches_start);
            return;
        }
        if (!grepLineHit(ctx, rel, line_no, line, pattern, limits, out, &file_hits)) return;
        saw_line = true;
        ended_newline = true;
        line_no += 1;
    }
}

// ---------------------------------------------------------------- edit / write

fn prepareWrite(ctx: *ToolContext, path: []const u8, after: []const u8) ?ToolResult {
    switch (ctx.engine.decidePath(.write, path)) {
        .allow => {},
        .ask => {
            if (!ctx.requestApproval("write file", path, .{ .path_write = path })) return deniedResult(ctx.arena, "write '{s}' (declined)", .{path});
        },
        .deny => return deniedResult(ctx.arena, "write '{s}' (protected path)", .{path}),
    }
    _ = after;
    return null;
}

fn toolEdit(path: []const u8, old_string: []const u8, new_string: []const u8, ctx: *ToolContext) ToolResult {
    if (old_string.len == 0) return errResult(ctx.arena, "edit: old_string must not be empty", .{});
    if (prepareWrite(ctx, path, new_string)) |r| return r;

    const before = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(max_file_size_bytes)) catch
        return errResult(ctx.arena, "edit: cannot read '{s}'", .{path});

    const first = std.mem.indexOf(u8, before, old_string) orelse
        return errResult(ctx.arena, "edit: old_string not found in '{s}' (file may have changed; re-read it)", .{path});
    if (std.mem.indexOf(u8, before[first + 1 ..], old_string) != null)
        return errResult(ctx.arena, "edit: old_string appears multiple times in '{s}'; provide a larger unique context", .{path});

    const after = std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{
        before[0..first],
        new_string,
        before[first + old_string.len ..],
    }) catch return errResult(ctx.arena, "oom", .{});

    commitMutation(ctx, path, before, after) catch |err|
        return errResult(ctx.arena, "edit: failed to write '{s}': {s}", .{ path, @errorName(err) });
    return .{ .output = std.fmt.allocPrint(ctx.arena, "edited {s} ({d} -> {d} bytes)", .{ path, before.len, after.len }) catch "edited", .status = .ok };
}

fn toolWrite(path: []const u8, content: []const u8, ctx: *ToolContext) ToolResult {
    if (prepareWrite(ctx, path, content)) |r| return r;

    const existing = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(max_file_size_bytes)) catch null;
    if (existing) |before| {
        commitMutation(ctx, path, before, content) catch |err|
            return errResult(ctx.arena, "write: failed '{s}': {s}", .{ path, @errorName(err) });
    } else {
        commitMutation(ctx, path, "", content) catch |err|
            return errResult(ctx.arena, "write: failed '{s}': {s}", .{ path, @errorName(err) });
    }
    return .{ .output = std.fmt.allocPrint(ctx.arena, "wrote {s} ({d} bytes)", .{ path, content.len }) catch "wrote", .status = .ok };
}

/// Journal-integrated file mutation: intent → write → commit.
fn commitMutation(ctx: *ToolContext, path: []const u8, before: []const u8, after: []const u8) !void {
    const j = ctx.journal orelse {
        // No journal (e.g. outside a session): write directly.
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try ctx.workspace.createDirPath(ctx.io, path[0..slash]);
        }
        try ctx.workspace.writeFile(ctx.io, .{ .sub_path = path, .data = after });
        return;
    };
    const exists = blk: {
        _ = ctx.workspace.statFile(ctx.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists) {
        try j.apply("file-mutation", &.{.{ .write = .{ .path = path, .before = before, .after = after } }});
    } else {
        try j.apply("file-mutation", &.{.{ .create = .{ .path = path, .after = after } }});
    }
}

// ---------------------------------------------------------------- artifacts

fn storeArtifact(ctx: *ToolContext, data: []const u8) []const u8 {
    var id_buf: [16]u8 = undefined;
    var rand_bytes: [8]u8 = undefined;
    ctx.io.random(&rand_bytes);
    const id = std.fmt.bufPrint(&id_buf, "a{x}", .{std.mem.readInt(u64, &rand_bytes, .little)}) catch return "";
    const rel = std.fmt.allocPrint(ctx.arena, ".ifnh/cache/artifacts/{s}.txt", .{id}) catch return "";
    ctx.workspace.createDirPath(ctx.io, ".ifnh/cache/artifacts") catch return "";
    ctx.workspace.writeFile(ctx.io, .{ .sub_path = rel, .data = data }) catch return "";
    return std.fmt.allocPrint(ctx.arena, "full output stored as artifact id {s} (read with read_tool_result)", .{id}) catch "";
}

fn toolReadResult(id: []const u8, offset: ?usize, limit: ?usize, ctx: *ToolContext) ToolResult {
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c)) return errResult(ctx.arena, "read_tool_result: invalid id", .{});
    }
    switch (ctx.engine.decidePath(.read, ".ifnh/cache/artifacts")) {
        .allow => {},
        else => return deniedResult(ctx.arena, "read artifact '{s}'", .{id}),
    }
    const rel = std.fmt.allocPrint(ctx.arena, ".ifnh/cache/artifacts/{s}.txt", .{id}) catch
        return errResult(ctx.arena, "oom", .{});
    const data = ctx.workspace.readFileAlloc(ctx.io, rel, ctx.arena, .limited(4 * 1024 * 1024)) catch
        return errResult(ctx.arena, "read_tool_result: artifact '{s}' not found", .{id});

    const start_line: usize = offset orelse 0;
    var max_lines: usize = limit orelse 400;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (max_lines == 0) {
            out.appendSlice(ctx.arena, "...[more lines; increase offset]") catch {};
            break;
        }
        out.appendSlice(ctx.arena, line) catch {};
        out.append(ctx.arena, '\n') catch {};
        max_lines -= 1;
    }
    return .{ .output = out.items, .status = .ok };
}

// ---------------------------------------------------------------- bash / git

fn runCaptured(ctx: *ToolContext, argv: []const []const u8, cwd: []const u8) ToolResult {
    // Windows has no POSIX process groups; keep the std helper there.
    if (builtin.os.tag == .windows) return runCapturedWindows(ctx, argv, cwd);

    const limit_s: u32 = if (ctx.timeout_s == 0) 120 else ctx.timeout_s;
    // Own process group (pgid = 0) so a cancel or timeout signals the whole
    // tree, not just the direct child (A-T06).
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| switch (err) {
        error.FileNotFound => return errResult(ctx.arena, "command not found: {s}", .{argv[0]}),
        else => return errResult(ctx.arena, "spawn failed: {s}", .{@errorName(err)}),
    };

    const deadline = std.Io.Clock.Timestamp.fromNow(ctx.io, .{
        .raw = .fromSeconds(@intCast(limit_s)),
        .clock = .awake,
    });

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    var fds = [_]std.posix.pollfd{
        .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var open = [2]bool{ true, true };
    var cancelled = false;
    var timed_out = false;
    var overflow = false;
    var buf: [8192]u8 = undefined;

    read_loop: while (open[0] or open[1]) {
        if (ctx.cancel) |cancel| {
            if (cancel.load(.acquire)) {
                cancelled = true;
                break :read_loop;
            }
        }
        const remaining_ns = deadline.durationFromNow(ctx.io).raw.nanoseconds;
        if (remaining_ns <= 0) {
            timed_out = true;
            break :read_loop;
        }
        // Short slices keep the cancel flag responsive during long commands.
        const wait_ms: i32 = @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), 100));
        const ready = std.posix.poll(&fds, wait_ms) catch break :read_loop;
        if (ready == 0) continue;
        for (0..2) |i| {
            if (!open[i]) continue;
            const revents = fds[i].revents;
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) == 0) continue;
            const got = std.posix.read(fds[i].fd, &buf) catch 0;
            if (got == 0) {
                open[i] = false;
                continue;
            }
            if (stdout.items.len + stderr.items.len + got > max_tool_output_bytes) {
                overflow = true;
                break :read_loop;
            }
            const sink = if (i == 0) &stdout else &stderr;
            sink.appendSlice(ctx.arena, buf[0..got]) catch break :read_loop;
            fds[i].revents = 0;
        }
    }

    if (cancelled or timed_out or overflow) killProcessGroup(ctx, &child);
    const term: std.process.Child.Term = child.wait(ctx.io) catch .{ .unknown = 0 };
    if (cancelled) {
        // Give the caller a chance to journal `.interrupted`; no output is
        // promised for a killed command.
        return .{ .output = "cancelled: command and its process group were terminated", .status = .failed };
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (stdout.items.len > 0) out.print(ctx.arena, "<stdout>\n{s}\n</stdout>\n", .{stdout.items}) catch {};
    if (stderr.items.len > 0) out.print(ctx.arena, "<stderr>\n{s}\n</stderr>\n", .{stderr.items}) catch {};
    if (timed_out) out.print(ctx.arena, "error: command timed out after {d}s (process group terminated)\n", .{limit_s}) catch {};
    if (overflow) out.print(ctx.arena, "error: output exceeded {d} bytes; command terminated\n", .{max_tool_output_bytes}) catch {};
    switch (term) {
        .exited => |code| {
            if (code != 0 and !timed_out and !overflow) out.print(ctx.arena, "exit code: {d}\n", .{code}) catch {};
        },
        .signal => |sig| out.print(ctx.arena, "terminated by signal {d}\n", .{sig}) catch {},
        .stopped => |sig| out.print(ctx.arena, "stopped by signal {d}\n", .{sig}) catch {},
        .unknown => |code| out.print(ctx.arena, "exit status: {d}\n", .{code}) catch {},
    }
    var body = truncateUtf8(ctx.arena, out.items, "command output") catch out.items;
    if (out.items.len > max_tool_output_bytes) {
        const handle = storeArtifact(ctx, out.items);
        body = std.fmt.allocPrint(ctx.arena, "{s}\n{s}", .{ body, handle }) catch body;
    }
    if (timed_out) return .{ .output = body, .status = .timeout };
    const failed = switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
    return .{ .output = body, .status = if (failed or overflow) .failed else .ok };
}

/// Terminate a captured command's process group: TERM first so it can clean
/// up, then KILL to guarantee no grandchild survives a cancel or timeout.
fn killProcessGroup(ctx: *ToolContext, child: *std.process.Child) void {
    const pid = child.id orelse return;
    _ = std.posix.kill(-pid, .TERM) catch {};
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    _ = std.posix.kill(-pid, .KILL) catch {};
}

fn runCapturedWindows(ctx: *ToolContext, argv: []const []const u8, cwd: []const u8) ToolResult {
    const run = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdout_limit = .limited(max_tool_output_bytes),
        .stderr_limit = .limited(32 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(if (ctx.timeout_s == 0) 120 else ctx.timeout_s) } },
    }) catch |err| switch (err) {
        error.Timeout => return .{ .output = "error: command timed out", .status = .timeout },
        error.FileNotFound => return errResult(ctx.arena, "command not found: {s}", .{argv[0]}),
        else => return errResult(ctx.arena, "spawn failed: {s}", .{@errorName(err)}),
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (run.stdout.len > 0) out.print(ctx.arena, "<stdout>\n{s}\n</stdout>\n", .{run.stdout}) catch {};
    if (run.stderr.len > 0) out.print(ctx.arena, "<stderr>\n{s}\n</stderr>\n", .{run.stderr}) catch {};
    switch (run.term) {
        .exited => |code| {
            if (code != 0) out.print(ctx.arena, "exit code: {d}\n", .{code}) catch {};
        },
        .signal => |sig| out.print(ctx.arena, "terminated by signal {d}\n", .{sig}) catch {},
        .stopped => |sig| out.print(ctx.arena, "stopped by signal {d}\n", .{sig}) catch {},
        .unknown => |code| out.print(ctx.arena, "exit status: {d}\n", .{code}) catch {},
    }
    const failed = switch (run.term) {
        .exited => |code| code != 0,
        else => true,
    };
    return .{ .output = out.items, .status = if (failed) .failed else .ok };
}

fn toolBash(command: []const u8, background: bool, timeout_s: u32, ctx: *ToolContext) ToolResult {
    // Permission classification always runs on the raw command string. The
    // command itself always goes through the shell, so quoting, globs,
    // redirection and pipes behave as the model wrote them (A-03).
    const decision = ctx.engine.decideCommand(command);
    switch (decision) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "command '{s}'", .{command}),
        .ask => {
            const grant_prefix = commandPrefixOf(command);
            if (!ctx.requestApproval("run command", command, .{ .command_prefix = grant_prefix }))
                return deniedResult(ctx.arena, "command '{s}' (declined)", .{command});
        },
    }

    if (background) {
        switch (ctx.engine.decideCommand(command)) {
            .allow, .ask => {
                if (ctx.engine.decideCommand(command) == .ask) {
                    if (!ctx.requestApproval("run command (background)", command, .{ .command_prefix = commandPrefixOf(command) }))
                        return deniedResult(ctx.arena, "command '{s}' (declined)", .{command});
                }
                const start_fn = ctx.exec_start_fn orelse
                    return errResult(ctx.arena, "bash: background executions not available", .{});
                return .{ .output = start_fn(ctx.exec_ctx orelse ctx.approval_ctx, ctx.arena, command), .status = .ok };
            },
            .deny => return deniedResult(ctx.arena, "command '{s}'", .{command}),
        }
    }

    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return errResult(ctx.arena, "bash: empty command", .{});

    // A per-call timeout may only tighten the session ceiling.
    var local = ctx.*;
    if (timeout_s > 0) local.timeout_s = @min(timeout_s, if (ctx.timeout_s == 0) 120 else ctx.timeout_s);

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    // Note: shell side effects are not journaled (M185); surfaced in audit log instead.
    return runCaptured(&local, &argv, "");
}

/// "git commit -m x" -> "git commit"; "ls" -> "ls".
fn commandPrefixOf(command: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = it.next() orelse return command;
    const second = it.next() orelse return first;
    const start = second.ptr - command.ptr;
    return command[0 .. start + second.len];
}

fn toolGit(argv: []const []const u8, ctx: *ToolContext) ToolResult {
    // Reconstruct command line for classification/permission.
    const command = std.mem.join(ctx.arena, " ", argv) catch return errResult(ctx.arena, "oom", .{});
    switch (ctx.engine.decideCommand(command)) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "git command '{s}'", .{command}),
        .ask => {
            const grant_prefix = commandPrefixOf(command);
            if (!ctx.requestApproval("run git", command, .{ .command_prefix = grant_prefix }))
                return deniedResult(ctx.arena, "git command '{s}' (declined)", .{command});
        },
    }
    return runCaptured(ctx, argv, "");
}

// ---------------------------------------------------------------- tests

fn testCtx(arena: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, e: *engine_mod.Engine) ToolContext {
    return .{
        .io = io,
        .arena = arena,
        .workspace = ws,
        .engine = e,
        .journal = null,
        .max_file_read_bytes = 256 * 1024,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
                return .approved_once;
            }
        }.approve,
    };
}

fn makeTmp() !std.testing.TmpDir {
    return std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
}

test "read tool with line numbers and paging" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\ngamma\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("read", "{\"path\":\"f.txt\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "1| alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "3| gamma") != null);

    const r2 = execute("read", "{\"path\":\"f.txt\",\"offset\":1,\"limit\":1}", &ctx);
    try std.testing.expectEqualStrings("     2| beta\n...[more lines; call read again with offset]", r2.output);

    const r3 = execute("read", "{\"path\":\"missing.txt\"}", &ctx);
    try std.testing.expectEqual(Status.failed, r3.status);
}

test "glob and grep tools" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const needle = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/b.zig", .data = "const needle = 2;\nconst other = 3;\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const g = execute("glob", "{\"pattern\":\"src/**/*.zig\"}", &ctx);
    try std.testing.expectEqual(Status.ok, g.status);
    try std.testing.expect(std.mem.indexOf(u8, g.output, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.output, "src/deep/b.zig") != null);

    const gr = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, gr.status);
    try std.testing.expect(std.mem.indexOf(u8, gr.output, "src/a.zig:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, gr.output, "src/deep/b.zig:1") != null);
}

test "edit and write with journal integration" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "code.zig", .data = "const x = 1;\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const w = execute("write", "{\"path\":\"new.txt\",\"content\":\"hello new\\n\"}", &ctx);
    try std.testing.expectEqual(Status.ok, w.status);

    const r = execute("edit", "{\"path\":\"code.zig\",\"old_string\":\"const x = 1;\",\"new_string\":\"const x = 2;\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    const data = try tmp.dir.readFileAlloc(io, "code.zig", arena_state.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("const x = 2;\n", data);

    // Ambiguity refused.
    try tmp.dir.writeFile(io, .{ .sub_path = "dup.txt", .data = "aa aa" });
    const dup = execute("edit", "{\"path\":\"dup.txt\",\"old_string\":\"aa\",\"new_string\":\"bb\"}", &ctx);
    try std.testing.expectEqual(Status.failed, dup.status);
    try std.testing.expect(std.mem.indexOf(u8, dup.output, "multiple times") != null);

    // Staleness refused.
    const stale = execute("edit", "{\"path\":\"code.zig\",\"old_string\":\"const x = 1;\",\"new_string\":\"zz\"}", &ctx);
    try std.testing.expectEqual(Status.failed, stale.status);
    try std.testing.expect(std.mem.indexOf(u8, stale.output, "not found") != null);
}

test "write denied on protected path without approval escape" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("write", "{\"path\":\".ifnh/config.json\",\"content\":\"{}\"}", &ctx);
    try std.testing.expectEqual(Status.denied, r.status);
}

test "bash tool runs read-only commands without approval" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("bash", "{\"command\":\"echo hello-ifnh\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hello-ifnh") != null);
}

test "bash tool asks for write commands and honors denial" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    const Denier = struct {
        fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied;
        }
    };
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.approval_fn = Denier.approve;

    const r = execute("bash", "{\"command\":\"mkdir newdir\"}", &ctx);
    try std.testing.expectEqual(Status.denied, r.status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "newdir", .{}));
}

test "read_dotenv gates .env reads" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=1\n" });
    try tmp.dir.createDirPath(io, "config");
    try tmp.dir.writeFile(io, .{ .sub_path = "config/.env.local", .data = "SECRET=2\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    // Default: denied, with the policy key named in the reason.
    const denied = execute("read", "{\"path\":\".env\"}", &ctx);
    try std.testing.expectEqual(Status.denied, denied.status);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "read_dotenv") != null);
    try std.testing.expectEqual(Status.denied, execute("read", "{\"path\":\"config/.env.local\"}", &ctx).status);
    // Ordinary dotfiles are unaffected.
    try std.testing.expectEqualStrings("failed", @tagName(execute("read", "{\"path\":\".gitignore\"}", &ctx).status));

    // Opted in: reads succeed.
    e.read_dotenv = true;
    const allowed = execute("read", "{\"path\":\".env\"}", &ctx);
    try std.testing.expectEqualStrings("ok", @tagName(allowed.status));
    try std.testing.expect(std.mem.indexOf(u8, allowed.output, "SECRET=1") != null);
    const grep_res = execute("grep", "{\"pattern\":\"SECRET\"}", &ctx);
    try std.testing.expectEqualStrings("ok", @tagName(grep_res.status));
    try std.testing.expect(std.mem.indexOf(u8, grep_res.output, ".env:1") != null);
}

test "grep skips dotenv files by default" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET=1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "SECRET=1\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("grep", "{\"pattern\":\"SECRET\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ok.txt:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".env:1") == null);
}

test "grep finds a match late in a large file" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    const line = "x" ** 1023 ++ "\n";
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    while (data.items.len < 900 * 1024) {
        try data.appendSlice(std.testing.allocator, line);
    }
    try data.appendSlice(std.testing.allocator, "needle at the end\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "late.txt", .data = data.items });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "late.txt:901: needle at the end") != null);
}

test "grep discards overlong lines but keeps line numbers" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    const data = "x" ** 9000 ++ "\nneedle\nafter\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "long.txt", .data = data });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqualStrings("long.txt:2: needle\n", r.output);
}

test "grep trims CR and keeps line numbers" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "crlf.txt", .data = "first\r\nneedle\r\nlast needle" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqualStrings("crlf.txt:2: needle\ncrlf.txt:3: last needle\n", r.output);
}

test "git push is denied under the default ceilings" {
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), std.testing.io, std.Io.Dir.cwd(), &e);

    const r = execute("git", "{\"args\":[\"push\",\"origin\",\"main\"]}", &ctx);
    try std.testing.expectEqual(Status.denied, r.status);
    const forced = execute("git", "{\"args\":[\"push\",\"--force\",\"origin\",\"main\"]}", &ctx);
    try std.testing.expectEqual(Status.denied, forced.status);
}

test "bash timeout kills the whole process group" {
    // Probe via raw kill(2) with signal 0; the std SIG enum has no zero tag.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const pid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pid", .{dir_path});
    defer std.testing.allocator.free(pid_path);

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.timeout_s = 1;

    const script = try std.fmt.allocPrint(arena_state.allocator(), "sleep 30 & echo $! > {s}; wait", .{pid_path});
    const r = runCaptured(&ctx, &.{ "/bin/sh", "-c", script }, "");
    try std.testing.expectEqual(Status.timeout, r.status);

    // The grandchild printed its pid; it must not survive the group kill.
    const text = try tmp.dir.readFileAlloc(io, "pid", arena_state.allocator(), .limited(64));
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
    var gone = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        // Signal 0 only probes for existence.
        const rc = std.os.linux.syscall2(.kill, @intCast(pid), 0);
        if (std.os.linux.errno(rc) == .SRCH) {
            gone = true;
            break;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }
    try std.testing.expect(gone);
}

test "unknown tool and bad args" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    try std.testing.expectEqual(Status.failed, execute("frobnicate", "{}", &ctx).status);
    try std.testing.expectEqual(Status.failed, execute("read", "not json", &ctx).status);
    try std.testing.expectEqual(Status.failed, execute("read", "{\"other\":1}", &ctx).status);
}

test "bash passes the raw command through sh -c" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);

    // Quoted arguments with spaces stay single argv entries.
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"command\":");
    try std.json.Stringify.value("printf '%s|' 'a b' \"c d\"", .{}, &aw.writer);
    try aw.writer.writeByte('}');
    const r = execute("bash", aw.written(), &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a b|c d|") != null);

    // Shell expansion is not tokenized away.
    var aw2: std.Io.Writer.Allocating = .init(arena);
    try aw2.writer.writeAll("{\"command\":");
    try std.json.Stringify.value("printf '%s' $((1 + 2))", .{}, &aw2.writer);
    try aw2.writer.writeByte('}');
    const r2 = execute("bash", aw2.written(), &ctx);
    try std.testing.expectEqual(Status.ok, r2.status);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "\n3") != null);
}

test "bash per-call timeout only tightens the session ceiling" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.timeout_s = 1; // session ceiling

    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"command\":\"sleep 30\",\"timeout_s\":60}");
    const start = std.Io.Timestamp.now(io, .awake);
    const r = execute("bash", aw.written(), &ctx);
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds, std.time.ns_per_ms);

    try std.testing.expectEqual(Status.timeout, r.status);
    // A 60 s request was clamped to the 1 s ceiling.
    try std.testing.expect(elapsed_ms < 4000);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "timed out after 1s") != null);
}

test "isReadOnly classifies only workspace readers" {
    try std.testing.expect(isReadOnly("read"));
    try std.testing.expect(isReadOnly("glob"));
    try std.testing.expect(isReadOnly("grep"));
    try std.testing.expect(!isReadOnly("bash"));
    try std.testing.expect(!isReadOnly("write"));
    try std.testing.expect(!isReadOnly("agent"));
}
