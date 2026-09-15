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

pub const max_summary_bytes: usize = 4 * 1024;

pub const Role = enum { research, implement, review };

fn parseRole(s: []const u8) ?Role {
    if (std.mem.eql(u8, s, "research")) return .research;
    if (std.mem.eql(u8, s, "implement")) return .implement;
    if (std.mem.eql(u8, s, "review")) return .review;
    return null;
}

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
    // Parent permission snapshot (borrowed slices, stable for the session).
    mode: engine_mod.Mode,
    read_globs: []const []const u8,
    write_globs: []const []const u8,
    command_allow: []const []const u8,
    command_deny: []const []const u8,
    env_allow: []const []const u8,
    journal: ?*journal_mod.Journal,
    approval_ctx: *anyopaque,
    approval_fn: *const fn (ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse,
    max_depth: usize,
    max_concurrent: usize,
    max_rounds: usize,
    redactions: []const []const u8,
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    cancel: *std.atomic.Value(bool),
    active: std.atomic.Value(u32) = .init(0),
    report_seq: std.atomic.Value(u32) = .init(0),
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
    var model: ?[]const u8 = null;
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
    }

    if (host.cancel.load(.acquire)) return fail(arena, "agent: cancelled", .{});
    if (parent_depth + 1 > host.max_depth) {
        return fail(arena, "agent: max delegation depth {d} exceeded", .{host.max_depth});
    }
    _ = host.active.fetchAdd(1, .acq_rel);
    defer _ = host.active.fetchSub(1, .acq_rel);

    const label = std.fmt.allocPrint(arena, "{s}-{d}", .{ @tagName(role), host.report_seq.load(.monotonic) + 1 }) catch "child";
    const result = runChild(host, arena, task, role, model, parent_depth, label);
    return result;
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
    model: ?[]const u8,
    parent_depth: usize,
    label: []const u8,
) tool_mod.AgentSpawnResult {
    // Child gets its own arena (thread isolation; freed before return).
    var child_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer child_arena_state.deinit();
    const child_arena = child_arena_state.allocator();

    // Role-scoped engine: research/review are read-only (D015).
    var child_engine = engine_mod.Engine.init(child_arena, host.mode);
    child_engine.read_globs = host.read_globs;
    child_engine.command_allow = host.command_allow;
    child_engine.command_deny = host.command_deny;
    child_engine.env_allow = host.env_allow;
    child_engine.write_globs = switch (role) {
        .implement => host.write_globs,
        .research, .review => &.{},
    };

    var child_tool_ctx = tool_mod.ToolContext{
        .io = host.io,
        .arena = child_arena,
        .workspace = host.workspace,
        .engine = &child_engine,
        .journal = host.journal,
        .max_file_read_bytes = 256 * 1024,
        .approval_ctx = host.approval_ctx,
        .approval_fn = host.approval_fn,
        .agent_spawn_fn = spawnHookFn,
        .agent_spawn_ctx = host,
        .agent_depth = parent_depth + 1,
        .agent_label = label,
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

    const outcome = agent_engine.runTurn(.{
        .io = host.io,
        .arena = child_arena,
        .pcfg = .{
            .provider = host.provider,
            .model = model orelse host.default_model,
            .base_url = host.base_url,
            .api_key = host.api_key,
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
        .temperature = host.temperature,
        .max_output_tokens = host.max_output_tokens,
    }) catch |err| {
        return fail(parent_arena, "agent: child turn failed: {s}", .{@errorName(err)});
    };

    // Durable report (PLAN §19). Path is copied to the parent arena — the
    // child arena dies on return.
    const report_path_child = writeReport(host, child_arena, task, role, label, outcome) catch "";
    const report_path = parent_arena.dupe(u8, report_path_child) catch "";

    // Structured result for the parent's model context (bounded).
    const summary = if (outcome.reply.len > max_summary_bytes) outcome.reply[0..max_summary_bytes] else outcome.reply;
    const envelope = std.fmt.allocPrint(
        parent_arena,
        "subagent {s} {s}\nreport: {s}\ntool_calls: {d}\n\n{s}",
        .{
            label,
            @tagName(outcome.status),
            report_path,
            outcome.tool_calls,
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
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
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
