//! Headless-capable agent session runtime (C-01/C-02).
//!
//! Owns the one-turn flow: history, provider config, hooks, tool execution,
//! approval callback, and the compaction trigger. The REPL and `ifnh ask`
//! are renderers on top of this module; neither owns a second turn loop.

const std = @import("std");
const core_types = @import("../types.zig");
const config_mod = @import("../config/config.zig");
const session_mod = @import("../session/store.zig");
const journal_mod = @import("../journal.zig");
const engine_mod = @import("../permissions/engine.zig");
const compaction_mod = @import("../compaction.zig");
const hooks_mod = @import("../hooks.zig");
const git_mod = @import("../git.zig");
const mcp_mod = @import("../mcp.zig");
const skills_mod = @import("../skills.zig");
const executions_mod = @import("../executions.zig");
const tool_mod = @import("../../tools/tool.zig");
const agent_engine = @import("engine.zig");
const subagent_mod = @import("subagent.zig");

pub const Approval = struct {
    ctx: *anyopaque,
    approve_fn: *const fn (ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse,
};

pub const Notice = struct {
    ctx: *anyopaque,
    notify_fn: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const TurnResult = struct {
    status: agent_engine.Status,
    reply: []const u8 = "",
    error_message: []const u8 = "",
    usage: core_types.Usage = .{},
    tool_rounds: usize = 0,
    tool_calls: usize = 0,
    denied_tools: usize = 0,
    hook_blocked: bool = false,
};

pub const Runtime = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: std.Io.Dir,
    cfg: *config_mod.Store,
    pcfg: agent_engine.ProviderConfig,
    system: []const u8,
    history: *std.ArrayListUnmanaged(core_types.ChatMessage),
    engine: *engine_mod.Engine,
    journal: ?*journal_mod.Journal = null,
    store: ?*session_mod.Session = null,
    mcp_registry: ?*mcp_mod.Registry = null,
    skills: ?skills_mod.Catalog = null,
    executions: ?*executions_mod.Registry = null,
    session_id: []const u8 = "",
    environ: ?*const std.process.Environ.Map = null,
    callbacks: agent_engine.Callbacks,
    approval: Approval,
    cancel: *std.atomic.Value(bool),
    notice: ?Notice = null,

    fn status(self: *Runtime, text: []const u8) void {
        if (self.notice) |n| {
            n.notify_fn(n.ctx, text);
        } else {
            self.callbacks.on_notice(self.callbacks.ctx, text);
        }
    }

    /// Run exactly one user turn. Appends history and session events.
    pub fn submit(self: *Runtime, user_text: []const u8) TurnResult {
        if (self.pcfg.model.len == 0) {
            return .{ .status = .failed, .error_message = "no model configured — run /provider set <openai|anthropic> <model> [base_url] [key_env]" };
        }
        if (self.pcfg.api_key.len == 0) {
            const key_env = self.cfg.getOptionalString("model.api_key_env") orelse "OPENAI_API_KEY";
            const msg = std.fmt.allocPrint(self.arena, "note: no api key — run /provider key {s} <value> (or export it) before sending a message", .{key_env}) catch
                "note: no api key";
            self.status(msg);
        }

        if (self.store) |store| _ = store.append(.{ .user = .{ .text = user_text } }) catch {};
        self.history.append(self.arena, .{ .role = .user, .content = user_text }) catch {};

        var host = subagent_mod.Host{
            .io = self.io,
            .workspace = self.cwd,
            .base_system = self.system,
            .provider = self.pcfg.provider,
            .base_url = self.pcfg.base_url,
            .api_key = self.pcfg.api_key,
            .default_model = self.pcfg.model,
            .mode = self.engine.mode,
            .read_globs = self.engine.read_globs,
            .write_globs = self.engine.write_globs,
            .command_allow = self.engine.command_allow,
            .command_deny = self.engine.command_deny,
            .env_allow = self.engine.env_allow,
            .journal = self.journal,
            .approval_ctx = self.approval.ctx,
            .approval_fn = self.approval.approve_fn,
            .max_depth = self.cfg.getU32("agents.max_depth", 1),
            .max_concurrent = self.cfg.getU32("agents.max_concurrent", 4),
            .max_rounds = 25,
            .redactions = redactionsFor(self.arena, self.pcfg.api_key),
            .temperature = self.cfg.getOptionalF64("model.temperature"),
            .max_output_tokens = self.cfg.getOptionalU32("model.max_output_tokens"),
            .cancel = self.cancel,
            .git = blk: {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = self.cwd.realPath(self.io, &path_buf) catch break :blk null;
                const repo_path = self.arena.dupe(u8, path_buf[0..n]) catch break :blk null;
                const g = git_mod.Git.init(self.io, repo_path);
                if (!g.isRepo(self.arena)) break :blk null;
                break :blk g;
            },
            .worktree_root = blk: {
                const home = if (self.environ) |e| e.get("HOME") orelse break :blk null else break :blk null;
                const root = std.fmt.allocPrint(self.arena, "{s}/.local/state/ifnh/worktrees", .{home}) catch break :blk null;
                self.cwd.createDirPath(self.io, root) catch {};
                break :blk root;
            },
            .session_hint = self.session_id,
        };
        var tool_ctx = tool_mod.ToolContext{
            .io = self.io,
            .arena = self.arena,
            .workspace = self.cwd,
            .engine = self.engine,
            .journal = self.journal,
            .max_file_read_bytes = self.cfg.getU32("context.max_file_read_bytes", 262144),
            .approval_ctx = self.approval.ctx,
            .approval_fn = self.approval.approve_fn,
            .agent_spawn_fn = subagent_mod.spawnHookFn,
            .agent_spawn_ctx = &host,
            .agent_depth = 0,
            .agent_label = "parent",
            .mcp_list_fn = mcpListHook,
            .mcp_call_fn = mcpCallHook,
            .mcp_ctx = @ptrCast(self),
            .skill_load_fn = skillLoadHook,
            .skill_ctx = @ptrCast(self),
            .exec_start_fn = execStartHook,
            .exec_query_fn = execQueryHook,
            .exec_ctx = @ptrCast(self),
        };
        _ = &tool_ctx;

        var hook_engine = hooks_mod.Engine.init(self.io, self.cwd, hooks_mod.Engine.fromConfig(self.arena, self.cfg.get("hooks")) catch &.{}, self.arena);
        const pre = hook_engine.dispatch(.before_agent, "{}");
        if (pre.blocked) {
            self.status(std.fmt.allocPrint(self.arena, "before_agent hook blocked the turn: {s}", .{pre.output}) catch "before_agent hook blocked the turn");
            return .{ .status = .failed, .error_message = pre.output, .hook_blocked = true };
        }

        // ---- automatic context compaction (C36, PLAN §24) ----
        if (self.cfg.getBool("context.auto_compact", true)) {
            const threshold: usize = self.cfg.getU32("context.max_context_tokens", 96_000);
            const plan = compaction_mod.planCompaction(self.history.items, threshold, self.cfg.getF64("context.compact_at_fraction", 0.8));
            if (plan.should_compact) {
                const start_msg = std.fmt.allocPrint(self.arena, "[compacting context... {d} tokens]", .{plan.estimated_tokens}) catch "[compacting context]";
                self.status(start_msg);
                const res_opt: ?compaction_mod.Result = blk: {
                    break :blk compaction_mod.compact(self.arena, self.io, self.pcfg, self.history, redactionsFor(self.arena, self.pcfg.api_key)) catch |err| {
                        const fail_msg = std.fmt.allocPrint(self.arena, "[compaction failed: {s}; continuing with full context]", .{@errorName(err)}) catch "[compaction failed; continuing]";
                        self.status(fail_msg);
                        break :blk null;
                    };
                };
                if (res_opt) |res| {
                    self.history.clearRetainingCapacity();
                    self.history.appendSlice(self.arena, res.history) catch {};
                    if (self.store) |store| _ = store.append(.{ .note = .{
                        .text = std.fmt.allocPrint(self.arena, "context compacted: {d} -> {d} tokens", .{ res.tokens_before, res.tokens_after }) catch "context compacted",
                    } }) catch {};
                    const done_msg = std.fmt.allocPrint(self.arena, "[context compacted: {d} -> {d} tokens]", .{ res.tokens_before, res.tokens_after }) catch "[context compacted]";
                    self.status(done_msg);
                }
            }
        }

        var tap = Tap{ .inner = self.callbacks };
        const outcome = agent_engine.runTurn(.{
            .io = self.io,
            .arena = self.arena,
            .pcfg = self.pcfg,
            .system = self.system,
            .history = self.history,
            .tool_ctx = &tool_ctx,
            .callbacks = .{
                .ctx = &tap,
                .on_text = Tap.onText,
                .on_tool_start = Tap.onToolStart,
                .on_tool_result = Tap.onToolResult,
                .on_notice = Tap.onNotice,
            },
            .cancel = self.cancel,
            .include_tools = self.cfg.getBool("model.tools_enabled", true),
            .max_retries = self.cfg.getU32("agents.max_retries", 3),
            .redactions = redactionsFor(self.arena, self.pcfg.api_key),
        }) catch |err| {
            return .{
                .status = .failed,
                .error_message = std.fmt.allocPrint(self.arena, "turn failed: {s}", .{@errorName(err)}) catch "turn failed",
                .denied_tools = tap.denied,
            };
        };

        _ = hook_engine.dispatch(.after_agent, "{}");
        if (self.store) |store| {
            switch (outcome.status) {
                .completed => _ = store.append(.{ .assistant = .{ .text = outcome.reply } }) catch {},
                .failed => _ = store.append(.{ .note = .{ .text = outcome.error_message } }) catch {},
                .cancelled => _ = store.append(.interrupted) catch {},
            }
        }
        if (outcome.usage.input_tokens > 0 or outcome.usage.output_tokens > 0) {
            if (self.store) |store| {
                const usage_line = std.fmt.allocPrint(self.arena, "{{\"ts_ms\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"tool_calls\":{d}}}\n", .{
                    @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms))),
                    outcome.usage.input_tokens,
                    outcome.usage.output_tokens,
                    outcome.tool_calls,
                }) catch "";
                if (usage_line.len > 0) {
                    const f = store.dir.createFile(self.io, "usage.jsonl", .{ .truncate = false }) catch null;
                    if (f) |file| {
                        defer file.close(self.io);
                        const st = file.stat(self.io) catch null;
                        const off: u64 = if (st) |s| s.size else 0;
                        file.writePositionalAll(self.io, usage_line, off) catch {};
                    }
                }
            }
        }
        if (self.store) |store| store.syncWatermark() catch {};

        return .{
            .status = outcome.status,
            .reply = outcome.reply,
            .error_message = outcome.error_message,
            .usage = outcome.usage,
            .tool_rounds = outcome.tool_rounds,
            .tool_calls = outcome.tool_calls,
            .denied_tools = tap.denied,
        };
    }
};

const Tap = struct {
    inner: agent_engine.Callbacks,
    denied: usize = 0,

    fn onText(ctx: *anyopaque, text: []const u8) void {
        const self: *Tap = @ptrCast(@alignCast(ctx));
        self.inner.on_text(self.inner.ctx, text);
    }
    fn onToolStart(ctx: *anyopaque, name: []const u8, args_json: []const u8) void {
        const self: *Tap = @ptrCast(@alignCast(ctx));
        self.inner.on_tool_start(self.inner.ctx, name, args_json);
    }
    fn onToolResult(ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        const self: *Tap = @ptrCast(@alignCast(ctx));
        if (status == .denied) self.denied += 1;
        self.inner.on_tool_result(self.inner.ctx, name, status, output);
    }
    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *Tap = @ptrCast(@alignCast(ctx));
        self.inner.on_notice(self.inner.ctx, text);
    }
};

fn mcpListHook(ctx: *anyopaque, arena: std.mem.Allocator) []const u8 {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const reg = self.mcp_registry orelse return "no MCP servers configured";
    if (reg.configs.len == 0) return "no MCP servers configured";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (reg.allTools(arena)) |st| {
        buf.print(arena, "{s}.{s}: {s}\n", .{ st.server, st.tool.name, st.tool.description }) catch {};
    }
    if (buf.items.len == 0) return "no MCP tools available";
    return buf.items;
}

fn mcpCallHook(ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) []const u8 {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const reg = self.mcp_registry orelse return "error: MCP not configured";
    const res = reg.call(arena, server, tool, arguments_json) catch |err| {
        return std.fmt.allocPrint(arena, "error: mcp call failed: {s}", .{@errorName(err)}) catch "error: mcp call failed";
    };
    if (res.is_error) return std.fmt.allocPrint(arena, "mcp error: {s}", .{res.text}) catch res.text;
    return res.text;
}

fn execStartHook(ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) []const u8 {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const reg = self.executions orelse return "error: background executions unavailable";
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(arena, "/bin/sh") catch return "error: oom";
    argv.append(arena, "-c") catch return "error: oom";
    argv.append(arena, command) catch return "error: oom";
    const id = reg.start(argv.items) catch |err| {
        return std.fmt.allocPrint(arena, "error: start failed: {s}", .{@errorName(err)}) catch "error: start failed";
    };
    return std.fmt.allocPrint(arena, "started background execution {d}; poll with exec action=status id={d}, output with action=output", .{ id, id }) catch "started";
}

fn execQueryHook(ctx: *anyopaque, arena: std.mem.Allocator, action: []const u8, id_str: []const u8) []const u8 {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const reg = self.executions orelse return "error: background executions unavailable";
    const id = std.fmt.parseInt(u32, id_str, 10) catch {
        if (std.mem.eql(u8, action, "list")) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (&reg.slots) |*s| {
                if (!s.used) continue;
                buf.print(arena, "  exec {d}: {s}\n", .{ s.id, s.command[0..s.command_len] }) catch {};
            }
            if (buf.items.len == 0) return "no background executions";
            return buf.items;
        }
        return "error: exec requires numeric id";
    };
    if (std.mem.eql(u8, action, "status")) {
        const snap = reg.snapshot(id) orelse return "error: unknown execution id";
        return std.fmt.allocPrint(arena, "exec {d}: {s} (exit: {any}), {d} bytes output in {s}", .{
            snap.id, @tagName(snap.state), snap.exit_code, snap.output_bytes, snap.output_file,
        }) catch "error: oom";
    }
    if (std.mem.eql(u8, action, "output")) {
        return reg.readOutput(id, arena, 32 * 1024) orelse "error: no output available";
    }
    if (std.mem.eql(u8, action, "stop")) {
        return if (reg.stop(id)) "stopped" else "error: unknown execution id";
    }
    return "error: unknown action (status|output|stop|list)";
}

fn skillLoadHook(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const catalog = self.skills orelse return null;
    return skills_mod.loadSkill(self.cwd, self.io, arena, catalog, name) catch null;
}

fn redactionsFor(arena: std.mem.Allocator, api_key: []const u8) []const []const u8 {
    if (api_key.len < 8) return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    list.append(arena, api_key) catch return &.{};
    return list.items;
}
