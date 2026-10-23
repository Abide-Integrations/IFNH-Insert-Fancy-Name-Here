//! Tool contract, registry, and dispatch (DESIGN §3.2).
//!
//! M0 tools: read, glob, grep, edit, write, bash, git. Tool arguments are
//! JSON objects decoded with std.json. Mutating tools journal their file
//! operations (bash/git side effects are opaque and not journaled — they
//! are gated by approvals instead, DECISIONS M185-186).
//!
//! Every tool result is model-facing text, UTF-8-safe, and capped.

const std = @import("std");
const engine_mod = @import("../core/permissions/engine.zig");
const journal_mod = @import("../core/journal.zig");
const globm = @import("../core/permissions/glob.zig");
const cmd_class = @import("../core/permissions/command_class.zig");

pub const max_tool_output_bytes: usize = 64 * 1024;
pub const max_file_size_bytes: usize = 1024 * 1024;

pub const Status = enum { ok, denied, failed, timeout };

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
    mcp_ctx: ?*anyopaque = null,
    /// Delegation depth of the agent owning this context (0 = parent).
    agent_depth: usize = 0,
    /// Display label for approval provenance ("parent", "research-1"...).
    agent_label: []const u8 = "",
    /// Data-defined tools (D-02); built-ins always come from `registry`.
    custom_tools: []const ToolDef = &.{},

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

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// Permission class carried by each tool (DESIGN §3.3). The classifier
/// itself is unchanged; handlers still consult it exactly as before.
pub const PermissionClass = enum { read, write, command, mcp, internal };

const Handler = *const fn (def: *const ToolDef, a: Args, args_json: []const u8, ctx: *ToolContext) ToolResult;

pub const ToolDef = struct {
    spec: Spec,
    permission: PermissionClass,
    handler: Handler,
    /// Present only for data-defined tools (D-02).
    custom: ?Custom = null,

    pub const Custom = struct {
        /// Shell command template; `{{param}}` expands to a shell-quoted
        /// argument value.
        command: []const u8,
        /// Declared policy; combined with the engine (stricter wins).
        permission: CustomPermission,
    };
};

/// Permission policy declared by a custom tool file. It can only tighten
/// the engine's decision, never relax it.
pub const CustomPermission = enum { auto, ask, deny };

/// The registry: one row per tool. Adding a tool means adding a row here
/// (plus its handler); `execute` and `specs` both derive from this table.
pub const registry = [_]ToolDef{
    .{ .spec = .{ .name = "read", .description = "Read a text file with line numbers. Supports offset/limit for paging.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"0-based start line"},"limit":{"type":"integer"}},"required":["path"]}
    }, .permission = .read, .handler = dispatchRead },
    .{ .spec = .{ .name = "glob", .description = "List files matching a glob pattern (** crosses directories, * stays within one).", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}
    }, .permission = .read, .handler = dispatchGlob },
    .{ .spec = .{ .name = "grep", .description = "Literal substring search across repository text files.", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"subdirectory to search"}},"required":["pattern"]}
    }, .permission = .read, .handler = dispatchGrep },
    .{ .spec = .{ .name = "edit", .description = "Replace exactly one occurrence of old_string with new_string in a file. Refuses if the text appears zero or multiple times.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}
    }, .permission = .write, .handler = dispatchEdit },
    .{ .spec = .{ .name = "write", .description = "Create a file or overwrite it entirely. Prefer edit for existing files.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    }, .permission = .write, .handler = dispatchWrite },
    .{ .spec = .{ .name = "bash", .description = "Run a shell command in the workspace. Read-only commands run freely; anything that changes state requires approval.", .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
    }, .permission = .command, .handler = dispatchBash },
    .{ .spec = .{ .name = "skill", .description = "Load a named skill's full instructions from the installed skills catalog.", .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    }, .permission = .internal, .handler = dispatchSkill },
    .{ .spec = .{ .name = "mcp_list", .description = "List configured MCP servers and their tools.", .parameters_json =
    \\{"type":"object","properties":{}}
    }, .permission = .internal, .handler = dispatchMcpList },
    .{ .spec = .{ .name = "mcp_call", .description = "Call an MCP server tool. Server/tool must be permitted; calls require approval unless allowlisted.", .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"},"arguments":{"type":"object"}},"required":["server","tool"]}
    }, .permission = .mcp, .handler = dispatchMcpCall },
    .{ .spec = .{ .name = "agent", .description = "Delegate a self-contained task to a child agent. Roles: research (read-only), implement (may edit), review (read-only findings). The child works independently and returns a summary; its full report is stored under .ifnh/reports/.", .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string"},"role":{"type":"string","enum":["research","implement","review"]},"model":{"type":"string"}},"required":["task","role"]}
    }, .permission = .internal, .handler = dispatchAgent },
    .{ .spec = .{ .name = "exec", .description = "Manage background executions: status/output/stop/list by execution id.", .parameters_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["status","output","stop","list"]},"id":{"type":"integer"}},"required":["action"]}
    }, .permission = .internal, .handler = dispatchExec },
    .{ .spec = .{ .name = "read_tool_result", .description = "Read a stored oversized tool output artifact by id, with optional offset/limit paging.", .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["id"]}
    }, .permission = .read, .handler = dispatchReadResult },
    .{ .spec = .{ .name = "git", .description = "Run a git subcommand in the workspace (porcelain operations only).", .parameters_json =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}}},"required":["args"]}
    }, .permission = .command, .handler = dispatchGit },
};

/// Tool specs advertised to the model, generated from `registry`
/// (order = advertisement order).
pub const specs: [registry.len]Spec = blk: {
    var out: [registry.len]Spec = undefined;
    for (registry, 0..) |def, i| out[i] = def.spec;
    break :blk out;
};

/// Look a built-in tool up by name. Unknown names return null.
pub fn find(name: []const u8) ?*const ToolDef {
    for (&registry) |*def| {
        if (std.mem.eql(u8, def.spec.name, name)) return def;
    }
    return null;
}

/// Look a tool up by name, built-ins first, then data-defined tools.
pub fn findTool(name: []const u8, extra: []const ToolDef) ?*const ToolDef {
    if (find(name)) |def| return def;
    for (extra) |*def| {
        if (std.mem.eql(u8, def.spec.name, name)) return def;
    }
    return null;
}

// ----------------------------------------------------- custom tools (D-02)

pub const max_custom_tool_bytes: usize = 64 * 1024;
pub const max_custom_tools: usize = 64;

pub const CustomTools = struct {
    tools: []const ToolDef = &.{},
    /// Human-readable reasons files were skipped ("<path>: ... (skipped)").
    warnings: []const []const u8 = &.{},
};

/// Load data-defined tools from `~/.config/ifnh/tools/*.json` (user level)
/// and `.ifnh/tools/*.json` (project level). Project entries override user
/// entries with the same name; names that collide with a built-in tool are
/// rejected. Invalid files are reported in `warnings` and skipped; loading
/// never fails the session.
pub fn loadCustomTools(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    user_dir: ?[]const u8,
) CustomTools {
    var user: std.ArrayListUnmanaged(ToolDef) = .empty;
    var project: std.ArrayListUnmanaged(ToolDef) = .empty;
    var warnings: std.ArrayListUnmanaged([]const u8) = .empty;

    if (user_dir) |ud| collectCustomTools(arena, io, workspace, ud, &user, &warnings);
    collectCustomTools(arena, io, workspace, ".ifnh/tools", &project, &warnings);

    // Merge: project scope last so it overrides the user scope.
    var merged: std.ArrayListUnmanaged(ToolDef) = .empty;
    for (user.items) |t| merged.append(arena, t) catch break;
    for (project.items) |t| {
        var replaced = false;
        for (merged.items) |*m| {
            if (std.mem.eql(u8, m.spec.name, t.spec.name)) {
                m.* = t;
                replaced = true;
                break;
            }
        }
        if (!replaced) merged.append(arena, t) catch break;
    }
    return .{ .tools = merged.items, .warnings = warnings.items };
}

fn collectCustomTools(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    root: []const u8,
    out: *std.ArrayListUnmanaged(ToolDef),
    warnings: *std.ArrayListUnmanaged([]const u8),
) void {
    var dir = workspace.openDir(io, root, .{ .iterate = true }) catch return; // absent dir is normal
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (out.items.len >= max_custom_tools) {
            addWarning(arena, warnings, "{s}/{s}: too many custom tools (skipped)", .{ root, entry.name });
            continue;
        }
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.name }) catch continue;
        const content = workspace.readFileAlloc(io, path, arena, .limited(max_custom_tool_bytes)) catch {
            addWarning(arena, warnings, "{s}: cannot read (skipped)", .{path});
            continue;
        };
        const def = parseCustomTool(arena, content, path, warnings) orelse continue;
        out.append(arena, def) catch break;
    }
}

fn parseCustomTool(
    arena: std.mem.Allocator,
    content: []const u8,
    path: []const u8,
    warnings: *std.ArrayListUnmanaged([]const u8),
) ?ToolDef {
    const document = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch {
        addWarning(arena, warnings, "{s}: invalid JSON (skipped)", .{path});
        return null;
    };
    const obj = switch (document.value) {
        .object => |o| o,
        else => {
            addWarning(arena, warnings, "{s}: not a JSON object (skipped)", .{path});
            return null;
        },
    };

    const name = jsonStr(obj, "name") orelse {
        addWarning(arena, warnings, "{s}: missing string \"name\" (skipped)", .{path});
        return null;
    };
    if (!validToolName(name)) {
        addWarning(arena, warnings, "{s}: \"name\" must be 1-64 characters of [A-Za-z0-9_.-] (skipped)", .{path});
        return null;
    }
    if (find(name) != null) {
        addWarning(arena, warnings, "{s}: \"{s}\" shadows a built-in tool (skipped)", .{ path, name });
        return null;
    }

    const command = jsonStr(obj, "command") orelse {
        addWarning(arena, warnings, "{s}: missing string \"command\" (skipped)", .{path});
        return null;
    };
    if (std.mem.trim(u8, command, " \t").len == 0) {
        addWarning(arena, warnings, "{s}: empty \"command\" (skipped)", .{path});
        return null;
    }

    const permission_text = jsonStr(obj, "permission") orelse {
        addWarning(arena, warnings, "{s}: missing string \"permission\" (skipped)", .{path});
        return null;
    };
    const permission = std.meta.stringToEnum(CustomPermission, permission_text) orelse {
        addWarning(arena, warnings, "{s}: \"permission\" must be \"auto\", \"ask\" or \"deny\" (skipped)", .{path});
        return null;
    };

    const schema_json = blk: {
        const v = obj.get("input_schema") orelse break :blk "{\"type\":\"object\",\"properties\":{}}";
        if (v != .object) {
            addWarning(arena, warnings, "{s}: \"input_schema\" must be a JSON object (skipped)", .{path});
            return null;
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(v, .{}, &aw.writer) catch return null;
        break :blk aw.written();
    };

    return .{
        .spec = .{
            .name = name,
            .description = jsonStr(obj, "description") orelse "",
            .parameters_json = schema_json,
        },
        .permission = .command,
        .handler = dispatchCustom,
        .custom = .{ .command = command, .permission = permission },
    };
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

fn addWarning(
    arena: std.mem.Allocator,
    warnings: *std.ArrayListUnmanaged([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch return;
    warnings.append(arena, msg) catch {};
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
    const def = findTool(name, ctx.custom_tools) orelse
        return errResult(ctx.arena, "unknown tool '{s}'", .{name});
    return def.handler(def, .{ .obj = args.object }, args_json, ctx);
}

// ------------------------------------------------------------ dispatch

fn dispatchRead(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "read: missing path", .{});
    return toolRead(path, a.int("offset"), a.int("limit"), ctx);
}

fn dispatchGlob(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const pattern = a.str("pattern") orelse return errResult(ctx.arena, "glob: missing pattern", .{});
    return toolGlob(pattern, ctx);
}

fn dispatchGrep(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const pattern = a.str("pattern") orelse return errResult(ctx.arena, "grep: missing pattern", .{});
    const root = a.str("path") orelse "";
    return toolGrep(pattern, root, ctx);
}

fn dispatchEdit(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "edit: missing path", .{});
    const old_s = a.str("old_string") orelse return errResult(ctx.arena, "edit: missing old_string", .{});
    const new_s = a.str("new_string") orelse return errResult(ctx.arena, "edit: missing new_string", .{});
    return toolEdit(path, old_s, new_s, ctx);
}

fn dispatchWrite(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const path = a.str("path") orelse return errResult(ctx.arena, "write: missing path", .{});
    const content = a.str("content") orelse return errResult(ctx.arena, "write: missing content", .{});
    return toolWrite(path, content, ctx);
}

fn dispatchBash(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const command = a.str("command") orelse return errResult(ctx.arena, "bash: missing command", .{});
    const background = if (a.obj.get("background")) |b| (b == .bool and b.bool) else false;
    return toolBash(command, background, ctx);
}

fn dispatchSkill(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const load_fn = ctx.skill_load_fn orelse
        return errResult(ctx.arena, "skill: skills not available", .{});
    const skill_name = a.str("name") orelse return errResult(ctx.arena, "skill: missing name", .{});
    const body = load_fn(ctx.skill_ctx orelse ctx.approval_ctx, ctx.arena, skill_name) orelse
        return errResult(ctx.arena, "skill: '{s}' not found in catalog", .{skill_name});
    return .{ .output = body, .status = .ok };
}

fn dispatchExec(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
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

fn dispatchReadResult(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const artifact_id = a.str("id") orelse return errResult(ctx.arena, "read_tool_result: missing id", .{});
    return toolReadResult(artifact_id, a.int("offset"), a.int("limit"), ctx);
}

fn dispatchMcpList(_: *const ToolDef, _: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const list_fn = ctx.mcp_list_fn orelse
        return errResult(ctx.arena, "mcp_list: MCP not configured", .{});
    return .{ .output = list_fn(ctx.mcp_ctx orelse ctx.approval_ctx, ctx.arena), .status = .ok };
}

fn dispatchMcpCall(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
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

fn dispatchAgent(_: *const ToolDef, _: Args, args_json: []const u8, ctx: *ToolContext) ToolResult {
    const spawn_fn = ctx.agent_spawn_fn orelse
        return errResult(ctx.arena, "agent: delegation disabled", .{});
    const res = spawn_fn(ctx.agent_spawn_ctx orelse ctx.approval_ctx, ctx.arena, ctx.agent_depth, args_json);
    return .{
        .output = res.summary,
        .status = if (res.status == .completed) .ok else .failed,
    };
}

fn dispatchGit(_: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
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

fn dispatchCustom(def: *const ToolDef, a: Args, _: []const u8, ctx: *ToolContext) ToolResult {
    const custom = def.custom orelse
        return errResult(ctx.arena, "{s}: definition has no command template", .{def.spec.name});

    var bad_param: ?[]const u8 = null;
    const command = substituteCommand(ctx.arena, custom.command, a, &bad_param) catch |err| switch (err) {
        error.MissingParam => return errResult(ctx.arena, "{s}: missing argument '{s}'", .{ def.spec.name, bad_param orelse "" }),
        error.UnsupportedParam => return errResult(ctx.arena, "{s}: argument '{s}' must be a string, number or bool", .{ def.spec.name, bad_param orelse "" }),
        else => return errResult(ctx.arena, "{s}: out of memory", .{def.spec.name}),
    };

    // Same classifier as bash; the file's permission can only tighten it.
    switch (stricterDecision(ctx.engine.decideCommand(command), custom.permission)) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "{s} '{s}'", .{ def.spec.name, command }),
        .ask => {
            if (!ctx.requestApproval("run custom tool", command, .{ .command_prefix = commandPrefixOf(command) }))
                return deniedResult(ctx.arena, "{s} '{s}' (declined)", .{ def.spec.name, command });
        },
    }
    return runCaptured(ctx, &.{ "/bin/sh", "-c", command }, "");
}

fn stricterDecision(engine_decision: engine_mod.Decision, declared: CustomPermission) engine_mod.Decision {
    const declared_decision: engine_mod.Decision = switch (declared) {
        .auto => .allow,
        .ask => .ask,
        .deny => .deny,
    };
    return if (rank(engine_decision) >= rank(declared_decision)) engine_decision else declared_decision;
}

fn rank(decision: engine_mod.Decision) u8 {
    return switch (decision) {
        .allow => 0,
        .ask => 1,
        .deny => 2,
    };
}

/// Expand `{{param}}` placeholders; every value is inserted as a single
/// shell-quoted word, so arguments cannot break out of the template.
fn substituteCommand(
    arena: std.mem.Allocator,
    template: []const u8,
    a: Args,
    bad_param: *?[]const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const open = std.mem.indexOfPos(u8, template, i, "{{") orelse {
            try out.appendSlice(arena, template[i..]);
            break;
        };
        try out.appendSlice(arena, template[i..open]);
        const close = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse {
            try out.appendSlice(arena, template[open..]);
            break;
        };
        const key = std.mem.trim(u8, template[open + 2 .. close], " \t");
        bad_param.* = key;
        const value = a.obj.get(key) orelse return error.MissingParam;
        const text = switch (value) {
            .string => |v| v,
            .integer => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
            .float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
            .bool => |v| if (v) "true" else "false",
            else => return error.UnsupportedParam,
        };
        try appendShellQuoted(arena, &out, text);
        i = close + 2;
    }
    return out.items;
}

fn appendShellQuoted(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(arena, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
}
// ---------------------------------------------------------------- read

fn toolRead(path: []const u8, offset: ?usize, limit: ?usize, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, path)) {
        .allow => {},
        .ask => return deniedResult(ctx.arena, "read '{s}' not covered by read policy", .{path}),
        .deny => return deniedResult(ctx.arena, "read '{s}'", .{path}),
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

fn grepFile(ctx: *ToolContext, rel: []const u8, pattern: []const u8, limits: *WalkLimits, out: *std.ArrayListUnmanaged(u8)) void {
    const data = ctx.workspace.readFileAlloc(ctx.io, rel, ctx.arena, .limited(max_file_size_bytes)) catch return;
    if (!std.unicode.utf8ValidateSlice(data)) return; // skip binary
    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    var file_hits: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        if (file_hits >= 10 or limits.max_matches == 0) return;
        if (std.mem.indexOf(u8, line, pattern) != null) {
            out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, std.mem.trimEnd(u8, line, "\r") }) catch return;
            file_hits += 1;
            limits.max_matches -= 1;
        }
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
    const run = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdout_limit = .limited(max_tool_output_bytes),
        .stderr_limit = .limited(32 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(120) } },
    }) catch |err| switch (err) {
        error.Timeout => return .{ .output = "error: command timed out after 120s", .status = .timeout },
        error.FileNotFound => return errResult(ctx.arena, "command not found: {s}", .{argv[0]}),
        else => return errResult(ctx.arena, "spawn failed: {s}", .{@errorName(err)}),
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (run.stdout.len > 0) {
        out.print(ctx.arena, "<stdout>\n{s}\n</stdout>\n", .{run.stdout}) catch {};
    }
    if (run.stderr.len > 0) {
        out.print(ctx.arena, "<stderr>\n{s}\n</stderr>\n", .{run.stderr}) catch {};
    }
    switch (run.term) {
        .exited => |code| {
            if (code != 0) out.print(ctx.arena, "exit code: {d}\n", .{code}) catch {};
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
    const failed = switch (run.term) {
        .exited => |code| code != 0,
        else => true,
    };
    return .{ .output = body, .status = if (failed) .failed else .ok };
}

fn toolBash(command: []const u8, background: bool, ctx: *ToolContext) ToolResult {
    // Compound commands go through the user's shell; simple ones run directly
    // (DECISIONS I120). Compound detection is the classifier's job anyway.
    const effect = cmd_class.classify(command);
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

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.mem.indexOfAny(u8, command, "|;&<>()`") != null) {
        const shell = ctx.engine.alloc.dupe(u8, "/bin/sh") catch return errResult(ctx.arena, "oom", .{});
        const flag = ctx.engine.alloc.dupe(u8, "-c") catch return errResult(ctx.arena, "oom", .{});
        const cmd = ctx.engine.alloc.dupe(u8, command) catch return errResult(ctx.arena, "oom", .{});
        argv.append(ctx.arena, shell) catch {};
        argv.append(ctx.arena, flag) catch {};
        argv.append(ctx.arena, cmd) catch {};
    } else {
        var it = std.mem.tokenizeAny(u8, command, " \t");
        while (it.next()) |tok| {
            argv.append(ctx.arena, tok) catch {};
        }
    }
    if (argv.items.len == 0) return errResult(ctx.arena, "bash: empty command", .{});

    const result = runCaptured(ctx, argv.items, "");
    // Note: shell side effects are not journaled (M185); surfaced in audit log instead.
    _ = effect;
    return result;
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

    // Data-defined tools are policy too (ADR-0004): an agent cannot author
    // a tool that would run with its declared permission next session.
    const t = execute("write", "{\"path\":\".ifnh/tools/evil.json\",\"content\":\"{}\"}", &ctx);
    try std.testing.expectEqual(Status.denied, t.status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".ifnh/tools/evil.json", .{}));
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

test "tool registry: schemas parse as JSON and names are unique" {
    for (registry, 0..) |def, i| {
        try std.testing.expect(def.spec.name.len > 0);
        try std.testing.expect(def.spec.description.len > 0);
        const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, def.spec.parameters_json, .{}) catch |err| {
            std.debug.print("tool '{s}' has an invalid input schema: {s}\n", .{ def.spec.name, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        // The advertised specs array is generated from this same row.
        try std.testing.expectEqualStrings(def.spec.name, specs[i].name);
        try std.testing.expectEqualStrings(def.spec.parameters_json, specs[i].parameters_json);
        for (registry[0..i]) |other| {
            try std.testing.expect(!std.mem.eql(u8, def.spec.name, other.spec.name));
        }
    }
    try std.testing.expectEqual(registry.len, specs.len);

    // Permission classes travel with the row.
    try std.testing.expectEqual(PermissionClass.read, find("read").?.permission);
    try std.testing.expectEqual(PermissionClass.write, find("edit").?.permission);
    try std.testing.expectEqual(PermissionClass.command, find("bash").?.permission);
    try std.testing.expectEqual(PermissionClass.mcp, find("mcp_call").?.permission);
}

test "tool registry: unknown tool name returns the documented error" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    try std.testing.expect(find("no_such_tool") == null);
    try std.testing.expect(find("read") != null);

    const r = execute("no_such_tool", "{}", &ctx);
    try std.testing.expectEqual(Status.failed, r.status);
    try std.testing.expectEqualStrings("error: unknown tool 'no_such_tool'", r.output);
}

fn writeToolFile(io: std.Io, dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    try dir.createDirPath(io, ".ifnh/tools");
    try dir.writeFile(io, .{ .sub_path = name, .data = body });
}

test "custom tools: a valid file registers a callable tool" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try writeToolFile(io, tmp.dir, ".ifnh/tools/say.json",
        \\{"name":"say","description":"Say hello.","input_schema":{"type":"object","properties":{"who":{"type":"string"}},"required":["who"]},"command":"echo hello {{who}}","permission":"auto"}
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = loadCustomTools(arena, io, tmp.dir, null);
    try std.testing.expectEqual(@as(usize, 0), loaded.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.tools.len);
    try std.testing.expectEqualStrings("say", loaded.tools[0].spec.name);
    try std.testing.expect(findTool("say", loaded.tools) != null);
    try std.testing.expect(findTool("say", &.{}) == null);

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.custom_tools = loaded.tools;

    const r = execute("say", "{\"who\":\"bob\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hello bob") != null);

    // Arguments are substituted as one shell-quoted word.
    const quoted = execute("say", "{\"who\":\"a; touch pwned\"}", &ctx);
    try std.testing.expectEqual(Status.ok, quoted.status);
    try std.testing.expect(std.mem.indexOf(u8, quoted.output, "hello a; touch pwned") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "pwned", .{}));

    const missing = execute("say", "{}", &ctx);
    try std.testing.expectEqual(Status.failed, missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.output, "missing argument 'who'") != null);
}

test "custom tools: malformed files are skipped with a warning" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try writeToolFile(io, tmp.dir, ".ifnh/tools/bad.json", "{ this is not json");
    try writeToolFile(io, tmp.dir, ".ifnh/tools/shadow.json",
        \\{"name":"read","command":"echo shadow","permission":"auto"}
    );
    try writeToolFile(io, tmp.dir, ".ifnh/tools/noperm.json",
        \\{"name":"noperm","command":"echo hi","permission":"sometimes"}
    );
    try writeToolFile(io, tmp.dir, ".ifnh/tools/good.json",
        \\{"name":"good","description":"Good.","input_schema":{"type":"object","properties":{}},"command":"echo good","permission":"ask"}
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = loadCustomTools(arena, io, tmp.dir, null);
    try std.testing.expectEqual(@as(usize, 3), loaded.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.tools.len);
    try std.testing.expectEqualStrings("good", loaded.tools[0].spec.name);

    var saw_bad = false;
    var saw_shadow = false;
    var saw_noperm = false;
    for (loaded.warnings) |w| {
        if (std.mem.indexOf(u8, w, "bad.json") != null) saw_bad = true;
        if (std.mem.indexOf(u8, w, "shadow.json") != null and std.mem.indexOf(u8, w, "built-in") != null) saw_shadow = true;
        if (std.mem.indexOf(u8, w, "noperm.json") != null and std.mem.indexOf(u8, w, "permission") != null) saw_noperm = true;
    }
    try std.testing.expect(saw_bad);
    try std.testing.expect(saw_shadow);
    try std.testing.expect(saw_noperm);

    // Built-in dispatch is untouched by the rejected file.
    try std.testing.expect(find("read") != null);
}

test "custom tools: the declared permission class is honoured" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try writeToolFile(io, tmp.dir, ".ifnh/tools/denied.json",
        \\{"name":"denied_tool","command":"echo {{who}}","permission":"deny"}
    );
    try writeToolFile(io, tmp.dir, ".ifnh/tools/asked.json",
        \\{"name":"asked_tool","command":"echo {{who}}","permission":"ask"}
    );
    try writeToolFile(io, tmp.dir, ".ifnh/tools/auto.json",
        \\{"name":"auto_tool","command":"echo {{who}}","permission":"auto"}
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const loaded = loadCustomTools(arena, io, tmp.dir, null);
    try std.testing.expectEqual(@as(usize, 0), loaded.warnings.len);
    try std.testing.expectEqual(@as(usize, 3), loaded.tools.len);

    const Denier = struct {
        fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied;
        }
    };
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var ctx = testCtx(arena, io, tmp.dir, &e);
    ctx.custom_tools = loaded.tools;
    ctx.approval_fn = Denier.approve;

    // "deny" overrides an engine .allow (echo is read-only for the classifier).
    try std.testing.expectEqual(engine_mod.Decision.allow, e.decideCommand("echo hi"));
    const denied = execute("denied_tool", "{\"who\":\"hi\"}", &ctx);
    try std.testing.expectEqual(Status.denied, denied.status);

    // "ask" prompts even when the engine allows; the denier wins.
    const asked = execute("asked_tool", "{\"who\":\"hi\"}", &ctx);
    try std.testing.expectEqual(Status.denied, asked.status);

    // "auto" adds no restriction: no prompt is consulted.
    const auto = execute("auto_tool", "{\"who\":\"hi\"}", &ctx);
    try std.testing.expectEqual(Status.ok, auto.status);
    try std.testing.expect(std.mem.indexOf(u8, auto.output, "hi") != null);
}
