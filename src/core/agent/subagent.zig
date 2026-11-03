//! Subagent runtime (M1-T01/T02, DECISIONS section E).
//!
//! A child agent is a full agent runtime instance with its own history,
//! role-scoped permission engine, and arena — spawned via the `agent`
//! tool. Children never exceed the parent's permission ceiling (D015):
//! they inherit the parent's policy snapshot with an empty grant list.
//! Each child writes a durable Markdown report under `.ifnh/reports/`
//! (PLAN §19) and returns a structured summary to the parent (D011).
//!
//! Parallelism (E58): consecutive `agent` tool calls in one round execute
//! on threads (engine.zig); this module is synchronous per spawn, so it is
//! safe from any thread. Shared state (journal, counters) is synchronized.

const std = @import("std");
const core_types = @import("../types.zig");
const provider_mod = @import("../../providers/provider.zig");
const agent_engine = @import("engine.zig");
const tool_mod = @import("../../tools/tool.zig");
const engine_mod = @import("../permissions/engine.zig");
const journal_mod = @import("../journal.zig");
const fsutil = @import("../fsutil.zig");
const git_mod = @import("../git.zig");
const mcp_mod = @import("../mcp.zig");

pub const max_summary_bytes: usize = 4 * 1024;

pub const Role = enum { research, implement, review };

fn parseRole(s: []const u8) ?Role {
    if (std.mem.eql(u8, s, "research")) return .research;
    if (std.mem.eql(u8, s, "implement")) return .implement;
    if (std.mem.eql(u8, s, "review")) return .review;
    return null;
}

/// Model settings for one child role (D45). Provider, base URL, key and
/// model switch together, so a child can never mix one provider's endpoint
/// with another provider's credential.
pub const ChildModel = struct {
    provider: provider_mod.Provider,
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    provider_options: []const u8 = "",
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
};

/// Role -> model table for children. Resolved once per turn on the parent
/// thread: a `config.Store` must not be read from a child thread.
pub const ChildModels = struct {
    research: ?ChildModel = null,
    implement: ?ChildModel = null,
    review: ?ChildModel = null,
    /// Every configured alias (plus "default"); an explicit `model` on an
    /// `agent` call is looked up here, never used as a literal model id.
    aliases: []const NamedModel = &.{},

    pub const NamedModel = struct { name: []const u8, model: ChildModel };

    pub fn alias(self: *const ChildModels, name: []const u8) ?ChildModel {
        for (self.aliases) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.model;
        }
        return null;
    }

    pub const roles = [_][]const u8{ "research", "implement", "review" };

    pub fn set(self: *ChildModels, role: []const u8, model: ChildModel) void {
        if (std.mem.eql(u8, role, "research")) {
            self.research = model;
        } else if (std.mem.eql(u8, role, "implement")) {
            self.implement = model;
        } else if (std.mem.eql(u8, role, "review")) {
            self.review = model;
        }
    }

    pub fn get(self: *const ChildModels, role: []const u8) ?ChildModel {
        if (std.mem.eql(u8, role, "research")) return self.research;
        if (std.mem.eql(u8, role, "implement")) return self.implement;
        if (std.mem.eql(u8, role, "review")) return self.review;
        return null;
    }
};

/// Authority snapshot captured once per spawn (fx admission-snapshot
/// pattern): everything a child needs, borrowed from stable memory.
pub const Host = struct {
    io: std.Io,
    workspace: std.Io.Dir,
    base_system: []const u8,
    provider: provider_mod.Provider,
    base_url: []const u8,
    api_key: []const u8,
    default_model: []const u8,
    /// Session-owned HTTP client shared by child turns (B-02).
    client: ?*std.http.Client = null,
    // Parent permission snapshot (borrowed slices, stable for the session).
    mode: engine_mod.Mode,
    read_globs: []const []const u8,
    write_globs: []const []const u8,
    command_allow: []const []const u8,
    command_deny: []const []const u8,
    env_allow: []const []const u8,
    /// `git.*` / `permissions.read_dotenv` ceilings inherited from the parent
    /// config (A-T07). Defaults are the fail-closed ones.
    git_commits: engine_mod.GitPolicy = .ask,
    git_push: engine_mod.GitPolicy = .never,
    git_force_push: engine_mod.GitPolicy = .never,
    read_dotenv: bool = false,
    /// `tools.external`: let the child use `rg`/`fd` when present.
    use_external_tools: bool = true,
    /// Custom tools inherited from the parent run (D-02).
    custom: []const tool_mod.CustomTool = &.{},
    /// `agents.timeout_tool_s` for the child's captured commands.
    timeout_tool_s: u32 = 120,
    journal: ?*journal_mod.Journal,
    approval_ctx: *anyopaque,
    approval_fn: *const fn (ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse,
    max_depth: usize,
    max_concurrent: usize,
    max_rounds: usize,
    redactions: []const []const u8,
    /// Sampling settings of the inherited (parent) model; a routed child
    /// role carries its own in `ChildModel`.
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    /// Compiled provider options of the inherited model (D-05).
    provider_options: []const u8 = "",
    /// Per-role model table (D45); null keeps the parent's model.
    routing: ?*const ChildModels = null,
    cancel: *std.atomic.Value(bool),
    active: std.atomic.Value(u32) = .init(0),
    report_seq: std.atomic.Value(u32) = .init(0),
    /// Git access for worktree isolation (null = worktrees unavailable).
    git: ?git_mod.Git = null,
    /// Where agent worktrees are created (absolute, outside the repo).
    worktree_root: ?[]const u8 = null,
    /// Session hint used in worktree/branch names.
    session_hint: []const u8 = "s",
    /// The parent's MCP registry (borrowed). A child never uses it directly:
    /// it gets its own `forAgent` view with no live clients (E-03).
    mcp: ?*const mcp_mod.Registry = null,
};

fn rolePreamble(arena: std.mem.Allocator, role: Role, label: []const u8) ![]const u8 {
    return switch (role) {
        .research => try std.fmt.allocPrint(arena,
            \\You are {s}, a research subagent. You are read-only: gather facts,
            \\read code, run read-only commands, and report findings. Do not
            \\attempt to modify anything. Structure your final message as your
            \\report with these sections: Findings, Decisions, Open Questions,
            \\Recommended Next Action. Be dense and specific.
            \\
            \\
        , .{label}),
        .implement => try std.fmt.allocPrint(arena,
            \\You are {s}, an implementation subagent. Make the changes your task
            \\describes using the edit/write tools, verify with tests where
            \\possible, and report. Structure your final message as your report
            \\with these sections: Changes Made, Files Changed, Tests Performed,
            \\Risks, Open Questions. Patch-first: prefer edit over write.
            \\
            \\
        , .{label}),
        .review => try std.fmt.allocPrint(arena,
            \\You are {s}, a review subagent. You are read-only: inspect the
            \\diff/code/tests you are given and report findings. Structure your
            \\final message as your report with sections: Findings (each with
            \\severity blocker|major|minor|info), Risks, Open Questions.
            \\
            \\
        , .{label}),
    };
}

/// The `agent` tool hook. Runs synchronously; the engine's parallel batch
/// provides thread-level concurrency across consecutive agent calls.
pub fn spawnHook(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    parent_depth: usize,
    arguments_json: []const u8,
) tool_mod.AgentSpawnResult {
    const host: *Host = @ptrCast(@alignCast(ctx));

    // Parse arguments.
    var task: []const u8 = "";
    var role: Role = .implement;
    var model: ?[]const u8 = null; // alias name
    var isolation_worktree = false;
    {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch
            return fail(arena, "agent: invalid arguments", .{});
        if (v != .object) return fail(arena, "agent: arguments must be an object", .{});
        const o = v.object;
        const task_v = o.get("task") orelse return fail(arena, "agent: missing task", .{});
        if (task_v != .string) return fail(arena, "agent: task must be a string", .{});
        task = task_v.string;
        if (o.get("role")) |r| {
            if (r == .string) {
                role = parseRole(r.string) orelse return fail(arena, "agent: unknown role '{s}'", .{r.string});
            }
        }
        if (o.get("model")) |m| {
            if (m == .string and m.string.len > 0) model = m.string;
        }
        if (o.get("isolation")) |iso| {
            if (iso == .string and std.mem.eql(u8, iso.string, "worktree")) isolation_worktree = true;
        }
    }

    var chosen_alias: ?ChildModel = null;
    if (model) |name| {
        chosen_alias = if (host.routing) |r| r.alias(name) else null;
        if (chosen_alias == null) return fail(arena, "agent: unknown alias '{s}' (the model argument names an entry of models.aliases, or \"default\")", .{name});
    }

    if (host.cancel.load(.acquire)) return fail(arena, "agent: cancelled", .{});
    if (parent_depth + 1 > host.max_depth) {
        return fail(arena, "agent: max delegation depth {d} exceeded", .{host.max_depth});
    }
    _ = host.active.fetchAdd(1, .acq_rel);
    defer _ = host.active.fetchSub(1, .acq_rel);

    const label = std.fmt.allocPrint(arena, "{s}-{d}", .{ @tagName(role), host.report_seq.load(.monotonic) + 1 }) catch "child";
    const result = runChild(host, arena, task, role, chosen_alias, parent_depth, label, isolation_worktree);
    return result;
}

const WorktreeInfo = struct {
    path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    note: []const u8 = "",
};

/// Create an isolated git worktree for the child (D009, L164-166).
fn prepareWorktree(host: *Host, arena: std.mem.Allocator, label: []const u8) WorktreeInfo {
    const git = host.git orelse return .{ .note = "worktree isolation unavailable (not a git repository); child runs in the main workspace" };
    const root = host.worktree_root orelse return .{ .note = "worktree root not configured; child runs in the main workspace" };
    const name = std.fmt.allocPrint(arena, "ifnh-{s}-{s}", .{ host.session_hint, label }) catch return .{};
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, name }) catch return .{};
    const branch = std.fmt.allocPrint(arena, "ifnh/{s}/{s}", .{ host.session_hint, label }) catch return .{};
    git.addWorktree(arena, path, branch) catch |err| {
        return .{ .note = std.fmt.allocPrint(arena, "worktree creation failed ({s}); child runs in the main workspace", .{@errorName(err)}) catch "" };
    };
    return .{ .path = path, .branch = branch };
}

fn fail(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) tool_mod.AgentSpawnResult {
    const msg = std.fmt.allocPrint(arena, "error: " ++ fmt, args) catch "error: agent spawn failed";
    return .{ .status = .failed, .summary = msg };
}

fn runChild(
    host: *Host,
    parent_arena: std.mem.Allocator,
    task: []const u8,
    role: Role,
    explicit: ?ChildModel,
    parent_depth: usize,
    label: []const u8,
    isolation_worktree: bool,
) tool_mod.AgentSpawnResult {
    // Child gets its own arena (thread isolation; freed before return).
    var child_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer child_arena_state.deinit();
    const child_arena = child_arena_state.allocator();

    // Worktree isolation (D009): the child operates inside its own tree.
    var child_workspace = host.workspace;
    var wt = WorktreeInfo{};
    if (isolation_worktree) {
        wt = prepareWorktree(host, parent_arena, label);
        if (wt.path) |p| {
            child_workspace = std.Io.Dir.openDirAbsolute(host.io, p, .{ .access_sub_paths = true }) catch host.workspace;
        }
    }

    // Role-scoped engine: research/review are read-only (D015).
    var child_engine = engine_mod.Engine.init(child_arena, host.mode);
    child_engine.read_globs = host.read_globs;
    child_engine.command_allow = host.command_allow;
    child_engine.command_deny = host.command_deny;
    child_engine.env_allow = host.env_allow;
    child_engine.git_commits = host.git_commits;
    child_engine.git_push = host.git_push;
    child_engine.git_force_push = host.git_force_push;
    child_engine.read_dotenv = host.read_dotenv;
    child_engine.write_globs = switch (role) {
        .implement => host.write_globs,
        .research, .review => &.{},
    };

    // MCP for the child: the servers its role is allowlisted for, started on
    // demand and shut down when the child finishes.
    var child_mcp: ?mcp_mod.Registry = if (host.mcp) |parent_reg| parent_reg.forAgent(child_arena, @tagName(role)) else null;
    defer if (child_mcp) |*reg| reg.deinit();

    var child_tool_ctx = tool_mod.ToolContext{
        .io = host.io,
        .arena = child_arena,
        .workspace = child_workspace,
        .engine = &child_engine,
        .journal = host.journal,
        .max_file_read_bytes = 256 * 1024,
        .timeout_s = host.timeout_tool_s,
        .use_external_tools = host.use_external_tools,
        .custom = host.custom,
        .approval_ctx = host.approval_ctx,
        .approval_fn = host.approval_fn,
        .agent_spawn_fn = spawnHookFn,
        .agent_spawn_ctx = host,
        .agent_depth = parent_depth + 1,
        .agent_label = label,
        .mcp_list_fn = if (child_mcp != null) mcp_mod.listHook else null,
        .mcp_call_fn = if (child_mcp != null) mcp_mod.callHook else null,
        .mcp_describe_fn = if (child_mcp != null) mcp_mod.describeHook else null,
        .mcp_ctx = if (child_mcp) |*reg| reg else null,
    };

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    history.append(child_arena, .{ .role = .user, .content = task }) catch
        return fail(parent_arena, "agent: out of memory", .{});

    const preamble = rolePreamble(child_arena, role, label) catch
        return fail(parent_arena, "agent: out of memory", .{});
    const system = std.fmt.allocPrint(child_arena, "{s}{s}", .{
        preamble,
        host.base_system,
    }) catch return fail(parent_arena, "agent: out of memory", .{});

    // An explicit `model` alias on the tool call wins (resolved by
    // `spawnHook`); otherwise `routing.<role>` picks the whole bundle (D45).
    // No routing entry keeps the parent's.
    var chosen = ChildModel{
        .provider = host.provider,
        .model = host.default_model,
        .base_url = host.base_url,
        .api_key = host.api_key,
        .provider_options = host.provider_options,
        .temperature = host.temperature,
        .max_output_tokens = host.max_output_tokens,
    };
    if (explicit) |e| {
        chosen = e;
    } else if (host.routing) |routing| {
        if (routing.get(@tagName(role))) |routed| chosen = routed;
    }

    const outcome = agent_engine.runTurn(.{
        .io = host.io,
        .arena = child_arena,
        .pcfg = .{
            .provider = chosen.provider,
            .model = chosen.model,
            .base_url = chosen.base_url,
            .api_key = chosen.api_key,
            .client = host.client,
            .provider_options = chosen.provider_options,
            .temperature = chosen.temperature,
            .max_output_tokens = chosen.max_output_tokens,
        },
        .system = system,
        .history = &history,
        .tool_ctx = &child_tool_ctx,
        .callbacks = .{
            .ctx = undefined,
            .on_text = noopText,
            .on_tool_start = noopStart,
            .on_tool_result = noopResult,
            .on_notice = noopNotice,
        },
        .cancel = host.cancel,
        .max_tool_rounds = host.max_rounds,
        .redactions = host.redactions,
        .temperature = chosen.temperature,
        .max_output_tokens = chosen.max_output_tokens,
    }) catch |err| {
        return fail(parent_arena, "agent: child turn failed: {s}", .{@errorName(err)});
    };

    // Diff summary for worktree-isolated children (L172 preview).
    var diff_note: []const u8 = "";
    if (wt.path) |wp| {
        if (host.git) |g| {
            const diff = g.diffWorktree(parent_arena, wp);
            if (diff.len > 0) {
                const max_diff: usize = 2 * 1024;
                diff_note = std.fmt.allocPrint(parent_arena, "\nworktree diff ({s}):\n{s}", .{
                    wt.branch orelse "?",
                    if (diff.len > max_diff) diff[0..max_diff] else diff,
                }) catch "";
            }
        }
    }

    // Durable report (PLAN §19). Path is copied to the parent arena — the
    // child arena dies on return.
    const report_path_child = writeReport(host, child_arena, task, role, label, outcome, wt) catch "";
    const report_path = parent_arena.dupe(u8, report_path_child) catch "";

    // Structured result for the parent's model context (bounded).
    const summary = if (outcome.reply.len > max_summary_bytes) outcome.reply[0..max_summary_bytes] else outcome.reply;
    const envelope = std.fmt.allocPrint(
        parent_arena,
        "subagent {s} {s}\nreport: {s}\ntool_calls: {d}{s}{s}\n\n{s}",
        .{
            label,
            @tagName(outcome.status),
            report_path,
            outcome.tool_calls,
            if (wt.branch) |b| std.fmt.allocPrint(parent_arena, "\nbranch: {s}\nworktree: {s}", .{ b, wt.path.? }) catch "" else "",
            diff_note,
            summary,
        },
    ) catch return fail(parent_arena, "agent: out of memory", .{});

    return .{
        .status = switch (outcome.status) {
            .completed => .completed,
            .failed, .cancelled => .failed,
        },
        .summary = envelope,
        .report_path = report_path,
        .tool_calls = outcome.tool_calls,
    };
}

fn writeReport(
    host: *Host,
    arena: std.mem.Allocator,
    task: []const u8,
    role: Role,
    label: []const u8,
    outcome: agent_engine.Outcome,
    wt: WorktreeInfo,
) ![]const u8 {
    host.workspace.createDirPath(host.io, ".ifnh/reports") catch {};
    const seq = host.report_seq.fetchAdd(1, .monotonic);
    const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(host.io, .real).nanoseconds, std.time.ns_per_ms));
    const name = std.fmt.allocPrint(arena, "report-{d}-{d}-{s}.md", .{ ts_ms, seq, @tagName(role) }) catch return error.OutOfMemory;
    const rel = std.fmt.allocPrint(arena, ".ifnh/reports/{s}", .{name}) catch return error.OutOfMemory;

    const content = std.fmt.allocPrint(arena,
        \\# Agent Report ({s})
        \\
        \\- role: {s}
        \\- worktree: {s}
        \\- status: {s}
        \\- ts_ms: {d}
        \\- tool_calls: {d}
        \\- tokens: {d} in / {d} out
        \\
        \\## Assignment
        \\
        \\{s}
        \\
        \\## Report
        \\
        \\{s}
        \\
    , .{
        label,
        @tagName(role),
        if (wt.path) |p| p else "none",
        @tagName(outcome.status),
        ts_ms,
        outcome.tool_calls,
        outcome.usage.input_tokens,
        outcome.usage.output_tokens,
        task,
        outcome.reply,
    }) catch return error.OutOfMemory;

    try fsutil.atomicWriteFile(host.workspace, host.io, arena, rel, content);
    return rel;
}

fn noopText(_: *anyopaque, _: []const u8) void {}
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
fn noopNotice(_: *anyopaque, _: []const u8) void {}

/// Tool-level adapter (matches tool_mod.ToolContext.agent_spawn_fn).
pub fn spawnHookFn(ctx: *anyopaque, arena: std.mem.Allocator, parent_depth: usize, arguments_json: []const u8) tool_mod.AgentSpawnResult {
    return spawnHook(ctx, arena, parent_depth, arguments_json);
}

// ---------------------------------------------------------------- tests

const testing = @import("testing.zig");

test "child agent runs its own script and writes a durable report" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    // The child agent answers from its own scripted provider.
    var child_fake = testing.Fake{ .script = &.{
        &.{.{ .text = "Findings: the answer is 42. Open Questions: none." }},
    } };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "base rules",
        .provider = child_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{"**"},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn deny(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
                return .denied;
            }
        }.deny,
        .max_depth = 1,
        .max_concurrent = 2,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
    };

    const result = spawnHook(&host, arena, 0, "{\"task\":\"find the answer\",\"role\":\"research\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "the answer is 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "report: .ifnh/reports/") != null);
    try std.testing.expect(result.report_path.len > 0);

    // Report is durable and contains the child's reply.
    const data = try tmp.dir.readFileAlloc(io, result.report_path, arena, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, data, "# Agent Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "role: research") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "the answer is 42") != null);
}

test "delegation depth is enforced" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parent_fake = testing.Fake{ .script = &.{
        &.{.{ .text = "unused" }},
    } };
    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "",
        .provider = parent_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = undefined,
        .max_depth = 1,
        .max_concurrent = 1,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
    };

    // depth 0 -> 1 is allowed; depth 1 -> 2 is not.
    const ok = spawnHook(&host, arena, 0, "{\"task\":\"x\",\"role\":\"research\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, ok.status);
    const blocked = spawnHook(&host, arena, 1, "{\"task\":\"x\",\"role\":\"research\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.failed, blocked.status);
    try std.testing.expect(std.mem.indexOf(u8, blocked.summary, "depth") != null);
}

test "research role has no write access" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "hello\n" });

    var child_fake = testing.Fake{ .script = &.{
        &.{.{ .tool_call = .{ .id = "c1", .name = "write", .arguments_json = "{\"path\":\"code.txt\",\"content\":\"hacked\"}" } }},
        &.{.{ .text = "Write was denied; nothing changed." }},
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "",
        .provider = child_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{"**"}, // parent CAN write; research child must not
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn deny(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
                return .denied;
            }
        }.deny,
        .max_depth = 1,
        .max_concurrent = 1,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
    };

    const result = spawnHook(&host, arena, 0, "{\"task\":\"modify\",\"role\":\"research\"}");
    // The child ran; its write was denied (approval denied because engine says ask
    // and approver denies). The file must be untouched.
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, result.status);
    const data = try tmp.dir.readFileAlloc(io, "code.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("hello\n", data);
}

test "worktree isolation: child edits land in its own tree" {
    const io = std.testing.io;
    const git_avail = blk: {
        const r = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "git", "--version" } }) catch break :blk false;
        const ok = r.term == .exited and r.term.exited == 0;
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
        break :blk ok;
    };
    if (!git_avail) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const repo_path = try arena.dupe(u8, path_buf[0..n]);

    // Real repo with a committed seed file.
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "init", "-q", "-b", "main" }, .cwd = .{ .path = repo_path } }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "original\n" });
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "add", "." }, .cwd = .{ .path = repo_path } }) catch {};
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "seed" }, .cwd = .{ .path = repo_path } }) catch {};

    // Child is an implement role that overwrites code.txt in its worktree.
    var child_fake = testing.Fake{ .script = &.{
        &.{.{ .tool_call = .{ .id = "w1", .name = "write", .arguments_json = "{\"path\":\"code.txt\",\"content\":\"edited by child\"}" } }},
        &.{.{ .text = "Changes Made: overwrote code.txt." }},
    } };

    const wt_root = try std.fmt.allocPrint(arena, "{s}/agent-worktrees", .{repo_path});
    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "",
        .provider = child_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{"**"},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = undefined,
        .max_depth = 1,
        .max_concurrent = 1,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
        .git = git_mod.discover(io, arena, tmp.dir).?.git,
        .worktree_root = wt_root,
        .session_hint = "stest",
    };

    const result = spawnHook(&host, arena, 0, "{\"task\":\"edit code\",\"role\":\"implement\",\"isolation\":\"worktree\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "branch: ifnh/") != null);

    // Main tree untouched; worktree has the edit.
    const main_data = try tmp.dir.readFileAlloc(io, "code.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("original\n", main_data);
}

/// Records the request a child turn actually made.
const Recorder = struct {
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    options: []const u8 = "",
    calls: usize = 0,

    fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, req: provider_mod.ModelRequest, sink: provider_mod.Sink) anyerror!void {
        _ = alloc;
        _ = io;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.model = req.model;
        self.base_url = req.base_url;
        self.api_key = req.api_key;
        self.options = req.provider_options;
        self.calls += 1;
        sink.emit(.{ .content_delta = "Findings: routed." });
        sink.emit(.{ .done = {} });
    }

    fn provider(self: *Recorder) provider_mod.Provider {
        return .{ .ctx = self, .stream_fn = Recorder.stream };
    }
};

test "routed child role switches provider, model and options together" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parent_rec = Recorder{};
    var research_rec = Recorder{};
    var models = ChildModels{};
    models.set("research", .{
        .provider = research_rec.provider(),
        .model = "research-model",
        .base_url = "http://research.example",
        .api_key = "research-key",
        .provider_options = "{\"reasoning_effort\":\"high\"}",
        .temperature = 0.1,
    });

    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "base rules",
        .provider = parent_rec.provider(),
        .base_url = "http://parent.example",
        .api_key = "parent-key",
        .default_model = "parent-model",
        .provider_options = "{\"reasoning_effort\":\"low\"}",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{"**"},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn deny(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
                return .denied;
            }
        }.deny,
        .max_depth = 1,
        .max_concurrent = 1,
        .max_rounds = 4,
        .redactions = &.{},
        .cancel = &cancel,
        .routing = &models,
    };

    const routed = spawnHook(&host, arena, 0, "{\"task\":\"look\",\"role\":\"research\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, routed.status);
    try std.testing.expectEqualStrings("research-model", research_rec.model);
    try std.testing.expectEqualStrings("http://research.example", research_rec.base_url);
    try std.testing.expectEqualStrings("research-key", research_rec.api_key);
    try std.testing.expectEqualStrings("{\"reasoning_effort\":\"high\"}", research_rec.options);
    try std.testing.expectEqual(@as(usize, 0), parent_rec.calls);

    // A role with no routing entry keeps the parent's whole bundle.
    _ = spawnHook(&host, arena, 0, "{\"task\":\"ship\",\"role\":\"implement\"}");
    try std.testing.expectEqualStrings("parent-model", parent_rec.model);
    try std.testing.expectEqualStrings("http://parent.example", parent_rec.base_url);
    try std.testing.expectEqualStrings("parent-key", parent_rec.api_key);
    try std.testing.expectEqualStrings("{\"reasoning_effort\":\"low\"}", parent_rec.options);

    // An explicit `model` is an alias: it wins over the role table and brings
    // its whole bundle (provider, endpoint, key, options).
    var alias_rec = Recorder{};
    models.aliases = &.{.{ .name = "fast", .model = .{
        .provider = alias_rec.provider(),
        .model = "fast-model",
        .base_url = "http://fast.example",
        .api_key = "fast-key",
    } }};
    const known = spawnHook(&host, arena, 0, "{\"task\":\"look\",\"role\":\"research\",\"model\":\"fast\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, known.status);
    try std.testing.expectEqualStrings("fast-model", alias_rec.model);
    try std.testing.expectEqualStrings("http://fast.example", alias_rec.base_url);
    try std.testing.expectEqualStrings("fast-key", alias_rec.api_key);
    try std.testing.expectEqual(@as(usize, 1), research_rec.calls);

    // An unknown alias is an error; the string is not passed through as a model id.
    const unknown = spawnHook(&host, arena, 0, "{\"task\":\"look\",\"role\":\"research\",\"model\":\"explicit-model\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.failed, unknown.status);
    try std.testing.expect(std.mem.indexOf(u8, unknown.summary, "unknown alias 'explicit-model'") != null);
    try std.testing.expectEqual(@as(usize, 1), parent_rec.calls);
}

test "a research child gets only its allowed MCP servers; the parent keeps its own set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two stdio servers that touch a marker file when they are spawned.
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const parent_script = try mcp_mod.writeFakeServerWith(tmp.dir, io, arena, "parent-mcp.sh", try std.fmt.allocPrint(arena, "touch '{s}/spawned-parent'", .{dir}));
    const research_script = try mcp_mod.writeFakeServerWith(tmp.dir, io, arena, "research-mcp.sh", try std.fmt.allocPrint(arena, "touch '{s}/spawned-research'", .{dir}));
    const cfg_json = try std.fmt.allocPrint(
        arena,
        "{{\"p\":{{\"command\":\"{s}\",\"agents\":[\"parent\"]}},\"r\":{{\"command\":\"{s}\",\"agents\":[\"research\"]}}}}",
        .{ parent_script, research_script },
    );
    const cfg_val = try std.json.parseFromSliceLeaky(std.json.Value, arena, cfg_json, .{});
    var registry = try mcp_mod.Registry.init(io, arena, cfg_val, "parent");
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 1), registry.configs.len);
    try std.testing.expectEqualStrings("p", registry.configs[0].name);

    // The child lists its MCP tools, then answers.
    var child_fake = testing.Fake{ .script = &.{
        &.{.{ .tool_call = .{ .id = "c1", .name = "mcp_list", .arguments_json = "{}" } }},
        &.{.{ .text = "listed" }},
    } };
    var cancel = std.atomic.Value(bool).init(false);
    var host = Host{
        .io = io,
        .workspace = tmp.dir,
        .base_system = "",
        .provider = child_fake.provider(),
        .base_url = "",
        .api_key = "",
        .default_model = "fake",
        .mode = .auto,
        .read_globs = &.{"**"},
        .write_globs = &.{},
        .command_allow = &.{},
        .command_deny = &.{},
        .env_allow = &.{},
        .journal = null,
        .approval_ctx = undefined,
        .approval_fn = undefined,
        .max_depth = 1,
        .max_concurrent = 1,
        .max_rounds = 10,
        .redactions = &.{},
        .cancel = &cancel,
        .mcp = &registry,
    };

    const result = spawnHook(&host, arena, 0, "{\"task\":\"list mcp\",\"role\":\"research\"}");
    try std.testing.expectEqual(tool_mod.AgentSpawnResult.SpawnStatus.completed, result.status);

    // The child started the research server and never the parent-only one.
    try tmp.dir.access(io, "spawned-research", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "spawned-parent", .{}));
    // The child did not borrow (or leave behind) any of the parent's clients.
    try std.testing.expectEqual(@as(usize, 0), registry.clients.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.configs.len);
}
