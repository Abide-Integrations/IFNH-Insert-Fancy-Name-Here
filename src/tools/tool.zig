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
const search = @import("search.zig");
const diff_mod = @import("../core/diff.zig");
const custom_mod = @import("custom.zig");
const sandbox_mod = @import("../core/sandbox.zig");

/// Data-defined tool from `<workspace>/.ifnh/tools/*.json` (D-02, ADR 0004).
pub const CustomTool = custom_mod.CustomTool;
/// The whole loaded custom-tool set, warnings included.
pub const CustomToolSet = custom_mod.Set;

pub const max_tool_output_bytes: usize = 64 * 1024;
pub const max_file_size_bytes: usize = 1024 * 1024;

pub const Status = enum { ok, denied, failed, timeout };

/// Tools that only read the workspace and never prompt for approval. These
/// may run concurrently as one batch (DECISIONS #58 leadingParallelGroup).
/// Backed by `registry`'s `executor_kind`, so the answer is derived, not a
/// second list. Custom tools (D-02) are never read-only whatever their
/// advisory `permission` class says: they run a shell command, so they are
/// always gated and always dispatched sequentially.
pub fn isReadOnly(name: []const u8) bool {
    const tool = find(name) orelse return false;
    return tool.executor_kind == .read;
}

pub const ApprovalRequest = struct {
    pub const Grant = union(enum) {
        none,
        command_prefix: []const u8,
        path_write: []const u8,
    };

    /// Tool asking ("" when the caller does not know).
    tool: []const u8 = "",
    title: []const u8,
    detail: []const u8, // command line or path
    /// What a session-scope approval should grant.
    grant: Grant = .none,
    /// Unified diff of the change being approved (write/edit); "" otherwise.
    preview: []const u8 = "",
};

/// `approved_project` is "always for this project": the grant is also saved
/// to `.ifnh/permissions.local.json` (C-05).
pub const ApprovalResponse = enum { approved_once, approved_session, approved_project, denied };

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
    /// OS-sandbox hook for model-issued shell commands (E-04; wired by the
    /// host, null disables). Never consulted for `git` or the REPL's `!cmd`.
    sandbox_fn: ?sandbox_mod.WrapFn = null,
    sandbox_ctx: ?*anyopaque = null,
    /// Skill loader hook (wired by the host; null disables the tool).
    skill_load_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 = null,
    skill_ctx: ?*anyopaque = null,
    /// MCP registry hooks (wired by the host; null disables MCP).
    mcp_list_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator) []const u8 = null,
    mcp_call_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) []const u8 = null,
    mcp_describe_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8) []const u8 = null,
    mcp_ctx: ?*anyopaque = null,
    /// Advisory-memory hooks (wired by the host; null disables the
    /// `memory_*` tools, which are then not advertised either).
    memory_recall_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, query: []const u8) []const u8 = null,
    memory_remember_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, text: []const u8) []const u8 = null,
    memory_forget_fn: ?*const fn (ctx: *anyopaque, arena: std.mem.Allocator, id: ?[]const u8) []const u8 = null,
    memory_ctx: ?*anyopaque = null,
    /// Turn cancel flag (A-T06). `runCaptured` kills the child process group
    /// when it flips; null when nothing can cancel.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Wall-clock limit for one captured command (`agents.timeout_tool_s`).
    timeout_s: u32 = 120,
    /// Delegation depth of the agent owning this context (0 = parent).
    agent_depth: usize = 0,
    /// Display label for approval provenance ("parent", "research-1"...).
    agent_label: []const u8 = "",
    /// `tools.external`: prefer `rg`/`fd` when the host allows it. `null`
    /// follows the process-global probe; an explicit value overrides it.
    use_external_tools: ?bool = null,
    /// Per-context view of the process-global `rg`/`fd` probe.
    external_cache: search.ExternalCache = .{},
    /// Custom tools loaded from `.ifnh/tools` for this run (D-02). Empty
    /// disables them; every other tool path is unaffected.
    custom: []const CustomTool = &.{},
    /// Name of the tool currently executing (set by `execute`, read by
    /// approval prompts so they can name it).
    tool_name: []const u8 = "",

    pub fn requestApproval(self: *ToolContext, title: []const u8, detail: []const u8, grant: ApprovalRequest.Grant) bool {
        return self.requestApprovalWithPreview(title, detail, grant, "");
    }

    pub fn requestApprovalWithPreview(self: *ToolContext, title: []const u8, detail: []const u8, grant: ApprovalRequest.Grant, preview: []const u8) bool {
        const resp = self.approval_fn(self.approval_ctx, .{ .tool = self.tool_name, .title = title, .detail = detail, .grant = grant, .preview = preview });
        switch (resp) {
            .approved_once, .approved_session, .approved_project => return true,
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

/// What a tool does to the workspace; drives read-only batching and
/// advertisement metadata (DESIGN §3.2).
pub const ExecutorKind = enum { read, write, exec, git };

/// Deviation from DESIGN §3.2: the sketched signature
/// `call_fn(ctx, alloc, io, input) anyerror!ToolResult` predates this shell, and
/// the allocator, the `std.Io` and the raw argument JSON already reach every
/// executor through `ToolContext`/`Args`, so folding them in keeps one call
/// shape without rewriting fourteen executors for an error union none of them
/// uses.
pub const CallFn = *const fn (ctx: *ToolContext, args: *const Args) ToolResult;

/// One dispatchable tool. `parameters_json` is the JSON Schema string sent to
/// the model; `call_fn` owns all argument validation for its tool.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    executor_kind: ExecutorKind,
    call_fn: CallFn,
};

/// Every builtin tool, in advertisement order. Dispatch (`find`), the model's
/// tool list (`specs`) and read-only classification (`isReadOnly`) all read
/// this one table, so they cannot drift apart.
pub const registry = [_]Tool{
    .{ .name = "read", .description = "Read a text file with line numbers. Supports offset/limit for paging.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"0-based start line"},"limit":{"type":"integer"}},"required":["path"]}
    , .executor_kind = .read, .call_fn = execRead },
    .{ .name = "glob", .description = "List files matching a glob pattern (** crosses directories, * stays within one). Respects .gitignore and skips hidden entries.", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}
    , .executor_kind = .read, .call_fn = execGlob },
    .{ .name = "grep", .description = "Regex search across text files (literals, ., *, +, ?, [...], ^, $). Respects .gitignore; skips hidden and binary files.", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"subdirectory to search"}},"required":["pattern"]}
    , .executor_kind = .read, .call_fn = execGrep },
    .{ .name = "edit", .description = "Replace exactly one occurrence of old_string with new_string in a file. Refuses if the text appears zero or multiple times. Set replace_all to replace every occurrence. Pass edits (an array of {old_string,new_string,replace_all}) instead of old_string/new_string to apply several edits atomically in one write: all must match or the file is unchanged. If old_string has no exact match, a unique match ignoring per-line leading/trailing whitespace and space/tab run lengths is used instead (new_string is inserted verbatim, replacing whole lines).", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","description":"replace every exact occurrence (default false)"},"edits":{"type":"array","description":"atomic multi-edit, applied in order; exclusive with old_string/new_string","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["old_string","new_string"]}}},"required":["path"]}
    , .executor_kind = .write, .call_fn = execEdit },
    .{ .name = "write", .description = "Create a file or overwrite it entirely. Prefer edit for existing files.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    , .executor_kind = .write, .call_fn = execWrite },
    .{ .name = "bash", .description = "Run a shell command with the user's shell. Read-only commands run freely; anything that changes state requires approval. Use background for long-running commands and poll them with the exec tool.", .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string"},"background":{"type":"boolean","description":"start detached and return an execution id"},"timeout_s":{"type":"integer","description":"wall-clock limit in seconds, capped by the session limit"}},"required":["command"]}
    , .executor_kind = .exec, .call_fn = execBash },
    .{ .name = "skill", .description = "Load a named skill's full instructions from the installed skills catalog.", .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    , .executor_kind = .exec, .call_fn = execSkill },
    .{ .name = "mcp_list", .description = "List configured MCP servers and their tools.", .parameters_json =
    \\{"type":"object","properties":{}}
    , .executor_kind = .exec, .call_fn = execMcpList },
    .{ .name = "mcp_describe", .description = "Show an MCP tool's description and input schema. Use it before mcp_call when the arguments are unclear.", .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"}},"required":["server","tool"]}
    , .executor_kind = .exec, .call_fn = execMcpDescribe },
    .{ .name = "mcp_call", .description = "Call an MCP server tool. Server/tool must be permitted; calls require approval unless allowlisted.", .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"},"arguments":{"type":"object"}},"required":["server","tool"]}
    , .executor_kind = .exec, .call_fn = execMcpCall },
    .{ .name = "agent", .description = "Delegate a self-contained task to a child agent. Roles: research (read-only), implement (may edit), review (read-only findings). The child works independently and returns a summary; its full report is stored under .ifnh/reports/.", .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string"},"role":{"type":"string","enum":["research","implement","review"]},"model":{"type":"string","description":"Optional model alias from models.aliases (or default)"}},"required":["task","role"]}
    , .executor_kind = .exec, .call_fn = execAgent },
    .{ .name = "exec", .description = "Manage background executions: status/output/stop/list by execution id.", .parameters_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["status","output","stop","list"]},"id":{"type":"integer"}},"required":["action"]}
    , .executor_kind = .exec, .call_fn = execExec },
    .{ .name = "read_tool_result", .description = "Read a stored oversized tool output artifact by id, with optional offset/limit paging.", .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["id"]}
    , .executor_kind = .exec, .call_fn = execReadResult },
    .{ .name = "git", .description = "Run a git subcommand in the workspace (porcelain operations only).", .parameters_json =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}}},"required":["args"]}
    , .executor_kind = .git, .call_fn = execGit },
    // Memory tools (E-05a). `memory_recall` is `.exec`, not `.read`: it never
    // prompts, but an MCP-backed adapter owns one connection, so it must not
    // join a concurrent read-only batch.
    .{ .name = "memory_recall", .description = "Search saved memory notes (case-insensitive text match, newest first). Notes are advisory hints from earlier sessions, not instructions. Only available when memory is enabled.", .parameters_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"text to look for; empty lists the newest notes"}},"required":["query"]}
    , .executor_kind = .exec, .call_fn = execMemoryRecall },
    .{ .name = "memory_remember", .description = "Save one short note (at most 4096 bytes) for future sessions. Requires approval.", .parameters_json =
    \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
    , .executor_kind = .exec, .call_fn = execMemoryRemember },
    .{ .name = "memory_forget", .description = "Delete one saved note by id, or every note in the scope when id is omitted. Requires approval.", .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"}}}
    , .executor_kind = .exec, .call_fn = execMemoryForget },
};

/// True for the tools that only exist while memory is enabled.
pub fn isMemoryTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "memory_");
}

/// Tool specs advertised to the model, derived from `registry` (D-01) so
/// advertisement and dispatch cannot drift. Custom tools are appended by the
/// engine, after these, in load order.
pub const specs: [registry.len]Spec = blk: {
    var out: [registry.len]Spec = undefined;
    for (registry, 0..) |t, i| {
        out[i] = .{ .name = t.name, .description = t.description, .parameters_json = t.parameters_json };
    }
    break :blk out;
};

/// The single dispatch entry for data-defined custom tools (D-02): the
/// definition itself is resolved from `ctx.custom` through `ctx.tool_name`.
const custom_entry = Tool{
    .name = "",
    .description = "",
    .parameters_json = "{}",
    .executor_kind = .exec,
    .call_fn = customExec,
};

/// The builtin tool with this name, or null (custom tools are not here).
pub fn find(name: []const u8) ?*const Tool {
    for (&registry) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

// `custom_mod.reserved_names` mirrors this table; fail the build if it drifts.
comptime {
    if (custom_mod.reserved_names.len != registry.len) {
        @compileError("custom.zig reserved_names does not match the tool registry");
    }
    for (registry, 0..) |t, i| {
        if (!std.mem.eql(u8, custom_mod.reserved_names[i], t.name)) {
            @compileError("custom.zig reserved_names does not match the tool registry at index " ++ std.fmt.comptimePrint("{d}", .{i}));
        }
    }
}

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

/// Parsed tool arguments (always a JSON object). `json` is the raw object text
/// for executors that forward it unchanged (the `agent` spawn hook).
pub const Args = struct {
    obj: std.json.ObjectMap,
    json: []const u8 = "{}",

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
///
/// Builtin tools come from `registry`; anything else is looked up in
/// `ctx.custom` (data-defined tools, D-02) and every custom call runs through
/// `custom_entry`. Argument validation stays with each executor.
pub fn execute(name: []const u8, args_json: []const u8, ctx: *ToolContext) ToolResult {
    const V = std.json.Value;
    const args: V = std.json.parseFromSliceLeaky(V, ctx.arena, args_json, .{}) catch
        return errResult(ctx.arena, "invalid JSON arguments", .{});
    if (args != .object) return errResult(ctx.arena, "arguments must be a JSON object", .{});
    const a = Args{ .obj = args.object, .json = args_json };
    ctx.tool_name = name;

    const tool = find(name) orelse blk: {
        if (custom_mod.findTool(ctx.custom, name) != null) break :blk &custom_entry;
        return errResult(ctx.arena, "unknown tool '{s}'", .{name});
    };
    return tool.call_fn(ctx, &a);
}

// ------------------------------------------------------------ executors

fn execRead(ctx: *ToolContext, a: *const Args) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "read: missing path", .{});
    return toolRead(path, a.int("offset"), a.int("limit"), ctx);
}

fn execGlob(ctx: *ToolContext, a: *const Args) ToolResult {
    const pattern = a.str("pattern") orelse return errResult(ctx.arena, "glob: missing pattern", .{});
    return toolGlob(pattern, ctx);
}

fn execGrep(ctx: *ToolContext, a: *const Args) ToolResult {
    const pattern = a.str("pattern") orelse return errResult(ctx.arena, "grep: missing pattern", .{});
    const root = a.str("path") orelse "";
    return toolGrep(pattern, root, ctx);
}

const max_edits_per_call: usize = 100;

fn replaceAllFlag(ctx: *ToolContext, obj: std.json.ObjectMap, prefix: []const u8) union(enum) { ok: bool, fail: ToolResult } {
    const v = obj.get("replace_all") orelse return .{ .ok = false };
    return switch (v) {
        .bool => |b| .{ .ok = b },
        .null => .{ .ok = false },
        else => .{ .fail = errResult(ctx.arena, "edit: {s}replace_all must be a boolean", .{prefix}) },
    };
}

fn execEdit(ctx: *ToolContext, a: *const Args) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "edit: missing path", .{});
    if (a.obj.get("edits")) |ev| {
        if (a.obj.get("old_string") != null or a.obj.get("new_string") != null or a.obj.get("replace_all") != null)
            return errResult(ctx.arena, "edit: pass either old_string/new_string (with optional replace_all) or edits, not both", .{});
        if (ev != .array or ev.array.items.len == 0)
            return errResult(ctx.arena, "edit: edits must be a non-empty array", .{});
        if (ev.array.items.len > max_edits_per_call)
            return errResult(ctx.arena, "edit: at most {d} edits per call", .{max_edits_per_call});
        const ops = ctx.arena.alloc(EditOp, ev.array.items.len) catch return errResult(ctx.arena, "oom", .{});
        for (ev.array.items, ops, 0..) |item, *op, i| {
            if (item != .object) return errResult(ctx.arena, "edit: edits[{d}] must be an object", .{i});
            const old_v = item.object.get("old_string") orelse return errResult(ctx.arena, "edit: edits[{d}]: missing old_string", .{i});
            const new_v = item.object.get("new_string") orelse return errResult(ctx.arena, "edit: edits[{d}]: missing new_string", .{i});
            if (old_v != .string or new_v != .string)
                return errResult(ctx.arena, "edit: edits[{d}]: old_string and new_string must be strings", .{i});
            const prefix = std.fmt.allocPrint(ctx.arena, "edits[{d}]: ", .{i}) catch "";
            const all = switch (replaceAllFlag(ctx, item.object, prefix)) {
                .ok => |b| b,
                .fail => |r| return r,
            };
            op.* = .{ .old = old_v.string, .new = new_v.string, .replace_all = all };
        }
        return toolEdit(path, ops, true, ctx);
    }
    const old_s = a.str("old_string") orelse return errResult(ctx.arena, "edit: missing old_string", .{});
    const new_s = a.str("new_string") orelse return errResult(ctx.arena, "edit: missing new_string", .{});
    const all = switch (replaceAllFlag(ctx, a.obj, "")) {
        .ok => |b| b,
        .fail => |r| return r,
    };
    const ops = ctx.arena.alloc(EditOp, 1) catch return errResult(ctx.arena, "oom", .{});
    ops[0] = .{ .old = old_s, .new = new_s, .replace_all = all };
    return toolEdit(path, ops, false, ctx);
}

fn execWrite(ctx: *ToolContext, a: *const Args) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "write: missing path", .{});
    const content = a.str("content") orelse return errResult(ctx.arena, "write: missing content", .{});
    return toolWrite(path, content, ctx);
}

fn execBash(ctx: *ToolContext, a: *const Args) ToolResult {
    const command = a.str("command") orelse return errResult(ctx.arena, "bash: missing command", .{});
    const background = if (a.obj.get("background")) |b| (b == .bool and b.bool) else false;
    const timeout_s: u32 = blk: {
        const v = a.obj.get("timeout_s") orelse break :blk 0;
        if (v != .integer or v.integer <= 0 or v.integer > 86_400) break :blk 0;
        break :blk @intCast(v.integer);
    };
    return toolBash(command, background, timeout_s, ctx);
}

fn execSkill(ctx: *ToolContext, a: *const Args) ToolResult {
    const load_fn = ctx.skill_load_fn orelse
        return errResult(ctx.arena, "skill: skills not available", .{});
    const skill_name = a.str("name") orelse return errResult(ctx.arena, "skill: missing name", .{});
    const body = load_fn(ctx.skill_ctx orelse ctx.approval_ctx, ctx.arena, skill_name) orelse
        return errResult(ctx.arena, "skill: '{s}' not found in catalog", .{skill_name});
    return .{ .output = body, .status = .ok };
}

fn execExec(ctx: *ToolContext, a: *const Args) ToolResult {
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
}

fn execReadResult(ctx: *ToolContext, a: *const Args) ToolResult {
    const artifact_id = a.str("id") orelse return errResult(ctx.arena, "read_tool_result: missing id", .{});
    return toolReadResult(artifact_id, a.int("offset"), a.int("limit"), ctx);
}

fn execMcpList(ctx: *ToolContext, _: *const Args) ToolResult {
    const list_fn = ctx.mcp_list_fn orelse
        return errResult(ctx.arena, "mcp_list: MCP not configured", .{});
    return .{ .output = list_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena), .status = .ok };
}

fn execMcpDescribe(ctx: *ToolContext, a: *const Args) ToolResult {
    const describe_fn = ctx.mcp_describe_fn orelse
        return errResult(ctx.arena, "mcp_describe: MCP not configured", .{});
    const server = a.str("server") orelse return errResult(ctx.arena, "mcp_describe: missing server", .{});
    const mcp_tool = a.str("tool") orelse return errResult(ctx.arena, "mcp_describe: missing tool", .{});
    const out = describe_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena, server, mcp_tool);
    return .{ .output = out, .status = if (std.mem.startsWith(u8, out, "error:")) .failed else .ok };
}

fn execMcpCall(ctx: *ToolContext, a: *const Args) ToolResult {
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
}

const memory_off = "memory is off (memory.adapter)";

fn execMemoryRecall(ctx: *ToolContext, a: *const Args) ToolResult {
    const recall_fn = ctx.memory_recall_fn orelse return errResult(ctx.arena, "{s}", .{memory_off});
    const query = a.str("query") orelse return errResult(ctx.arena, "memory_recall: missing query", .{});
    const out = recall_fn(ctx.memory_ctx orelse ctx.approval_ctx, ctx.arena, query);
    return .{ .output = out, .status = if (std.mem.startsWith(u8, out, "error:")) .failed else .ok };
}

/// Memory writes go through the permission engine as the pseudo MCP tool
/// `memory.remember` / `memory.forget`, so `permissions` allow/deny lists for
/// MCP tools (`memory.*`) apply and the default is to ask.
fn memoryWriteAllowed(ctx: *ToolContext, tool: []const u8, title: []const u8, detail: []const u8) ?ToolResult {
    switch (ctx.engine.decide(.{ .mcp = .{ .server = "memory", .tool = tool } })) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "memory {s}", .{tool}),
        .ask => if (!ctx.requestApproval(title, detail, .none))
            return deniedResult(ctx.arena, "memory {s} (declined)", .{tool}),
    }
    return null;
}

fn execMemoryRemember(ctx: *ToolContext, a: *const Args) ToolResult {
    const remember_fn = ctx.memory_remember_fn orelse return errResult(ctx.arena, "{s}", .{memory_off});
    const text = a.str("text") orelse return errResult(ctx.arena, "memory_remember: missing text", .{});
    if (memoryWriteAllowed(ctx, "remember", "save a memory note", text)) |denied| return denied;
    const out = remember_fn(ctx.memory_ctx orelse ctx.approval_ctx, ctx.arena, text);
    return .{ .output = out, .status = if (std.mem.startsWith(u8, out, "error:")) .failed else .ok };
}

fn execMemoryForget(ctx: *ToolContext, a: *const Args) ToolResult {
    const forget_fn = ctx.memory_forget_fn orelse return errResult(ctx.arena, "{s}", .{memory_off});
    const id = a.str("id");
    const detail = id orelse "every note in the memory scope";
    if (memoryWriteAllowed(ctx, "forget", "delete memory notes", detail)) |denied| return denied;
    const out = forget_fn(ctx.memory_ctx orelse ctx.approval_ctx, ctx.arena, id);
    return .{ .output = out, .status = if (std.mem.startsWith(u8, out, "error:")) .failed else .ok };
}

fn execAgent(ctx: *ToolContext, a: *const Args) ToolResult {
    const spawn_fn = ctx.agent_spawn_fn orelse
        return errResult(ctx.arena, "agent: delegation disabled", .{});
    const res = spawn_fn(ctx.agent_spawn_ctx orelse ctx.approval_ctx, ctx.arena, ctx.agent_depth, a.json);
    return .{
        .output = res.summary,
        .status = if (res.status == .completed) .ok else .failed,
    };
}

fn execGit(ctx: *ToolContext, a: *const Args) ToolResult {
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

fn isInSkipDir(rel: []const u8) bool {
    for (skip_dirs) |sd| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, rel, from, sd)) |pos| {
            const before = pos == 0 or rel[pos - 1] == '/';
            const after = pos + sd.len == rel.len or rel[pos + sd.len] == '/';
            if (before and after) return true;
            from = pos + 1;
        }
    }
    return false;
}

fn isHiddenPath(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return true;
    }
    return false;
}

/// Hidden dot entries are skipped. `.env` files are the exception when the
/// policy allows reading them, but a hidden parent directory still wins.
fn skipHidden(ctx: *ToolContext, rel: []const u8) bool {
    if (!isHiddenPath(rel)) return false;
    if (ctx.engine.read_dotenv and isDotenvPath(rel)) {
        const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
        const parent = if (slash) |i| rel[0..i] else "";
        return isHiddenPath(parent);
    }
    return true;
}

fn shouldFilterPath(ctx: *ToolContext, rel: []const u8, is_dir: bool) bool {
    if (isInSkipDir(rel) or skipHidden(ctx, rel)) return true;
    if (!is_dir and !ctx.engine.read_dotenv and isDotenvPath(rel)) return true;
    return false;
}

fn collectFiles(
    ctx: *ToolContext,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: usize,
    limits: *WalkLimits,
    ignore: *search.IgnoreSet,
    out: *std.ArrayListUnmanaged([]const u8),
) void {
    if (depth > limits.max_depth or limits.max_files == 0) return;
    ignore.push(ctx.io, dir, rel_prefix);
    defer ignore.pop();
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (limits.max_files == 0) return;
        const child_rel = if (rel_prefix.len == 0)
            std.fmt.allocPrint(ctx.arena, "{s}", .{entry.name}) catch return
        else
            std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ rel_prefix, entry.name }) catch return;
        limits.max_files -|= 1;
        const is_dir = entry.kind == .directory;
        if (shouldFilterPath(ctx, child_rel, is_dir) or ignore.isIgnored(child_rel, is_dir)) continue;
        if (is_dir) {
            const sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(ctx.io);
            collectFiles(ctx, sub, child_rel, depth + 1, limits, ignore, out);
        } else {
            out.append(ctx.arena, child_rel) catch return;
        }
    }
}

fn sortPaths(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

/// `fd` runs with `--glob -d 1`, so it may only stand in for patterns that
/// match root-level basenames; everything with a path component (and the
/// recursive `**`) stays with the built-in walker.
fn fdMayHandleGlob(pattern: []const u8) bool {
    return std.mem.indexOfScalar(u8, pattern, '/') == null and !std.mem.eql(u8, pattern, "**");
}

/// Resolve an external program, honouring an explicit `tools.external`
/// override and otherwise following the process-global availability cache.
fn externalProgram(ctx: *ToolContext, which: enum { rg, fd }) ?[]const u8 {
    if (ctx.use_external_tools) |enabled| {
        if (!enabled) return null;
    }
    return switch (which) {
        .rg => ctx.external_cache.rg(ctx.io),
        .fd => ctx.external_cache.fd(ctx.io),
    };
}

fn toolGlob(pattern: []const u8, ctx: *ToolContext) ToolResult {
    if (fdMayHandleGlob(pattern)) {
        if (externalProgram(ctx, .fd)) |prog| {
            if (externalGlob(prog, pattern, ctx)) |result| return result;
        }
    }
    return fallbackGlob(pattern, ctx);
}

fn fallbackGlob(pattern: []const u8, ctx: *ToolContext) ToolResult {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var limits = WalkLimits{};
    var ignore = search.IgnoreSet.init(ctx.arena);
    collectFiles(ctx, ctx.workspace, "", 0, &limits, &ignore, &files);

    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files.items) |rel| {
        if (globm.match(pattern, rel)) matches.append(ctx.arena, rel) catch return errResult(ctx.arena, "oom", .{});
    }
    if (matches.items.len == 0) return .{ .output = "no matches", .status = .ok };
    sortPaths(matches.items);
    const shown = matches.items[0..@min(matches.items.len, 500)];
    const body = std.mem.join(ctx.arena, "\n", shown) catch return errResult(ctx.arena, "oom", .{});
    return .{ .output = truncateUtf8(ctx.arena, body, "glob results") catch body, .status = .ok };
}

const ExternalRun = struct {
    stdout: []const u8,
    code: u8,
};

fn runExternal(ctx: *ToolContext, argv: []const []const u8) ?ExternalRun {
    const run = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = .{ .dir = ctx.workspace },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(if (ctx.timeout_s == 0) 120 else ctx.timeout_s) } },
    }) catch return null;
    const code = switch (run.term) {
        .exited => |c| c,
        else => return null,
    };
    return .{ .stdout = run.stdout, .code = code };
}

fn externalGlob(prog: []const u8, pattern: []const u8, ctx: *ToolContext) ?ToolResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(ctx.arena, prog) catch return null;
    argv.appendSlice(ctx.arena, &[_][]const u8{
        "--color=never", "--type", "f", "--no-require-git", "--glob", "-d", "1",
    }) catch return null;
    if (ctx.engine.read_dotenv) argv.append(ctx.arena, "--hidden") catch return null;
    for (skip_dirs) |sd| {
        argv.appendSlice(ctx.arena, &[_][]const u8{ "--exclude", sd }) catch return null;
    }
    if (!ctx.engine.read_dotenv) {
        argv.appendSlice(ctx.arena, &[_][]const u8{ "--exclude", ".env", "--exclude", ".env.*" }) catch return null;
    }
    argv.appendSlice(ctx.arena, &[_][]const u8{ "--", pattern }) catch return null;

    const run = runExternal(ctx, argv.items) orelse return null;
    if (run.code != 0) return null;

    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, 0) != null) return null;
        if (std.mem.startsWith(u8, line, "./")) line = line[2..];
        if (line.len == 0 or line[0] == '/') return null;
        if (shouldFilterPath(ctx, line, false)) continue;
        matches.append(ctx.arena, line) catch return null;
    }
    if (matches.items.len == 0) return .{ .output = "no matches", .status = .ok };
    sortPaths(matches.items);
    const shown = matches.items[0..@min(matches.items.len, 500)];
    const body = std.mem.join(ctx.arena, "\n", shown) catch return null;
    return .{ .output = truncateUtf8(ctx.arena, body, "glob results") catch body, .status = .ok };
}

// ---------------------------------------------------------------- grep

fn toolGrep(pattern: []const u8, root: []const u8, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, root)) {
        .allow => {},
        else => return deniedResult(ctx.arena, "grep under '{s}'", .{root}),
    }
    var re = search.Regex.compile(ctx.arena, pattern) catch |err|
        return errResult(ctx.arena, "grep: {s}", .{search.regexError(err)});
    defer re.deinit();

    if (externalProgram(ctx, .rg)) |prog| {
        if (externalGrep(prog, pattern, root, ctx)) |result| return result;
    }
    return fallbackGrep(&re, root, ctx);
}

fn externalGrep(prog: []const u8, pattern: []const u8, root: []const u8, ctx: *ToolContext) ?ToolResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(ctx.arena, prog) catch return null;
    argv.appendSlice(ctx.arena, &[_][]const u8{
        "--no-config",   "--color=never",    "--no-heading",
        "--line-number", "--with-filename",  "--sort",
        "path",          "--no-messages",    "--max-count",
        "10",            "--no-require-git",
    }) catch return null;
    if (ctx.engine.read_dotenv) argv.append(ctx.arena, "--hidden") catch return null;
    for (skip_dirs) |sd| {
        const one = std.fmt.allocPrint(ctx.arena, "!{s}", .{sd}) catch return null;
        const all = std.fmt.allocPrint(ctx.arena, "!**/{s}/**", .{sd}) catch return null;
        argv.appendSlice(ctx.arena, &[_][]const u8{ "--glob", one, "--glob", all }) catch return null;
    }
    if (!ctx.engine.read_dotenv) {
        argv.appendSlice(ctx.arena, &[_][]const u8{
            "--glob", "!.env",   "--glob", "!**/.env",
            "--glob", "!.env.*", "--glob", "!**/.env.*",
        }) catch return null;
    }
    argv.appendSlice(ctx.arena, &[_][]const u8{ "--regexp", pattern, "--" }) catch return null;
    argv.append(ctx.arena, if (root.len == 0) "." else root) catch return null;

    const run = runExternal(ctx, argv.items) orelse return null;
    if (run.code > 1) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;
    var last_path: ?[]const u8 = null;
    var last_path_valid = false;
    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, 0) != null) return null;
        const match = parseRgMatch(line) orelse return null;
        var path = match.path;
        if (std.mem.startsWith(u8, path, "./")) path = path[2..];
        if (path.len == 0 or path[0] == '/') return null;
        if (shouldFilterPath(ctx, path, false)) continue;
        if (last_path == null or !std.mem.eql(u8, last_path.?, path)) {
            last_path = path;
            last_path_valid = fileIsValidUtf8(ctx, path);
        }
        if (!last_path_valid) continue;
        const text = std.mem.trimEnd(u8, match.text, "\r");
        out.print(ctx.arena, "{s}:{s}: {s}\n", .{ path, match.line_no, text }) catch return null;
        count += 1;
        if (count >= 200) break;
    }
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    return .{ .output = truncateUtf8(ctx.arena, out.items, "grep results") catch out.items, .status = .ok };
}

const RgMatch = struct {
    path: []const u8,
    line_no: []const u8,
    text: []const u8,
};

/// Parse `rg`'s `path:line:text` output. A path may itself contain colons,
/// so only a `:<digits>:` separator counts.
fn parseRgMatch(line: []const u8) ?RgMatch {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, ":")) |colon| {
        var j = colon + 1;
        const digits_start = j;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j > digits_start and j < line.len and line[j] == ':') {
            if (colon == 0) return null;
            return .{
                .path = line[0..colon],
                .line_no = line[digits_start..j],
                .text = line[j + 1 ..],
            };
        }
        from = colon + 1;
    }
    return null;
}

/// Apply the same file gates as the built-in walker before trusting an `rg`
/// hit: stat-size cap first, then per-line UTF-8 validation (a bad line drops
/// every hit from that file, as `grepFile` rolls them back).
fn fileIsValidUtf8(ctx: *ToolContext, path: []const u8) bool {
    const file = ctx.workspace.openFile(ctx.io, path, .{}) catch return false;
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return false;
    if (stat.size > max_file_size_bytes) return false;

    var buf: [max_grep_line_bytes]u8 = undefined;
    var file_reader = file.reader(ctx.io, &buf);
    const r = &file_reader.interface;
    while (true) {
        const maybe_line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const buffered = r.buffered();
                const line = buffered[0..@min(buffered.len, max_grep_line_bytes)];
                r.tossBuffered();
                if (!isTruncatedUtf8(line)) return false;
                switch (discardGrepLine(r)) {
                    .newline => continue,
                    .eof => return true,
                    .failed => return false,
                }
            },
            error.EndOfStream => {
                const rest = r.buffered();
                if (rest.len == 0) return true;
                r.tossBuffered();
                return std.unicode.utf8ValidateSlice(rest);
            },
            error.ReadFailed => return false,
        };
        const line = if (maybe_line.len > 0 and maybe_line[maybe_line.len - 1] == '\n')
            maybe_line[0 .. maybe_line.len - 1]
        else
            maybe_line;
        if (!std.unicode.utf8ValidateSlice(line)) return false;
    }
}

/// Longest grep line that is buffered and matched. Longer lines are matched
/// on this prefix and the remainder is discarded without being buffered.
const max_grep_line_bytes: usize = 8 * 1024;

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

fn fallbackGrep(re: *search.Regex, root: []const u8, ctx: *ToolContext) ToolResult {
    var start_rel = std.mem.trim(u8, root, " \t\r\n");
    start_rel = std.mem.trimEnd(u8, start_rel, "/");
    if (std.mem.eql(u8, start_rel, ".")) start_rel = "";

    var dir = ctx.workspace;
    var opened: ?std.Io.Dir = null;
    if (start_rel.len > 0) {
        dir = ctx.workspace.openDir(ctx.io, start_rel, .{ .iterate = true }) catch
            return .{ .output = "no matches", .status = .ok };
        opened = dir;
    }
    defer if (opened) |d| d.close(ctx.io);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var limits = WalkLimits{ .max_matches = 200 };
    var ignore = search.IgnoreSet.init(ctx.arena);
    // A subdirectory search still inherits the workspace .gitignore.
    if (start_rel.len > 0) ignore.push(ctx.io, ctx.workspace, "");
    collectFiles(ctx, dir, start_rel, 0, &limits, &ignore, &files);
    sortPaths(files.items);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (files.items) |rel| {
        if (limits.max_matches == 0) break;
        grepFile(ctx, rel, re, &limits, &out);
    }
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    return .{ .output = truncateUtf8(ctx.arena, out.items, "grep results") catch out.items, .status = .ok };
}

fn grepFile(ctx: *ToolContext, rel: []const u8, re: *search.Regex, limits: *WalkLimits, out: *std.ArrayListUnmanaged(u8)) void {
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
                const text = std.mem.trimEnd(u8, line, "\r");
                if (re.isMatch(text)) {
                    out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, text }) catch return;
                    file_hits += 1;
                    limits.max_matches -= 1;
                }
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
                    if ((!saw_line or ended_newline) and re.isMatch("")) {
                        out.print(ctx.arena, "{s}:{d}: \n", .{ rel, line_no + 1 }) catch return;
                        file_hits += 1;
                        limits.max_matches -= 1;
                    }
                    return;
                }
                r.tossBuffered();
                if (!std.unicode.utf8ValidateSlice(rest)) {
                    grepRollback(out, out_start, limits, matches_start);
                    return;
                }
                const text = std.mem.trimEnd(u8, rest, "\r");
                if (re.isMatch(text)) {
                    out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, text }) catch return;
                    file_hits += 1;
                    limits.max_matches -= 1;
                }
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
        const text = std.mem.trimEnd(u8, line, "\r");
        if (re.isMatch(text)) {
            out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, text }) catch return;
            file_hits += 1;
            limits.max_matches -= 1;
        }
        saw_line = true;
        ended_newline = true;
        line_no += 1;
    }
}

// ---------------------------------------------------------------- edit / write

/// What a write-class tool is about to do, for the approval preview.
const Change = union(enum) {
    write: []const u8,
    edits: []const EditOp,
};

fn prepareWrite(ctx: *ToolContext, path: []const u8, change: Change) ?ToolResult {
    switch (ctx.engine.decidePath(.write, path)) {
        .allow => {},
        .ask => {
            const preview = previewFor(ctx, path, change);
            if (!ctx.requestApprovalWithPreview("write file", path, .{ .path_write = path }, preview)) return deniedResult(ctx.arena, "write '{s}' (declined)", .{path});
        },
        .deny => return deniedResult(ctx.arena, "write '{s}' (protected path)", .{path}),
    }
    return null;
}

/// Unified diff shown at the approval prompt. Best effort: anything that
/// would make the tool itself fail (unreadable file, ambiguous edit) yields a
/// short note or nothing, and the tool reports the real error afterwards.
fn previewFor(ctx: *ToolContext, path: []const u8, change: Change) []const u8 {
    const cap = ctx.max_file_read_bytes;
    const before = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(cap)) catch |err| switch (err) {
        error.FileNotFound => @as([]const u8, ""),
        error.StreamTooLong => return "(file too large to preview)",
        else => return "",
    };
    const after = switch (change) {
        .write => |content| content,
        .edits => |ops| switch (applyEdits(ctx.arena, path, before, ops, false)) {
            .ok => |r| r.text,
            .fail => return "",
        },
    };
    if (after.len > cap) return "(change too large to preview)";
    return diff_mod.unifiedDiff(ctx.arena, path, before, after, .{}) catch "";
}

/// One replacement in an `edit` call (a plain edit is a one-element list).
const EditOp = struct { old: []const u8, new: []const u8, replace_all: bool = false };

const EditResult = union(enum) {
    ok: struct { text: []const u8, replacements: usize, whitespace_match: bool },
    /// Ready-to-report failure text.
    fail: []const u8,
};

const Applied = union(enum) {
    ok: struct { text: []const u8, count: usize, whitespace_match: bool },
    not_found,
    multiple,
    multiple_whitespace,
    oom,
};

/// Apply `ops` in order against one in-memory buffer. Pure: nothing is
/// written, so a failing op leaves the file untouched. `indexed` appends the
/// failing `edits[i]` to the message.
fn applyEdits(arena: std.mem.Allocator, path: []const u8, before: []const u8, ops: []const EditOp, indexed: bool) EditResult {
    var text = before;
    var total: usize = 0;
    var whitespace_match = false;
    for (ops, 0..) |op, i| {
        const msg: []const u8 = switch (applyOne(arena, text, op)) {
            .ok => |r| {
                text = r.text;
                total += r.count;
                whitespace_match = whitespace_match or r.whitespace_match;
                continue;
            },
            .oom => "edit: out of memory",
            .not_found => std.fmt.allocPrint(arena, "edit: old_string not found in '{s}' (file may have changed; re-read it)", .{path}) catch "edit: old_string not found",
            .multiple => std.fmt.allocPrint(arena, "edit: old_string appears multiple times in '{s}'; provide a larger unique context", .{path}) catch "edit: old_string appears multiple times",
            .multiple_whitespace => std.fmt.allocPrint(arena, "edit: old_string appears multiple times in '{s}'; provide a larger unique context (the match was whitespace-insensitive)", .{path}) catch "edit: old_string appears multiple times",
        };
        if (!indexed) return .{ .fail = msg };
        return .{ .fail = std.fmt.allocPrint(arena, "{s} [edits[{d}]]", .{ msg, i }) catch msg };
    }
    return .{ .ok = .{ .text = text, .replacements = total, .whitespace_match = whitespace_match } };
}

fn applyOne(arena: std.mem.Allocator, text: []const u8, op: EditOp) Applied {
    if (std.mem.indexOf(u8, text, op.old)) |first| {
        // An exact match always wins; the whitespace fallback never runs.
        if (op.replace_all) {
            const n = std.mem.count(u8, text, op.old);
            const out = std.mem.replaceOwned(u8, arena, text, op.old, op.new) catch return .oom;
            return .{ .ok = .{ .text = out, .count = n, .whitespace_match = false } };
        }
        if (std.mem.indexOf(u8, text[first + 1 ..], op.old) != null) return .multiple;
        const out = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ text[0..first], op.new, text[first + op.old.len ..] }) catch return .oom;
        return .{ .ok = .{ .text = out, .count = 1, .whitespace_match = false } };
    }
    // replace_all means "every exact occurrence": no fuzzy fallback for it.
    if (op.replace_all) return .not_found;
    return applyWhitespaceTolerant(arena, text, op);
}

/// Same tokens once leading/trailing blanks are dropped and space/tab runs
/// collapse to one.
fn sameIgnoringBlanks(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, " \t\r");
    var ib = std.mem.tokenizeAny(u8, b, " \t\r");
    while (true) {
        const ta = ia.next();
        const tb = ib.next();
        if (ta == null or tb == null) return ta == null and tb == null;
        if (!std.mem.eql(u8, ta.?, tb.?)) return false;
    }
}

/// Fallback for an old_string with no exact match: whole lines compared with
/// `sameIgnoringBlanks`, accepted only when exactly one window of lines
/// matches. The matched lines are replaced by `new` verbatim (indentation is
/// not reinterpreted).
fn applyWhitespaceTolerant(arena: std.mem.Allocator, text: []const u8, op: EditOp) Applied {
    const Line = struct { start: usize, end: usize };
    var old_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, op.old, '\n');
    while (it.next()) |l| old_lines.append(arena, l) catch return .oom;
    const ends_newline = op.old[op.old.len - 1] == '\n';
    if (ends_newline) _ = old_lines.pop();
    var any_content = false;
    for (old_lines.items) |l| {
        if (std.mem.trim(u8, l, " \t\r").len > 0) any_content = true;
    }
    if (!any_content) return .not_found;

    var lines: std.ArrayList(Line) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        lines.append(arena, .{ .start = pos, .end = nl orelse text.len }) catch return .oom;
        pos = if (nl) |n| n + 1 else text.len;
    }

    const k = old_lines.items.len;
    if (lines.items.len < k) return .not_found;
    var found: ?usize = null;
    var s: usize = 0;
    while (s + k <= lines.items.len) : (s += 1) {
        for (old_lines.items, 0..) |ol, j| {
            const fl = lines.items[s + j];
            if (!sameIgnoringBlanks(text[fl.start..fl.end], ol)) break;
        } else {
            if (found != null) return .multiple_whitespace;
            found = s;
        }
    }
    const first = found orelse return .not_found;
    const start = lines.items[first].start;
    var end = lines.items[first + k - 1].end;
    if (ends_newline and end < text.len) end += 1;
    const out = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ text[0..start], op.new, text[end..] }) catch return .oom;
    return .{ .ok = .{ .text = out, .count = 1, .whitespace_match = true } };
}

fn toolEdit(path: []const u8, ops: []const EditOp, indexed: bool, ctx: *ToolContext) ToolResult {
    for (ops, 0..) |op, i| {
        if (op.old.len > 0) continue;
        if (indexed) return errResult(ctx.arena, "edit: old_string must not be empty [edits[{d}]]", .{i});
        return errResult(ctx.arena, "edit: old_string must not be empty", .{});
    }
    if (prepareWrite(ctx, path, .{ .edits = ops })) |r| return r;

    const before = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(max_file_size_bytes)) catch
        return errResult(ctx.arena, "edit: cannot read '{s}'", .{path});

    const applied = switch (applyEdits(ctx.arena, path, before, ops, indexed)) {
        .ok => |r| r,
        .fail => |msg| return errResult(ctx.arena, "{s}", .{msg}),
    };
    const after = applied.text;

    // One write for the whole call: one journal group, one atomic replace.
    commitMutation(ctx, path, before, after) catch |err|
        return errResult(ctx.arena, "edit: failed to write '{s}': {s}", .{ path, @errorName(err) });
    const note: []const u8 = if (applied.whitespace_match) "; matched ignoring whitespace differences" else "";
    const out = if (ops.len == 1 and !ops[0].replace_all and !indexed)
        std.fmt.allocPrint(ctx.arena, "edited {s} ({d} -> {d} bytes){s}", .{ path, before.len, after.len, note })
    else
        std.fmt.allocPrint(ctx.arena, "edited {s} ({d} edits, {d} replacements, {d} -> {d} bytes){s}", .{ path, ops.len, applied.replacements, before.len, after.len, note });
    return .{ .output = out catch "edited", .status = .ok };
}

fn toolWrite(path: []const u8, content: []const u8, ctx: *ToolContext) ToolResult {
    if (prepareWrite(ctx, path, .{ .write = content })) |r| return r;

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

    // Note: shell side effects are not journaled (M185); surfaced in audit log instead.
    return runModelShell(&local, command);
}

/// Run a command the model issued under `/bin/sh -c`, through the sandbox
/// hook when the host wired one. Without a hook this is `runShell` exactly.
fn runModelShell(ctx: *ToolContext, command: []const u8) ToolResult {
    const wrap = ctx.sandbox_fn orelse return runShell(ctx, command);
    const wrap_ctx = ctx.sandbox_ctx orelse return errResult(ctx.arena, "sandbox unavailable: hook has no state", .{});
    switch (wrap(wrap_ctx, ctx.arena, command)) {
        .argv => |argv| return runCaptured(ctx, argv, ""),
        .unsupported => |reason| return errResult(ctx.arena, "sandbox unavailable: {s}", .{reason}),
    }
}

/// Run `command` under `/bin/sh -c` with the bash tool's capture, cancel and
/// timeout handling, without any permission check. For the human at the
/// keyboard (the REPL's `!cmd`), never for model-issued commands.
pub fn runShell(ctx: *ToolContext, command: []const u8) ToolResult {
    return runCaptured(ctx, &.{ "/bin/sh", "-c", command }, "");
}

/// Run a data-defined custom tool (D-02): substitute and shell-quote the
/// arguments, gate the rendered command exactly like `bash`, then run it
/// through the same captured path (same timeouts, truncation, journal and
/// background behaviour). The JSON `permission` class is advisory metadata
/// for the model and future allowlists; enforcement is this gate plus
/// approval.
fn customExec(ctx: *ToolContext, a: *const Args) ToolResult {
    const ct = custom_mod.findTool(ctx.custom, ctx.tool_name) orelse
        return errResult(ctx.arena, "unknown tool '{s}'", .{ctx.tool_name});
    const rendered = switch (custom_mod.render(ctx.arena, ct.*, a.obj)) {
        .command => |c| c,
        .err => |msg| return .{ .output = msg, .status = .failed },
    };
    switch (ctx.engine.decide(.{ .command = .{ .command = rendered } })) {
        .deny => return deniedResult(ctx.arena, "custom tool '{s}': command '{s}'", .{ ct.name, rendered }),
        .ask => {
            const detail = std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ ct.name, rendered }) catch ct.name;
            if (!ctx.requestApproval("run custom tool", detail, .none))
                return deniedResult(ctx.arena, "custom tool '{s}' (declined)", .{ct.name});
        },
        .allow => {},
    }

    // The definition's timeout may only tighten the session ceiling (0 = the
    // 120 s default, same meaning as everywhere else for `timeout_s`).
    var local = ctx.*;
    local.timeout_s = @min(ct.timeout_s, if (ctx.timeout_s == 0) 120 else ctx.timeout_s);
    return runModelShell(&local, rendered);
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

test "write and edit approvals carry a diff preview, bash does not" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "code.zig", .data = "const x = 1;\nconst y = 2;\n" });

    const Seen = struct {
        preview: []const u8 = "",
        calls: usize = 0,
        fn approve(ctx: *anyopaque, req: ApprovalRequest) ApprovalResponse {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.preview = req.preview;
            self.calls += 1;
            return .denied;
        }
    };
    var seen = Seen{};
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.approval_ctx = &seen;
    ctx.approval_fn = Seen.approve;

    // write over an existing file: only the changed line differs.
    _ = execute("write", "{\"path\":\"code.zig\",\"content\":\"const x = 1;\\nconst y = 3;\\n\"}", &ctx);
    try std.testing.expectEqualStrings("--- a/code.zig\n+++ b/code.zig\n@@ -1,2 +1,2 @@\n const x = 1;\n-const y = 2;\n+const y = 3;\n", seen.preview);

    // write of a new file: all additions.
    _ = execute("write", "{\"path\":\"new.txt\",\"content\":\"hi\\n\"}", &ctx);
    try std.testing.expectEqualStrings("--- a/new.txt\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+hi\n", seen.preview);

    // edit: diff of old vs new file content.
    _ = execute("edit", "{\"path\":\"code.zig\",\"old_string\":\"x = 1\",\"new_string\":\"x = 9\"}", &ctx);
    try std.testing.expect(std.mem.indexOf(u8, seen.preview, "-const x = 1;\n+const x = 9;\n") != null);

    // An ambiguous edit previews nothing (the tool will refuse it itself).
    try tmp.dir.writeFile(io, .{ .sub_path = "dup.txt", .data = "aa aa" });
    _ = execute("edit", "{\"path\":\"dup.txt\",\"old_string\":\"aa\",\"new_string\":\"bb\"}", &ctx);
    try std.testing.expectEqualStrings("", seen.preview);

    // Other approval sites leave the preview empty.
    _ = execute("bash", "{\"command\":\"mkdir newdir\"}", &ctx);
    try std.testing.expectEqualStrings("", seen.preview);
    try std.testing.expectEqual(@as(usize, 5), seen.calls);
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

    // Custom tool definitions are arbitrary shell: write and edit are refused too.
    const w = execute("write", "{\"path\":\".ifnh/tools/evil.json\",\"content\":\"{}\"}", &ctx);
    try std.testing.expectEqual(Status.denied, w.status);
    const ed = execute("edit", "{\"path\":\".ifnh/tools/evil.json\",\"old_string\":\"a\",\"new_string\":\"b\"}", &ctx);
    try std.testing.expectEqual(Status.denied, ed.status);
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

    const line = &@as([1023]u8, @splat('x')) ++ "\n";
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
    ctx.use_external_tools = false;

    const r = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "late.txt:901: needle at the end") != null);
}

test "grep discards overlong lines but keeps line numbers" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    const data = &@as([9000]u8, @splat('x')) ++ "\nneedle\nafter\n";
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

fn setupSearchParityTree(tmp: *std.testing.TmpDir) !void {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, ".hidden");
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nbuild/\n*.tmp\n!keep.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/b.zig", .data = "needle twice\nnothing\nneedle again\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/keep.log", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.log", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build/out.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden/secret.txt", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "needle=1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.bin", .data = "needle\xff\n" });
}

test "external rg grep agrees with fallback" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try setupSearchParityTree(&tmp);

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.use_external_tools = false;

    const fallback_grep = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, fallback_grep.status);
    try std.testing.expectEqualStrings(
        "src/a.zig:1: needle\n" ++
            "src/deep/b.zig:1: needle twice\n" ++
            "src/deep/b.zig:3: needle again\n" ++
            "src/keep.log:1: needle\n",
        fallback_grep.output,
    );

    if (!search.programAvailable(io, "rg")) return error.SkipZigTest;

    ctx.use_external_tools = true;
    ctx.external_cache = .{};
    const external_grep = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, external_grep.status);
    try std.testing.expectEqualStrings(fallback_grep.output, external_grep.output);
}

test "external fd glob agrees with fallback for root-level patterns" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try setupSearchParityTree(&tmp);

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.use_external_tools = false;

    const fallback_glob = execute("glob", "{\"pattern\":\"*.bin\"}", &ctx);
    try std.testing.expectEqual(Status.ok, fallback_glob.status);
    try std.testing.expectEqualStrings("blob.bin", fallback_glob.output);

    if (!search.programAvailable(io, "fd") and !search.programAvailable(io, "fdfind"))
        return error.SkipZigTest;

    ctx.use_external_tools = true;
    ctx.external_cache = .{};
    const external_glob = execute("glob", "{\"pattern\":\"*.bin\"}", &ctx);
    try std.testing.expectEqual(Status.ok, external_glob.status);
    try std.testing.expectEqualStrings(fallback_glob.output, external_glob.output);
}

test "fd is never used for path glob patterns" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try setupSearchParityTree(&tmp);

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.use_external_tools = true;
    // An fd that exits 0 with no output must not turn a path pattern into
    // "no matches"; path patterns belong to the built-in walker.
    ctx.external_cache = .{ .fd_checked = true, .fd_name = "/bin/true" };

    const r = execute("glob", "{\"pattern\":\"src/**/*.zig\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expectEqualStrings("src/a.zig\nsrc/deep/b.zig", r.output);
}

test "grep fallback regex subset and unsupported constructs" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data =
        \\const abc = 12;
        \\var x = 1;
        \\literal.dot
        \\foo123
        \\end line
        \\
    });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.use_external_tools = false;

    const cases = [_]struct { args: []const u8, expected: []const u8 }{
        .{ .args = "{\"pattern\":\"^const [a-z]+ = [0-9]+;$\"}", .expected = "f.txt:1: const abc = 12;\n" },
        .{ .args = "{\"pattern\":\"a.c\"}", .expected = "f.txt:1: const abc = 12;\n" },
        .{ .args = "{\"pattern\":\"foo[0-9]+\"}", .expected = "f.txt:4: foo123\n" },
        .{ .args = "{\"pattern\":\"^var\"}", .expected = "f.txt:2: var x = 1;\n" },
        .{ .args = "{\"pattern\":\"line$\"}", .expected = "f.txt:5: end line\n" },
    };
    for (cases) |case| {
        const r = execute("grep", case.args, &ctx);
        try std.testing.expectEqual(Status.ok, r.status);
        try std.testing.expectEqualStrings(case.expected, r.output);
    }

    const unsupported = [_]struct { args: []const u8, message: []const u8 }{
        .{ .args = "{\"pattern\":\"(foo)\"}", .message = "groups are unsupported" },
        .{ .args = "{\"pattern\":\"a|b\"}", .message = "alternation is unsupported" },
        .{ .args = "{\"pattern\":\"a{2}\"}", .message = "{m,n} repetition is unsupported" },
        .{ .args = "{\"pattern\":\"a\\\\1\"}", .message = "backreferences are unsupported" },
    };
    for (unsupported) |case| {
        const r = execute("grep", case.args, &ctx);
        try std.testing.expectEqual(Status.failed, r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.output, case.message) != null);
    }
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

test "tool registry and advertised specs agree" {
    try std.testing.expectEqual(@as(usize, 17), registry.len);
    try std.testing.expectEqual(@as(usize, registry.len), specs.len);
    for (registry, 0..) |t, i| {
        // One spec per registry entry, in registry order.
        try std.testing.expectEqualStrings(t.name, specs[i].name);
        try std.testing.expectEqualStrings(t.description, specs[i].description);
        try std.testing.expectEqualStrings(t.parameters_json, specs[i].parameters_json);
        // And `find` resolves it back to the same entry.
        const found = find(t.name) orelse return error.RegistryEntryNotFindable;
        try std.testing.expectEqual(&registry[i], found);
        // No duplicate names.
        for (registry[i + 1 ..]) |later| {
            try std.testing.expect(!std.mem.eql(u8, t.name, later.name));
        }
    }
    try std.testing.expect(find("frobnicate") == null);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("read_tool_result") != null);
}

test "tool registry backs read-only classification" {
    // The read tools are exactly the executor_kind = .read entries.
    for (registry) |t| {
        try std.testing.expectEqual(t.executor_kind == .read, isReadOnly(t.name));
    }
    // Names outside the table (custom tools included) are never read-only.
    try std.testing.expect(!isReadOnly("deploy-staging"));
}

test "custom tool executes end to end through execute" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".ifnh/tools");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/tools/hello.json", .data =
        \\{"name":"hello","description":"Say hello","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
        \\ "command":"printf 'hello %s' {name}","permission":"read"}
    });

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);

    const set = custom_mod.Set.load(arena, io, tmp.dir, true);
    try std.testing.expectEqual(@as(usize, 1), set.tools.len);
    try std.testing.expectEqual(@as(usize, 0), set.warnings.len);
    ctx.custom = set.tools;

    const r = execute("hello", "{\"name\":\"world\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expectEqualStrings("<stdout>\nhello world\n</stdout>\n", r.output);
    try std.testing.expectEqualStrings("hello", ctx.tool_name);

    // The same name is not a builtin: `find` must miss it and isReadOnly false.
    try std.testing.expect(find("hello") == null);
    try std.testing.expect(!isReadOnly("hello"));
}

test "custom tool argument cannot break out of the command" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".ifnh/tools");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/tools/echo.json", .data =
        \\{"name":"echo-arg","description":"Echo one argument","parameters":{"type":"object"},
        \\ "command":"printf '%s' {msg}","permission":"read"}
    });

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.custom = custom_mod.Set.load(arena, io, tmp.dir, true).tools;

    const payload = "a b; rm -rf / #' \"quoted\" $(whoami)";
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"msg\":");
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    try aw.writer.writeByte('}');

    const r = execute("echo-arg", aw.written(), &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    // Passed as one shell word: the echoed text is exactly the argument.
    try std.testing.expectEqualStrings(
        "<stdout>\na b; rm -rf / #' \"quoted\" $(whoami)\n</stdout>\n",
        r.output,
    );
}

test "custom tool render and gate failures" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".ifnh/tools");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/tools/tools.json", .data =
        \\[{"name":"needs-other","description":"d","parameters":{"type":"object"},"command":"echo {other}","permission":"read"},
        \\ {"name":"touch-it","description":"d","parameters":{"type":"object"},"command":"touch made.txt","permission":"write"}]
    });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    // Approval always declined.
    ctx.approval_fn = struct {
        fn deny(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied;
        }
    }.deny;
    ctx.custom = custom_mod.Set.load(arena, io, tmp.dir, true).tools;
    try std.testing.expectEqual(@as(usize, 2), ctx.custom.len);

    // Missing placeholder key: .failed with the "custom tool" error.
    const r = execute("needs-other", "{\"msg\":\"x\"}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.startsWith(u8, r.output, "error: custom tool 'needs-other': "));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "argument 'other'") != null);

    // A mutating command is gated; a declined approval is .denied and runs nothing.
    const touched = execute("touch-it", "{}", &ctx);
    try std.testing.expectEqual(Status.denied, touched.status);
    try std.testing.expect(std.mem.startsWith(u8, touched.output, "permission denied: custom tool 'touch-it'"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "made.txt", .{}));

    // An unknown name keeps the old error string and status.
    const unknown = execute("frobnicate", "{}", &ctx);
    try std.testing.expectEqual(Status.failed, unknown.status);
    try std.testing.expectEqualStrings("error: unknown tool 'frobnicate'", unknown.output);
}

// ---------------------------------------------------------------- edit upgrades (D-10)

const EditSeen = struct {
    preview: []const u8 = "",
    calls: usize = 0,
    fn approve(ctx: *anyopaque, req: ApprovalRequest) ApprovalResponse {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.preview = req.preview;
        self.calls += 1;
        return .approved_once;
    }
};

fn readText(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, name, arena, .limited(1 << 16));
}

test "edit replace_all replaces every occurrence and reports the count" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "foo bar foo\nfoo\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"foo\",\"new_string\":\"baz\",\"replace_all\":true}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "3 replacements") != null);
    try std.testing.expectEqualStrings("baz bar baz\nbaz\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit replace_all with no match fails and leaves the file alone" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"zzz\",\"new_string\":\"y\",\"replace_all\":true}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "not found") != null);
    try std.testing.expectEqualStrings("alpha\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
    // Default (replace_all false) still refuses several matches, same wording.
    try tmp.dir.writeFile(io, .{ .sub_path = "d.txt", .data = "aa aa" });
    const dup = execute("edit", "{\"path\":\"d.txt\",\"old_string\":\"aa\",\"new_string\":\"b\",\"replace_all\":false}", &ctx);
    try std.testing.expect(std.mem.indexOf(u8, dup.output, "appears multiple times in 'd.txt'; provide a larger unique context") != null);
}

test "edit multi-edit applies three edits in one approval, one write and one journal group" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    const original = "one\ntwo\nthree\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = original });
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var j = try journal_mod.Journal.open(io, arena, tmp.dir, tmp.dir);
    defer j.close();
    var seen = EditSeen{};
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.journal = &j;
    ctx.approval_ctx = &seen;
    ctx.approval_fn = EditSeen.approve;

    const r = execute("edit", "{\"path\":\"f.txt\",\"edits\":[{\"old_string\":\"one\",\"new_string\":\"1\"},{\"old_string\":\"two\",\"new_string\":\"2\"},{\"old_string\":\"1\\n2\",\"new_string\":\"12\"}]}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "3 edits") != null);
    try std.testing.expectEqualStrings("12\nthree\n", try readText(arena, io, tmp.dir, "f.txt"));
    // One approval whose diff is the final content; one journal group.
    try std.testing.expectEqual(@as(usize, 1), seen.calls);
    try std.testing.expect(std.mem.indexOf(u8, seen.preview, "-one\n-two\n+12\n") != null);
    _ = try j.undo();
    try std.testing.expect(!j.canUndo());
    try std.testing.expectEqualStrings(original, try readText(arena, io, tmp.dir, "f.txt"));
}

test "edit multi-edit with a stale second edit leaves the file byte-identical" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one\ntwo\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"edits\":[{\"old_string\":\"one\",\"new_string\":\"1\"},{\"old_string\":\"gone\",\"new_string\":\"x\"}]}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "old_string not found in 'f.txt'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "edits[1]") != null);
    try std.testing.expectEqualStrings("one\ntwo\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit rejects edits combined with old_string and malformed edits" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const both = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"one\",\"new_string\":\"1\",\"edits\":[{\"old_string\":\"one\",\"new_string\":\"1\"}]}", &ctx);
    try std.testing.expectEqual(Status.failed, both.status);
    try std.testing.expect(std.mem.indexOf(u8, both.output, "old_string/new_string") != null);
    try std.testing.expect(std.mem.indexOf(u8, both.output, "edits") != null);
    const empty = execute("edit", "{\"path\":\"f.txt\",\"edits\":[]}", &ctx);
    try std.testing.expectEqual(Status.failed, empty.status);
    const bad_flag = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"one\",\"new_string\":\"1\",\"replace_all\":\"yes\"}", &ctx);
    try std.testing.expect(std.mem.indexOf(u8, bad_flag.output, "replace_all must be a boolean") != null);
    try std.testing.expectEqualStrings("one\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit whitespace-tolerant unique match applies with new_string verbatim" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.zig", .data = "fn a() void {\n\tconst  x =\t1;\n    return;\n}\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    // The model's old_string has different indentation and spacing.
    const r = execute("edit", "{\"path\":\"f.zig\",\"old_string\":\"  const x = 1;\\nreturn;\",\"new_string\":\"  const x = 2;\\n  return;\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ignoring whitespace") != null);
    // Whole matched lines are replaced; new_string is inserted as given.
    try std.testing.expectEqualStrings("fn a() void {\n  const x = 2;\n  return;\n}\n", try readText(arena_state.allocator(), io, tmp.dir, "f.zig"));
}

test "edit whitespace-tolerant ambiguous match fails with a hint" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    const original = "a\n  x = 1;\nb\n\tx  =  1;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = original });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"x   =   1;\",\"new_string\":\"y\"}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "appears multiple times") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "whitespace-insensitive") != null);
    try std.testing.expectEqualStrings(original, try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit exact match wins over a whitespace-insensitive candidate" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    // "x = 1;" matches exactly once (line 2) and ignoring whitespace twice.
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x  =  1;\nx = 1;\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"x = 1;\",\"new_string\":\"y\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ignoring whitespace") == null);
    try std.testing.expectEqualStrings("x  =  1;\ny\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit replace_all never uses the whitespace fallback" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x  =  1;\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"old_string\":\"x = 1;\",\"new_string\":\"y\",\"replace_all\":true}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expectEqualStrings("x  =  1;\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "edit multi-edit reports an ambiguous edit by index and writes nothing" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "aa aa\nzz\n" });
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("edit", "{\"path\":\"f.txt\",\"edits\":[{\"old_string\":\"zz\",\"new_string\":\"q\"},{\"old_string\":\"aa\",\"new_string\":\"b\"}]}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "multiple times") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "edits[1]") != null);
    try std.testing.expectEqualStrings("aa aa\nzz\n", try readText(arena_state.allocator(), io, tmp.dir, "f.txt"));
}

test "memory tools: writes are gated, recall is not, and no hook means off" {
    const memory_mod = @import("../core/memory.zig");
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);

    // Not wired: every memory tool says memory is off, and none is advertised.
    const off = execute("memory_recall", "{\"query\":\"x\"}", &ctx);
    try std.testing.expectEqual(Status.failed, off.status);
    try std.testing.expectEqualStrings("error: memory is off (memory.adapter)", off.output);
    try std.testing.expectEqual(Status.failed, execute("memory_remember", "{\"text\":\"x\"}", &ctx).status);
    try std.testing.expect(isMemoryTool("memory_forget") and !isMemoryTool("mcp_call"));

    const h = memory_mod.open(arena, io, tmp.dir, null, .{ .kind = .file }, null).?;
    ctx.memory_recall_fn = memory_mod.recallHook;
    ctx.memory_remember_fn = memory_mod.rememberHook;
    ctx.memory_forget_fn = memory_mod.forgetHook;
    ctx.memory_ctx = h;

    try std.testing.expectEqualStrings("no memory matches", execute("memory_recall", "{\"query\":\"x\"}", &ctx).output);

    // A declined approval writes nothing.
    const Denier = struct {
        fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied;
        }
    };
    const approve_fn = ctx.approval_fn;
    ctx.approval_fn = Denier.approve;
    const declined = execute("memory_remember", "{\"text\":\"secret plan\"}", &ctx);
    try std.testing.expectEqual(Status.denied, declined.status);
    try std.testing.expectEqualStrings("no memory matches", execute("memory_recall", "{\"query\":\"\"}", &ctx).output);

    ctx.approval_fn = approve_fn;
    const saved = execute("memory_remember", "{\"text\":\"secret plan\"}", &ctx);
    try std.testing.expectEqual(Status.ok, saved.status);
    const found = execute("memory_recall", "{\"query\":\"PLAN\"}", &ctx);
    try std.testing.expect(std.mem.startsWith(u8, found.output, try std.fmt.allocPrint(arena, "- {s} (", .{saved.output})));
    try std.testing.expectEqual(Status.failed, execute("memory_remember", "{\"text\":\"\"}", &ctx).status);

    ctx.approval_fn = Denier.approve;
    try std.testing.expectEqual(Status.denied, execute("memory_forget", "{}", &ctx).status);
    ctx.approval_fn = approve_fn;
    try std.testing.expectEqualStrings("0", execute("memory_forget", "{\"id\":\"nope\"}", &ctx).output);
    try std.testing.expectEqualStrings("1", execute("memory_forget", "{}", &ctx).output);
}

test "permission rules for MCP tools govern memory writes (memory.*)" {
    const memory_mod = @import("../core/memory.zig");
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    e.mcp_deny = &.{"memory.forget"};
    e.mcp_allow = &.{"memory.remember"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    const h = memory_mod.open(arena, io, tmp.dir, null, .{ .kind = .file }, null).?;
    ctx.memory_recall_fn = memory_mod.recallHook;
    ctx.memory_remember_fn = memory_mod.rememberHook;
    ctx.memory_forget_fn = memory_mod.forgetHook;
    ctx.memory_ctx = h;
    ctx.approval_fn = struct {
        fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied; // would block anything that still asks
        }
    }.approve;

    try std.testing.expectEqual(Status.ok, execute("memory_remember", "{\"text\":\"allowed by rule\"}", &ctx).status);
    try std.testing.expectEqual(Status.denied, execute("memory_forget", "{}", &ctx).status);
}

// ---------------------------------------------------------------- sandbox (E-04)

/// A resolved sandbox for `ws` using the best backend of this host, or null
/// (with a printed SKIP) when none can run here. Landlock re-executes the
/// built `zig-out/bin/ifnh`, so it needs `zig build` to have run first.
fn sandboxForTest(arena: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, network: bool) !?sandbox_mod.Session {
    var env = try std.testing.environ.createMap(arena);
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = try arena.dupe(u8, ws_buf[0..try ws.realPathFile(io, ".", &ws_buf)]);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = blk: {
        const n = std.Io.Dir.cwd().realPathFile(io, "zig-out/bin/ifnh", &exe_buf) catch break :blk "";
        break :blk try arena.dupe(u8, exe_buf[0..n]);
    };
    const s = try sandbox_mod.Session.resolve(arena, io, &env, .{ .mode = .required, .network = network }, ws_path, exe);
    if (s.backend == .none) {
        std.debug.print("SKIP sandbox integration: no backend on this host\n", .{});
        return null;
    }
    if (s.backend == .landlock and exe.len == 0) {
        std.debug.print("SKIP sandbox integration: Landlock needs zig-out/bin/ifnh (run `zig build` first)\n", .{});
        return null;
    }
    return s;
}

fn jsonCommand(arena: std.mem.Allocator, command: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"command\":");
    try std.json.Stringify.value(command, .{}, &aw.writer);
    try aw.writer.writeByte('}');
    return aw.written();
}

test "sandbox required: bash writes inside the workspace, nothing outside it" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var other = try makeTmp();
    defer other.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var session = (try sandboxForTest(arena, io, tmp.dir, false)) orelse return error.SkipZigTest;
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.sandbox_fn = sandbox_mod.Session.wrapFn;
    ctx.sandbox_ctx = &session;

    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_path = other_buf[0..try other.dir.realPath(io, &other_buf)];
    // The directory above the workspace, for the `cd ..` escape.
    const parent_probe = try std.fmt.allocPrint(arena, "{s}/escape-ifnh-test", .{std.fs.path.dirname(session.policy.workspace).?});
    defer std.Io.Dir.cwd().deleteFile(io, parent_probe) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "/etc/ifnh-sandbox-test") catch {};

    // Allowed: a write in the workspace.
    // The test process does not run in `tmp`, so commands use absolute paths.
    const ws_path = session.policy.workspace;
    const inside_cmd = try std.fmt.allocPrint(arena, "echo sandboxed > {s}/inside.txt && cat {s}/inside.txt", .{ ws_path, ws_path });
    const inside = execute("bash", try jsonCommand(arena, inside_cmd), &ctx);
    try std.testing.expectEqual(Status.ok, inside.status);
    try std.testing.expect(std.mem.indexOf(u8, inside.output, "sandboxed") != null);
    try tmp.dir.access(io, "inside.txt", .{});

    // Allowed: reading outside the workspace, and /dev/null redirection.
    const read = execute("bash", try jsonCommand(arena, "head -c 1 /etc/passwd >/dev/null 2>/dev/null && echo read-ok"), &ctx);
    try std.testing.expectEqual(Status.ok, read.status);
    try std.testing.expect(std.mem.indexOf(u8, read.output, "read-ok") != null);

    // Denied: a write outside the workspace.
    const outside_cmd = try std.fmt.allocPrint(arena, "touch {s}/outside.txt", .{other_path});
    const outside = execute("bash", try jsonCommand(arena, outside_cmd), &ctx);
    try std.testing.expectEqual(Status.failed, outside.status);
    try std.testing.expectError(error.FileNotFound, other.dir.access(io, "outside.txt", .{}));

    // Denied: a write under /etc.
    const etc = execute("bash", try jsonCommand(arena, "echo x > /etc/ifnh-sandbox-test"), &ctx);
    try std.testing.expectEqual(Status.failed, etc.status);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "/etc/ifnh-sandbox-test", .{}));

    // Denied: leaving the workspace with `cd ..`.
    const esc_cmd = try std.fmt.allocPrint(arena, "cd {s}; set -e; cd ..; touch escape-ifnh-test", .{ws_path});
    const esc = execute("bash", try jsonCommand(arena, esc_cmd), &ctx);
    try std.testing.expectEqual(Status.failed, esc.status);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, parent_probe, .{}));
}

test "sandbox required: network is denied unless sandbox.network is on" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!programAvailableForTest(io, "bash")) {
        std.debug.print("SKIP sandbox network test: bash not found\n", .{});
        return error.SkipZigTest;
    }

    // A listener that never accepts: a connect completes in the kernel backlog.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    const connect = try std.fmt.allocPrint(arena, "bash -c 'exec 3<>/dev/tcp/127.0.0.1/{d} && echo connected'", .{srv.socket.address.getPort()});

    var denied_session = (try sandboxForTest(arena, io, tmp.dir, false)) orelse return error.SkipZigTest;
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.sandbox_fn = sandbox_mod.Session.wrapFn;
    ctx.sandbox_ctx = &denied_session;
    const denied = execute("bash", try jsonCommand(arena, connect), &ctx);
    try std.testing.expectEqual(Status.failed, denied.status);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "connected") == null);

    var open_session = (try sandboxForTest(arena, io, tmp.dir, true)) orelse return error.SkipZigTest;
    ctx.sandbox_ctx = &open_session;
    const allowed = execute("bash", try jsonCommand(arena, connect), &ctx);
    try std.testing.expectEqual(Status.ok, allowed.status);
    try std.testing.expect(std.mem.indexOf(u8, allowed.output, "connected") != null);
}

fn programAvailableForTest(io: std.Io, program: []const u8) bool {
    return search.programAvailable(io, program);
}

test "sandbox required without a usable backend fails the call instead of running open" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var session = sandbox_mod.Session{ .mode = .required, .backend = .none };
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.sandbox_fn = sandbox_mod.Session.wrapFn;
    ctx.sandbox_ctx = &session;

    const r = execute("bash", "{\"command\":\"touch must-not-exist.txt\"}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sandbox unavailable: ") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "must-not-exist.txt", .{}));

    // The human's `!cmd` path and the git tool never consult the sandbox.
    const shell = runShell(&ctx, "echo human-ok");
    try std.testing.expect(std.mem.indexOf(u8, shell.output, "human-ok") != null);
}

test "sandbox auto without a backend runs the command unsandboxed" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var session = sandbox_mod.Session{ .mode = .auto, .backend = .none };
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.sandbox_fn = sandbox_mod.Session.wrapFn;
    ctx.sandbox_ctx = &session;
    const r = execute("bash", "{\"command\":\"echo plain\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "plain") != null);
}

test "sandbox hook also guards data-defined custom tools" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var session = sandbox_mod.Session{ .mode = .required, .backend = .none };
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.sandbox_fn = sandbox_mod.Session.wrapFn;
    ctx.sandbox_ctx = &session;
    const defs = [_]CustomTool{.{
        .name = "say",
        .description = "say it",
        .command_template = "echo custom-ran",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        .permission = .exec,
        .timeout_s = 5,
    }};
    ctx.custom = &defs;
    const r = execute("say", "{}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sandbox unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "custom-ran") == null);
}
