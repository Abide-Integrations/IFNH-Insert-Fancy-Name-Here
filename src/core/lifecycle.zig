//! Lifecycle engine (M2-T01/T02, DECISIONS section F/G, D023-D026).
//!
//! A lifecycle is a linear pipeline of stages; each stage runs a child
//! agent (via the subagent Host) with a role, optional required artifacts
//! (entry conditions), an optional review stage pass, and an optional
//! human approval gate (D027). Reviews are reviewer-role children whose
//! findings carry severities; blockers stop the lifecycle (G94/95).
//! State is event-sourced in the session via the caller (F85).

const std = @import("std");
const core_types = @import("types.zig");
const subagent_mod = @import("agent/subagent.zig");
const tool_mod = @import("../tools/tool.zig");

pub const max_stages: usize = 32;

pub const Approval = enum { none, human };

pub const Stage = struct {
    name: []const u8,
    role: subagent_mod.Role = .implement,
    instructions: []const u8,
    /// Paths that must exist for the stage to start (F81).
    requires: []const []const u8 = &.{},
    /// Stage output is reviewed by a review-role child (G88-92).
    review: bool = false,
    /// Human approval gate after the stage (G98, D027).
    approval: Approval = .none,
};

pub const Lifecycle = struct {
    name: []const u8,
    stages: []Stage,
};

pub const ParseError = error{
    InvalidLifecycle,
    TooManyStages,
    OutOfMemory,
};

/// Parse a lifecycle JSON document:
/// { "name": "...", "stages": [ { "name","role","instructions",
///   "requires":[paths], "review":bool, "approval":"human"|"none" } ] }
pub fn parse(arena: std.mem.Allocator, json_text: []const u8) ParseError!Lifecycle {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch
        return error.InvalidLifecycle;
    if (v != .object) return error.InvalidLifecycle;
    const o = v.object;
    const stages_v = o.get("stages") orelse return error.InvalidLifecycle;
    if (stages_v != .array) return error.InvalidLifecycle;
    if (stages_v.array.items.len == 0 or stages_v.array.items.len > max_stages) return error.TooManyStages;

    var stages: std.ArrayListUnmanaged(Stage) = .empty;
    for (stages_v.array.items) |item| {
        if (item != .object) return error.InvalidLifecycle;
        const so = item.object;
        const name_v = so.get("name") orelse return error.InvalidLifecycle;
        const instr_v = so.get("instructions") orelse return error.InvalidLifecycle;
        if (name_v != .string or instr_v != .string) return error.InvalidLifecycle;

        var role: subagent_mod.Role = .implement;
        if (so.get("role")) |r| {
            if (r == .string) {
                role = std.meta.stringToEnum(subagent_mod.Role, r.string) orelse return error.InvalidLifecycle;
            }
        }
        var requires: std.ArrayListUnmanaged([]const u8) = .empty;
        if (so.get("requires")) |req| {
            if (req != .array) return error.InvalidLifecycle;
            for (req.array.items) |p| {
                if (p != .string) return error.InvalidLifecycle;
                try requires.append(arena, p.string);
            }
        }
        try stages.append(arena, .{
            .name = name_v.string,
            .role = role,
            .instructions = instr_v.string,
            .requires = requires.items,
            .review = if (so.get("review")) |rv| (rv == .bool and rv.bool) else false,
            .approval = if (so.get("approval")) |av|
                (if (av == .string and std.mem.eql(u8, av.string, "human")) Approval.human else Approval.none)
            else
                .none,
        });
    }

    return .{
        .name = if (o.get("name")) |n| (if (n == .string) n.string else "lifecycle") else "lifecycle",
        .stages = stages.items,
    };
}

pub const StageOutcome = struct {
    pub const Status = enum { completed, blocked, failed, needs_approval };

    stage: []const u8,
    status: Status,
    summary: []const u8,
    report_path: []const u8 = "",
    review_summary: []const u8 = "",
    blockers: usize = 0,
};

pub const RunCallbacks = struct {
    ctx: *anyopaque,
    on_stage_start: *const fn (ctx: *anyopaque, stage: []const u8, role: []const u8) void,
    on_stage_done: *const fn (ctx: *anyopaque, out: StageOutcome) void,
    /// Human approval gate (D027); true = approved.
    approve: *const fn (ctx: *anyopaque, stage: []const u8, summary: []const u8) bool,
};

/// Entry condition: all required artifacts exist (F81).
fn checkRequires(workspace: std.Io.Dir, io: std.Io, stage: Stage) bool {
    for (stage.requires) |p| {
        _ = workspace.statFile(io, p, .{}) catch return false;
    }
    return true;
}

/// Run the lifecycle from `start_stage`. Stops at the first blocked or
/// failed stage or after an unapproved human gate. Returns per-stage
/// outcomes allocated in `arena`.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    host: *subagent_mod.Host,
    lc: Lifecycle,
    start_stage: usize,
    callbacks: RunCallbacks,
) ![]StageOutcome {
    var outcomes: std.ArrayListUnmanaged(StageOutcome) = .empty;

    var i = start_stage;
    while (i < lc.stages.len) : (i += 1) {
        const stage = lc.stages[i];
        callbacks.on_stage_start(callbacks.ctx, stage.name, @tagName(stage.role));

        if (!checkRequires(host.workspace, io, stage)) {
            const out = StageOutcome{
                .stage = stage.name,
                .status = .blocked,
                .summary = "entry conditions not met (missing artifacts)",
            };
            try outcomes.append(arena, out);
            callbacks.on_stage_done(callbacks.ctx, out);
            return outcomes.items;
        }

        // Stage task = instructions (+ role framing handled by the child).
        const task = try std.fmt.allocPrint(arena, "Lifecycle stage '{s}': {s}", .{ stage.name, stage.instructions });
        var spawn_result = spawnChild(host, arena, task, stage.role);

        const out = StageOutcome{
            .stage = stage.name,
            .status = if (spawn_result.status == .completed) .completed else .failed,
            .summary = spawn_result.summary,
            .report_path = spawn_result.report_path,
        };
        callbacks.on_stage_done(callbacks.ctx, out);
        try outcomes.append(arena, out);
        if (out.status != .completed) return outcomes.items;

        // Review pass (D026, G88): a review-role child inspects the stage.
        if (stage.review) {
            const review_task = try std.fmt.allocPrint(arena, "Review the work completed for lifecycle stage '{s}'. Its report: {s}. " ++
                "Inspect the changed files in the repository and report findings with severities; " ++
                "state clearly on the first line either 'BLOCKERS: 0' or 'BLOCKERS: <n>'.", .{ stage.name, spawn_result.report_path });
            const review_result = spawnChild(host, arena, review_task, .review);
            const blockers = parseBlockers(review_result.summary);
            const reviewed = StageOutcome{
                .stage = stage.name,
                .status = if (blockers > 0) .blocked else .completed,
                .summary = review_result.summary,
                .report_path = review_result.report_path,
                .review_summary = review_result.summary,
                .blockers = blockers,
            };
            try outcomes.append(arena, reviewed);
            callbacks.on_stage_done(callbacks.ctx, reviewed);
            if (blockers > 0) return outcomes.items; // failed review stops (D008)
            spawn_result = review_result;
        }

        // Human approval gate (D027).
        if (stage.approval == .human) {
            const approved = callbacks.approve(callbacks.ctx, stage.name, spawn_result.summary);
            if (!approved) {
                const gated = StageOutcome{
                    .stage = stage.name,
                    .status = .needs_approval,
                    .summary = "awaiting developer approval",
                };
                try outcomes.append(arena, gated);
                callbacks.on_stage_done(callbacks.ctx, gated);
                return outcomes.items;
            }
        }
    }
    return outcomes.items;
}

fn spawnChild(host: *subagent_mod.Host, arena: std.mem.Allocator, task: []const u8, role: subagent_mod.Role) tool_mod.AgentSpawnResult {
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("{\"task\":") catch return .{ .status = .failed, .summary = "oom" };
    std.json.Stringify.value(task, .{}, &aw.writer) catch return .{ .status = .failed, .summary = "oom" };
    aw.writer.print(",\"role\":\"{s}\"}}", .{@tagName(role)}) catch return .{ .status = .failed, .summary = "oom" };
    return subagent_mod.spawnHook(host, arena, 0, aw.written());
}

/// Find "BLOCKERS: <n>" in a review summary.
fn parseBlockers(summary: []const u8) usize {
    const needle = "BLOCKERS:";
    const pos = std.mem.indexOf(u8, summary, needle) orelse return 0;
    const rest = std.mem.trim(u8, summary[pos + needle.len ..], " \t\r\n:");
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return 0;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch 0;
}

// ---------------------------------------------------------------- tests

const test_lifecycle_json =
    \\{
    \\  "name": "ship",
    \\  "stages": [
    \\    { "name": "research", "role": "research", "instructions": "investigate" },
    \\    { "name": "implement", "role": "implement", "instructions": "build it", "review": true },
    \\    { "name": "merge", "role": "implement", "instructions": "finalize", "approval": "human" }
    \\  ]
    \\}
;

test "lifecycle parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lc = try parse(a, test_lifecycle_json);
    try std.testing.expectEqualStrings("ship", lc.name);
    try std.testing.expectEqual(@as(usize, 3), lc.stages.len);
    try std.testing.expectEqual(subagent_mod.Role.research, lc.stages[0].role);
    try std.testing.expect(lc.stages[1].review);
    try std.testing.expectEqual(Approval.human, lc.stages[2].approval);

    try std.testing.expectError(error.InvalidLifecycle, parse(a, "not json"));
    try std.testing.expectError(error.InvalidLifecycle, parse(a, "{}"));
}

test "blocker parsing" {
    try std.testing.expectEqual(@as(usize, 0), parseBlockers("BLOCKERS: 0\nfine"));
    try std.testing.expectEqual(@as(usize, 2), parseBlockers("BLOCKERS: 2\nbad stuff"));
    try std.testing.expectEqual(@as(usize, 0), parseBlockers("no marker here"));
}

test "full lifecycle run with fake providers: review pass and approval gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Children: research replies, implement replies, review says BLOCKERS: 0,
    // final stage replies. One fake provider covers all children in order.
    var child_fake = @import("agent/testing.zig").Fake{ .script = &.{
        &.{.{ .text = "Findings: looks fine." }},
        &.{.{ .text = "Changes Made: built it." }},
        &.{.{ .text = "BLOCKERS: 0\nReview clean." }},
        &.{.{ .text = "Finalized." }},
    } };

    var cancel = std.atomic.Value(bool).init(false);
    var host = subagent_mod.Host{
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
    };

    const lc = try parse(arena, test_lifecycle_json);

    const Tracker = struct {
        starts: usize = 0,
        approvals: usize = 0,
        fn onStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn onDone(_: *anyopaque, _: StageOutcome) void {}
        fn approveFn(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
    };
    var tracker = Tracker{};
    const outcomes = try run(arena, io, &host, lc, 0, .{
        .ctx = &tracker,
        .on_stage_start = Tracker.onStart,
        .on_stage_done = Tracker.onDone,
        .approve = Tracker.approveFn,
    });

    // research, implement, implement-review, merge
    try std.testing.expectEqual(@as(usize, 4), outcomes.len);
    try std.testing.expectEqual(StageOutcome.Status.completed, outcomes[0].status);
    try std.testing.expectEqual(StageOutcome.Status.completed, outcomes[1].status);
    try std.testing.expectEqual(StageOutcome.Status.completed, outcomes[2].status); // review
    try std.testing.expectEqual(@as(usize, 0), outcomes[2].blockers);
    try std.testing.expectEqual(StageOutcome.Status.completed, outcomes[3].status);
}

test "lifecycle stops at blocked review" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var child_fake = @import("agent/testing.zig").Fake{ .script = &.{
        &.{.{ .text = "Changes Made: built it badly." }},
        &.{.{ .text = "BLOCKERS: 1\nSecurity issue found." }},
        &.{.{ .text = "this must not run" }},
    } };

    var cancel = std.atomic.Value(bool).init(false);
    var host = subagent_mod.Host{
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
    };

    const lc_json =
        \\{"stages":[{"name":"impl","role":"implement","instructions":"do","review":true},{"name":"next","role":"implement","instructions":"more"}]}
    ;
    const lc = try parse(arena, lc_json);
    const outcomes = try run(arena, io, &host, lc, 0, .{
        .ctx = undefined,
        .on_stage_start = struct {
            fn f(_: *anyopaque, _: []const u8, _: []const u8) void {}
        }.f,
        .on_stage_done = struct {
            fn f(_: *anyopaque, _: StageOutcome) void {}
        }.f,
        .approve = struct {
            fn f(_: *anyopaque, _: []const u8, _: []const u8) bool {
                return true;
            }
        }.f,
    });

    try std.testing.expectEqual(@as(usize, 2), outcomes.len); // impl + its review
    try std.testing.expectEqual(StageOutcome.Status.completed, outcomes[0].status);
    try std.testing.expectEqual(StageOutcome.Status.blocked, outcomes[1].status);
    try std.testing.expectEqual(@as(usize, 1), outcomes[1].blockers);
}
