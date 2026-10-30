//! Session and turn runtime (DESIGN §6, ACTIVE_PLAN C-01).
//!
//! Owns everything a session needs to run a turn: the persisted session
//! store, the journal, the permission engine, conversation history, the
//! skills catalog, background executions and the MCP registry.
//!
//! The runtime has no terminal dependency: it never reads stdin, never
//! writes to stdout/stderr and emits no escape codes. Everything the user
//! sees is delivered to the caller through `Events` (assistant text deltas,
//! tool progress, notices, approval requests), so the REPL and a headless
//! driver (C-02) run the same core.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const keys_mod = @import("../config/keys.zig");
const session_mod = @import("../session/store.zig");
const journal_mod = @import("../journal.zig");
const engine_mod = @import("../permissions/engine.zig");
const agent_engine = @import("engine.zig");
const subagent_mod = @import("subagent.zig");
const git_mod = @import("../git.zig");
const mcp_mod = @import("../mcp.zig");
const skills_mod = @import("../skills.zig");
const hooks_mod = @import("../hooks.zig");
const compaction_mod = @import("../compaction.zig");
const executions_mod = @import("../executions.zig");
const interrupt_mod = @import("../interrupt.zig");
const tool_mod = @import("../../tools/tool.zig");
const core_types = @import("../types.zig");
const openai = @import("../../providers/openai.zig");
const anthropic = @import("../../providers/anthropic.zig");
const trace_mod = @import("../trace.zig");
const turn_cache_mod = @import("../turn_cache.zig");

/// Severity of an informational status line. The caller picks the styling.
pub const Level = enum { plain, warn, err };

/// Everything the runtime tells the outside world. Rendering, key input and
/// approval prompting belong to the caller; the runtime only hands over data.
pub const Events = struct {
    ctx: *anyopaque,
    /// Assistant streaming text delta. Valid only for the duration of the call.
    on_text: *const fn (ctx: *anyopaque, chunk: []const u8) void,
    /// A status line (compaction, token notes, policy warnings).
    on_status: *const fn (ctx: *anyopaque, level: Level, text: []const u8) void,
    /// A tool call is about to execute.
    on_tool_start: *const fn (ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void,
    /// A tool call finished.
    on_tool_result: *const fn (ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void,
    /// Non-fatal notice (permission denials, truncation...).
    on_notice: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// An assistant message was persisted (text plus any tool calls).
    on_assistant_message: *const fn (ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void,
    /// Ask the human. The runtime applies session grants itself.
    on_approval: *const fn (ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse,
};

pub const InitOptions = struct {
    /// `sessions.dir` from config (e.g. ".ifnh/sessions").
    sessions_dir: []const u8,
    /// Session id to resume; null creates a new session.
    resume_id: ?[]const u8 = null,
    /// Recorded in the new session's manifest.
    cwd_label: []const u8 = ".",
    /// Startup trace owned by main (B-01).
    trace: ?*trace_mod.Trace = null,
};

/// Result of one turn. `ran` is false when the turn never reached the
/// provider (no model configured, or a hook blocked it).
pub const TurnOutcome = struct {
    ran: bool = false,
    status: agent_engine.Status = .completed,
    error_message: []const u8 = "",
    usage: core_types.Usage = .{},
    tool_calls: usize = 0,
};

pub const SessionRuntime = struct {
    io: std.Io,
    store: session_mod.Session,
    journal: journal_mod.Journal,
    engine: engine_mod.Engine,
    history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty,
    /// Session-layer overrides (path, JSON value text) re-applied after
    /// config re-reads at turn boundaries (DECISIONS B24).
    overrides: std.ArrayListUnmanaged(struct { path: []const u8, json: []const u8 }) = .empty,
    mcp_registry: ?*mcp_mod.Registry = null,
    skills: ?skills_mod.Catalog = null,
    executions: ?*executions_mod.Registry = null,
    /// Stage of the most recent blocked lifecycle review (M2-T03 override target).
    last_blocked_stage: ?[]const u8 = null,
    /// Persistent key store (user env file) for /provider key.
    user_keys: keys_mod.Keys,
    /// Per-session timing trace (B-01).
    trace: ?*trace_mod.Trace = null,
    /// Per-turn prologue cache, owned by the session (B-04).
    turn_cache: turn_cache_mod.TurnCache,
    /// One long-lived HTTP client for all provider rounds (B-02).
    http: std.http.Client,
    /// Raw process environment (never mutated).
    process_environ: *const std.process.Environ.Map,
    /// Process environment overlaid with the user env file (D022; the real
    /// environment wins). Provider keys stored mid-session land here.
    environ: *std.process.Environ.Map,

    /// Build a runtime: load provider keys, create or open the session
    /// store, and discover skills, background executions and MCP servers.
    pub fn init(
        io: std.Io,
        arena: std.mem.Allocator,
        process_environ: *const std.process.Environ.Map,
        cfg: *config_mod.Store,
        cwd: std.Io.Dir,
        opts: InitOptions,
    ) !SessionRuntime {
        // Persistent provider keys (~/.config/ifnh/env) overlay the process
        // environment for lookups (D022; real env wins).
        var user_keys = keys_mod.Keys.init(arena);
        user_keys.load(io, arena, process_environ);
        var merged = std.process.Environ.Map.init(arena);
        var keit = process_environ.iterator();
        while (keit.next()) |entry| {
            try merged.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var uk = user_keys.map.iterator();
        while (uk.next()) |entry| {
            if (merged.get(entry.key_ptr.*) == null) {
                try merged.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        const merged_env = try arena.create(std.process.Environ.Map);
        merged_env.* = merged;

        var store = if (opts.resume_id) |id|
            try session_mod.Session.open(cwd, io, arena, opts.sessions_dir, id)
        else
            try session_mod.Session.create(cwd, io, arena, opts.sessions_dir, opts.cwd_label);
        errdefer store.close();
        const j = try journal_mod.Journal.open(io, arena, store.dir);
        errdefer j.close();

        var self = SessionRuntime{
            .io = io,
            .store = store,
            .journal = j,
            .engine = engineFromConfig(arena, cfg),
            .user_keys = user_keys,
            .trace = opts.trace,
            .turn_cache = turn_cache_mod.TurnCache.init(io, arena),
            .http = .{ .allocator = arena, .io = io },
            .process_environ = process_environ,
            .environ = merged_env,
        };

        // ---- skills catalog (K148/149) ----
        var skills_span = trace_mod.Span.begin(opts.trace, "startup.skills");
        self.skills = blk: {
            const user_dir = config_mod.userSkillsDir(arena, process_environ) orelse break :blk null;
            const catalog = skills_mod.discover(cwd, io, arena, user_dir) catch break :blk null;
            break :blk catalog;
        };
        skills_span.end("");

        // ---- background executions (I123-125) ----
        self.executions = blk: {
            const reg = arena.create(executions_mod.Registry) catch break :blk null;
            reg.* = executions_mod.Registry.init(io, arena, cwd);
            break :blk reg;
        };

        // ---- MCP registry (lazy servers, J137/138) ----
        self.mcp_registry = blk: {
            const reg = arena.create(mcp_mod.Registry) catch break :blk null;
            reg.* = mcp_mod.Registry.init(io, arena, cfg.get("mcp_servers")) catch break :blk null;
            break :blk reg;
        };

        return self;
    }

    pub fn deinit(self: *SessionRuntime) void {
        if (self.executions) |reg| reg.deinit(); // kill background children (I125)
        if (self.mcp_registry) |reg| reg.deinit();
        self.store.close();
        self.journal.close();
        self.http.deinit();
    }

    /// Provider settings for the current config, with the API key read from
    /// the merged environment.
    pub fn providerConfig(self: *SessionRuntime, cfg: *config_mod.Store) agent_engine.ProviderConfig {
        const provider_name = cfg.getString("model.provider", "openai");
        const is_anthropic = std.mem.eql(u8, provider_name, "anthropic");
        const base_url = cfg.getOptionalString("model.base_url") orelse
            (if (is_anthropic) "https://api.anthropic.com" else "https://api.openai.com/v1");
        const model = cfg.getString("model.model", "");
        const api_key_env = cfg.getOptionalString("model.api_key_env") orelse
            (if (is_anthropic) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
        const api_key = if (self.environ.get(api_key_env)) |k|
            k
        else
            (self.process_environ.get(api_key_env) orelse "");
        return .{
            .provider = if (is_anthropic) anthropic.instance else openai.instance,
            .model = model,
            .base_url = base_url,
            .api_key = api_key,
            .client = &self.http,
        };
    }

    /// MCP server/tool listing for slash commands.
    pub fn mcpListText(self: *SessionRuntime, arena: std.mem.Allocator) []const u8 {
        return mcpListHook(@ptrCast(self.mcp_registry orelse mcp_registry_sentinel), arena);
    }

    /// Re-read disk config at a turn boundary, re-applying session overrides
    /// and preserving permission grants (T10/D029). Returns the replacement
    /// store, or null when the reload failed (caller keeps the last-good one).
    pub fn reloadConfig(self: *SessionRuntime, arena: std.mem.Allocator, cwd: std.Io.Dir) ?config_mod.Store {
        var fresh = config_mod.load(arena, self.io, self.process_environ, cwd) catch return null;
        for (self.overrides.items) |ov| {
            fresh.applyOverride(ov.path, ov.json, .{ .layer = .session, .origin = "session" }) catch {};
        }
        if (fresh.errors.items.len > 0) {
            fresh.deinit();
            return null; // keep the last-good config on invalid reload
        }
        // Rebuild the engine against the fresh store's slices, carrying grants
        // (grant patterns were duped into the long-lived REPL arena).
        var new_engine = engineFromConfig(arena, &fresh);
        new_engine.grants = self.engine.grants;
        self.engine = new_engine;
        return fresh;
    }

    /// Remove an unanswered turn from in-memory history and mark the persisted
    /// turn interrupted so replay drops it too (A-05).
    pub fn rollbackTurn(self: *SessionRuntime, history_start: usize) void {
        self.history.shrinkRetainingCapacity(history_start);
        _ = self.store.append(.interrupted) catch {};
    }

    /// Rebuild conversation history from the persisted event log.
    pub fn rebuildHistory(self: *SessionRuntime, arena: std.mem.Allocator, events: *const Events) !void {
        const page = try self.store.readEventPage(arena, 10_000);
        if (page.truncated) {
            statusFmt(events, .plain, "note: session has more than {d} events; resuming from the most recent {d}\n", .{ page.records.len, page.records.len });
        }
        const log = page.records;
        var turn_start: ?usize = null;
        var saw_assistant = false;
        for (log) |ev| {
            switch (ev.event) {
                .user => |v| {
                    // A new user message after an unanswered turn means the
                    // previous turn never produced an assistant reply.
                    if (turn_start) |start| {
                        if (!saw_assistant) self.history.shrinkRetainingCapacity(start);
                    }
                    turn_start = self.history.items.len;
                    saw_assistant = false;
                    try self.history.append(arena, .{ .role = .user, .content = v.text });
                },
                .assistant => |v| {
                    saw_assistant = true;
                    try self.history.append(arena, .{
                        .role = .assistant,
                        .content = v.text,
                        .tool_calls_json = v.tool_calls_json,
                    });
                },
                .tool_call => {},
                .tool_result => |v| try self.history.append(arena, .{
                    .role = .tool,
                    .content = v.output,
                    .tool_call_id = v.call_id,
                    .is_error = !std.mem.eql(u8, v.status, "ok"),
                }),
                .note => {},
                .interrupted => {
                    if (turn_start) |start| self.history.shrinkRetainingCapacity(start);
                    turn_start = null;
                    saw_assistant = false;
                },
            }
        }
        // A trailing user message with no assistant reply is an unfinished turn
        // from an older session or a crash; do not replay it.
        if (turn_start) |start| {
            if (!saw_assistant) self.history.shrinkRetainingCapacity(start);
        }
    }

    /// Run one turn: hooks, compaction, the provider rounds and persistence.
    /// All user-visible output goes through `events`.
    pub fn submitTurn(
        self: *SessionRuntime,
        arena: std.mem.Allocator,
        cfg: *config_mod.Store,
        pcfg: agent_engine.ProviderConfig,
        system: []const u8,
        /// Byte length of the byte-stable prefix of `system` (B-03).
        system_stable_len: usize,
        user_text: []const u8,
        cwd: std.Io.Dir,
        events: *const Events,
    ) !TurnOutcome {
        const io = self.io;
        if (pcfg.model.len == 0) {
            statusFmt(events, .plain, "no model configured — run /provider set <openai|anthropic> <model> [base_url] [key_env]\n", .{});
            return .{};
        }
        if (pcfg.api_key.len == 0) {
            const key_env = cfg.getOptionalString("model.api_key_env") orelse "OPENAI_API_KEY";
            statusFmt(events, .plain, "note: no api key — run /provider key {s} <value> (or export it) before sending a message\n", .{key_env});
        }

        var total_span = trace_mod.Span.begin(self.trace, "turn.total");
        defer total_span.end("");
        var cancel = std.atomic.Value(bool).init(false);
        // Ctrl-C sets `cancel` while the turn runs; a second one exits (A-06).
        interrupt_mod.install(&cancel);
        defer interrupt_mod.uninstall();
        var gate = Gate.init(self, events);
        var setup_span = trace_mod.Span.begin(self.trace, "turn.setup");
        var git_span = trace_mod.Span.begin(self.trace, "turn.git");
        const turn_git_lookup = self.turn_cache.gitRepo(cwd) catch turn_cache_mod.Lookup(?git_mod.Git){ .value = null, .hit = false };
        git_span.end(if (turn_git_lookup.hit) "cached" else "");
        const turn_git = turn_git_lookup.value;
        var host = subagent_mod.Host{
            .io = io,
            .workspace = cwd,
            .base_system = system,
            .provider = pcfg.provider,
            .base_url = pcfg.base_url,
            .api_key = pcfg.api_key,
            .default_model = pcfg.model,
            .client = &self.http,
            .mode = self.engine.mode,
            .read_globs = self.engine.read_globs,
            .write_globs = self.engine.write_globs,
            .command_allow = self.engine.command_allow,
            .command_deny = self.engine.command_deny,
            .env_allow = self.engine.env_allow,
            .git_commits = self.engine.git_commits,
            .git_push = self.engine.git_push,
            .git_force_push = self.engine.git_force_push,
            .read_dotenv = self.engine.read_dotenv,
            .use_external_tools = cfg.getBool("tools.external", true),
            .timeout_tool_s = cfg.getU32("agents.timeout_tool_s", 120),
            .journal = &self.journal,
            .approval_ctx = &gate,
            .approval_fn = Gate.approve,
            .max_depth = cfg.getU32("agents.max_depth", 1),
            .max_concurrent = cfg.getU32("agents.max_concurrent", 4),
            .max_rounds = cfg.getU32("agents.max_tool_rounds", 25),
            .redactions = redactionsFor(arena, cfg.getBool("debug.redact", true), pcfg.api_key),
            .temperature = cfg.getOptionalF64("model.temperature"),
            .max_output_tokens = cfg.getOptionalU32("model.max_output_tokens"),
            .cancel = &cancel,
            .git = turn_git,
            .worktree_root = blk: {
                const state_root = config_mod.userStateDir(arena, self.process_environ) orelse break :blk null;
                const root = std.fmt.allocPrint(arena, "{s}/worktrees", .{state_root}) catch break :blk null;
                std.Io.Dir.cwd().createDirPath(io, root) catch {};
                break :blk root;
            },
            .session_hint = self.store.manifest.id,
        };
        var tool_ctx = tool_mod.ToolContext{
            .io = io,
            .arena = arena,
            .workspace = cwd,
            .engine = &self.engine,
            .journal = &self.journal,
            .max_file_read_bytes = cfg.getU32("context.max_file_read_bytes", 262144),
            .timeout_s = cfg.getU32("agents.timeout_tool_s", 120),
            .use_external_tools = cfg.getBool("tools.external", true),
            .approval_ctx = &gate,
            .approval_fn = Gate.approve,
            .agent_spawn_fn = subagent_mod.spawnHookFn,
            .agent_spawn_ctx = &host,
            .agent_depth = 0,
            .agent_label = "parent",
            .mcp_list_fn = mcpListHook,
            .mcp_call_fn = mcpCallHook,
            .mcp_describe_fn = mcpDescribeHook,
            .mcp_ctx = self.mcp_registry orelse mcp_registry_sentinel,
            .skill_load_fn = skillLoadHook,
            .skill_ctx = self,
            .exec_start_fn = execStartHook,
            .exec_query_fn = execQueryHook,
            .exec_ctx = self,
        };
        tool_ctx.approval_ctx = &gate;
        tool_ctx.approval_fn = Gate.approve;
        setup_span.end("");

        var sink = TurnEvents{ .rt = self, .events = events };

        var hooks_span = trace_mod.Span.begin(self.trace, "turn.hooks");
        var hook_engine = hooks_mod.Engine.init(io, cwd, try hooks_mod.Engine.fromConfig(arena, cfg.get("hooks")), arena);
        const pre = hook_engine.dispatch(.before_agent, "{}");
        hooks_span.end("");
        if (pre.blocked) {
            statusFmt(events, .plain, "before_agent hook blocked the turn: {s}\n", .{pre.output});
            return .{};
        }

        // ---- automatic context compaction (C36, PLAN §24) ----
        if (cfg.getBool("context.auto_compact", true)) {
            // The provider's advertised window is folded into
            // `context.max_context_tokens` by first-run setup, so only the
            // configured budget is consulted here.
            const threshold = compaction_mod.thresholdTokens(cfg.getOptionalU32("context.max_context_tokens"), null);
            const plan = compaction_mod.planCompaction(self.history.items, threshold, cfg.getF64("context.compact_at_fraction", 0.8));
            if (plan.should_compact) {
                statusFmt(events, .plain, "[compacting context... {d} tokens]\n", .{plan.estimated_tokens});
                const res_opt: ?compaction_mod.Result = blk: {
                    break :blk compaction_mod.compact(arena, io, pcfg, &self.history, redactionsFor(arena, cfg.getBool("debug.redact", true), pcfg.api_key)) catch |err| {
                        statusFmt(events, .plain, "[compaction failed: {s}; continuing with full context]\n", .{@errorName(err)});
                        break :blk null;
                    };
                };
                if (res_opt) |res| {
                    self.history.clearRetainingCapacity();
                    try self.history.appendSlice(arena, res.history);
                    _ = try self.store.append(.{ .note = .{
                        .text = try std.fmt.allocPrint(arena, "context compacted: {d} -> {d} tokens", .{ res.tokens_before, res.tokens_after }),
                    } });
                    statusFmt(events, .plain, "[context compacted: {d} -> {d} tokens]\n", .{ res.tokens_before, res.tokens_after });
                }
            }
        }

        // Append the user message only after compaction and hooks, so the
        // rollback snapshot is never invalidated by history rewriting.
        const history_start = self.history.items.len;
        _ = try self.store.append(.{ .user = .{ .text = user_text } });
        try self.history.append(arena, .{ .role = .user, .content = user_text });

        const outcome = agent_engine.runTurn(.{
            .io = io,
            .arena = arena,
            .pcfg = pcfg,
            .system = system,
            .system_stable_len = system_stable_len,
            .history = &self.history,
            .tool_ctx = &tool_ctx,
            .callbacks = .{
                .ctx = &sink,
                .on_text = TurnEvents.onText,
                .on_tool_start = TurnEvents.onToolStart,
                .on_tool_result = TurnEvents.onToolResult,
                .on_notice = TurnEvents.onNotice,
                .on_assistant_message = TurnEvents.onAssistantMessage,
            },
            .cancel = &cancel,
            .include_tools = cfg.getBool("model.tools_enabled", true),
            .max_retries = cfg.getU32("agents.max_retries", 3),
            .max_tool_rounds = cfg.getU32("agents.max_tool_rounds", 25),
            .redactions = redactionsFor(arena, cfg.getBool("debug.redact", true), pcfg.api_key),
            .trace = self.trace,
        }) catch |err| {
            self.rollbackTurn(history_start);
            // Report the failure once, through the outcome: the caller renders
            // `error_message` (the REPL as a provider-error line, headless as an
            // NDJSON error event). Printing here too produced a second, empty
            // error line on the caller side.
            return .{ .ran = true, .status = .failed, .error_message = @errorName(err) };
        };

        _ = hook_engine.dispatch(.after_agent, "{}");
        const result = TurnOutcome{
            .ran = true,
            .status = outcome.status,
            .error_message = outcome.error_message,
            .usage = outcome.usage,
            .tool_calls = outcome.tool_calls,
        };
        switch (outcome.status) {
            .completed => {},
            .failed => {
                self.rollbackTurn(history_start);
                _ = try self.store.append(.{ .note = .{ .text = outcome.error_message } });
            },
            .cancelled => self.rollbackTurn(history_start),
        }
        if (outcome.usage.input_tokens > 0 or outcome.usage.output_tokens > 0) {
            // Session usage log (S254-258).
            const usage_line = try std.fmt.allocPrint(arena, "{{\"ts_ms\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"tool_calls\":{d}}}\n", .{
                @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms))),
                outcome.usage.input_tokens,
                outcome.usage.output_tokens,
                outcome.usage.cache_read_tokens,
                outcome.usage.cache_write_tokens,
                outcome.tool_calls,
            });
            const f = self.store.dir.createFile(io, "usage.jsonl", .{ .truncate = false }) catch null;
            if (f) |file| {
                defer file.close(io);
                const st = file.stat(io) catch null;
                const off: u64 = if (st) |s| s.size else 0;
                file.writePositionalAll(io, usage_line, off) catch {};
            }
        }
        try self.store.syncWatermark();
        return result;
    }
};

/// Bridges engine callbacks to `Events`, persisting what a resumed session
/// needs to replay (tool calls, tool results, assistant messages).
const TurnEvents = struct {
    rt: *SessionRuntime,
    events: *const Events,

    fn onText(ctx: *anyopaque, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.events.on_text(self.events.ctx, text);
    }

    fn onToolStart(ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.rt.store.append(.{ .tool_call = .{ .id = call_id, .name = name, .arguments_json = arguments_json } }) catch {};
        self.events.on_tool_start(self.events.ctx, call_id, name, arguments_json);
    }

    fn onToolResult(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.rt.store.append(.{ .tool_result = .{ .call_id = call_id, .status = @tagName(status), .output = output } }) catch {};
        self.events.on_tool_result(self.events.ctx, call_id, name, status, output);
    }

    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.events.on_notice(self.events.ctx, text);
    }

    /// Persist each completed assistant message (text and/or tool calls)
    /// as it is produced, so a resumed session can replay tool rounds.
    fn onAssistantMessage(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.rt.store.append(.{ .assistant = .{ .text = content, .tool_calls_json = tool_calls_json } }) catch {};
        self.events.on_assistant_message(self.events.ctx, content, tool_calls_json);
    }
};

/// Session-owned approval gate: policy tamper check (fail-closed, G99) and
/// session-scope grants. The human decision itself comes from
/// `Events.on_approval`.
pub const Gate = struct {
    rt: *SessionRuntime,
    events: *const Events,
    mutex: std.Io.Mutex = .init,
    /// SHA-256 of policy-relevant files at session start (G99/M0-T30).
    policy_hash: [32]u8 = [_]u8{0} ** 32,
    policy_hashed: bool = false,

    pub fn init(rt: *SessionRuntime, events: *const Events) Gate {
        return .{ .rt = rt, .events = events };
    }

    fn policyFingerprint(self: *Gate) ?[32]u8 {
        return self.rt.turn_cache.policyHash(std.Io.Dir.cwd());
    }

    /// Fail-closed on policy tampering between session start and now (G99).
    fn verifyPolicy(self: *Gate) bool {
        if (!self.policy_hashed) {
            self.policy_hash = self.policyFingerprint() orelse [_]u8{0} ** 32;
            self.policy_hashed = true;
            return true;
        }
        const current = self.policyFingerprint() orelse [_]u8{0} ** 32;
        if (!std.mem.eql(u8, &current, &self.policy_hash)) {
            self.events.on_status(self.events.ctx, .err, "\nPOLICY CHANGE DETECTED: .ifnh policy files changed since session start.\nApproval denied (fail-closed). Restart the session to adopt the new policy.\n");
            return false;
        }
        return true;
    }

    pub fn approve(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Gate = @ptrCast(@alignCast(ctx));
        self.mutex.lock(self.rt.io) catch return .denied;
        defer self.mutex.unlock(self.rt.io);
        if (!self.verifyPolicy()) return .denied;
        switch (self.events.on_approval(self.events.ctx, req)) {
            .approved_once => return .approved_once,
            .approved_session => {
                switch (req.grant) {
                    .command_prefix => |prefix| self.rt.engine.commandPrefixGrant(prefix, .session) catch {},
                    .path_write => |path| self.rt.engine.pathWriteGrant(path, .session) catch {},
                    .none => {},
                }
                return .approved_session;
            },
            .denied => return .denied,
        }
    }
};

fn statusFmt(events: *const Events, level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    events.on_status(events.ctx, level, text);
}

pub fn engineFromConfig(arena: std.mem.Allocator, cfg: *config_mod.Store) engine_mod.Engine {
    var e = engine_mod.Engine.init(arena, if (std.mem.eql(u8, cfg.getString("permissions.default_mode", "ask"), "auto")) .auto else .ask);
    e.read_globs = cfg.getStringList("permissions.read");
    e.write_globs = cfg.getStringList("permissions.write");
    e.command_allow = cfg.getStringList("permissions.command_allow");
    e.command_deny = cfg.getStringList("permissions.command_deny");
    e.env_allow = cfg.getStringList("permissions.env_allow");
    e.git_commits = gitPolicyFromConfig(cfg.getString("git.commits", "ask"), .ask);
    e.git_push = gitPolicyFromConfig(cfg.getString("git.push", "never"), .never);
    e.git_force_push = gitPolicyFromConfig(cfg.getString("git.force_push", "never"), .never);
    e.read_dotenv = cfg.getBool("permissions.read_dotenv", false);
    return e;
}

/// Parse a `git.*` ceiling; an unrecognized value falls back to the
/// fail-closed default for that action.
fn gitPolicyFromConfig(value: []const u8, fallback: engine_mod.GitPolicy) engine_mod.GitPolicy {
    return std.meta.stringToEnum(engine_mod.GitPolicy, value) orelse fallback;
}

fn redactionsFor(arena: std.mem.Allocator, enabled: bool, api_key: []const u8) []const []const u8 {
    if (!enabled or api_key.len < 8) return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    list.append(arena, api_key) catch return &.{};
    return list.items;
}

const mcp_registry_sentinel: *mcp_mod.Registry = @ptrFromInt(@alignOf(usize)); // never dereferenced

fn mcpListHook(ctx: *anyopaque, arena: std.mem.Allocator) []const u8 {
    const reg: *mcp_mod.Registry = @ptrCast(@alignCast(ctx));
    if (reg == mcp_registry_sentinel or reg.configs.len == 0) return "no MCP servers configured";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (reg.allTools(arena)) |st| {
        buf.print(arena, "{s}.{s}: {s}\n", .{ st.server, st.tool.name, st.tool.description }) catch {};
    }
    if (buf.items.len == 0) return "no MCP tools available";
    return buf.items;
}

fn mcpDescribeHook(ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8) []const u8 {
    const reg: *mcp_mod.Registry = @ptrCast(@alignCast(ctx));
    if (reg == mcp_registry_sentinel or reg.configs.len == 0) return "error: no MCP servers configured";
    const found = reg.describe(arena, server, tool) catch
        return std.fmt.allocPrint(arena, "error: server '{s}' unavailable", .{server}) catch "error: server unavailable";
    const t = found orelse
        return std.fmt.allocPrint(arena, "error: unknown tool {s}.{s}", .{ server, tool }) catch "error: unknown tool";
    return std.fmt.allocPrint(arena, "{s}.{s}: {s}\ninput schema: {s}", .{ server, t.name, t.description, t.input_schema_json }) catch "error: oom";
}

fn mcpCallHook(ctx: *anyopaque, arena: std.mem.Allocator, server: []const u8, tool: []const u8, arguments_json: []const u8) []const u8 {
    const reg: *mcp_mod.Registry = @ptrCast(@alignCast(ctx));
    if (reg == mcp_registry_sentinel) return "error: MCP not configured";
    const res = reg.call(arena, server, tool, arguments_json) catch |err| {
        return std.fmt.allocPrint(arena, "error: mcp call failed: {s}", .{@errorName(err)}) catch "error: mcp call failed";
    };
    if (res.is_error) {
        return std.fmt.allocPrint(arena, "mcp error: {s}", .{res.text}) catch res.text;
    }
    return res.text;
}

fn execStartHook(ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) []const u8 {
    const self: *SessionRuntime = @ptrCast(@alignCast(ctx));
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
    const self: *SessionRuntime = @ptrCast(@alignCast(ctx));
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

/// Background execution state for `/exec` rendering.
pub fn u8ToState(v: u8) executions_mod.State {
    return switch (v) {
        1 => .completed,
        2 => .stopped,
        3 => .failed_spawn,
        else => .running,
    };
}

fn skillLoadHook(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const self: *SessionRuntime = @ptrCast(@alignCast(ctx));
    const catalog = self.skills orelse return null;
    const cwd = std.Io.Dir.cwd();
    return skills_mod.loadSkill(cwd, self.io, arena, catalog, name) catch null;
}

// ---------------------------------------------------------------- tests

test "replay keeps assistant tool calls and tool results" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(arena);
    var rt = SessionRuntime{
        .io = io,
        .store = try session_mod.Session.create(tmp.dir, io, arena, "sessions", "/tmp/proj"),
        .journal = try journal_mod.Journal.open(io, arena, tmp.dir),
        .engine = engine_mod.Engine.init(arena, .ask),
        .user_keys = keys_mod.Keys.init(arena),
        .turn_cache = turn_cache_mod.TurnCache.init(io, arena),
        .http = .{ .allocator = arena, .io = io },
        .process_environ = &env,
        .environ = &env,
    };
    defer rt.http.deinit();
    defer rt.store.close();

    _ = try rt.store.append(.{ .user = .{ .text = "read a" } });
    _ = try rt.store.append(.{ .assistant = .{ .text = "", .tool_calls_json = "[{\"id\":\"c1\",\"name\":\"read\",\"arguments_json\":\"{}\"}]" } });
    _ = try rt.store.append(.{ .tool_call = .{ .id = "c1", .name = "read", .arguments_json = "{}" } });
    _ = try rt.store.append(.{ .tool_result = .{ .call_id = "c1", .status = "failed", .output = "no such file" } });
    _ = try rt.store.append(.{ .assistant = .{ .text = "done" } });

    const Sink = struct {
        fn text(_: *anyopaque, _: []const u8) void {}
        fn status(_: *anyopaque, _: Level, _: []const u8) void {}
        fn start(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
        fn result(_: *anyopaque, _: []const u8, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
        fn notice(_: *anyopaque, _: []const u8) void {}
        fn message(_: *anyopaque, _: []const u8, _: ?[]const u8) void {}
        fn approve(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
            return .denied;
        }
    };
    var dummy: u8 = 0;
    const events = Events{
        .ctx = @ptrCast(&dummy),
        .on_text = Sink.text,
        .on_status = Sink.status,
        .on_tool_start = Sink.start,
        .on_tool_result = Sink.result,
        .on_notice = Sink.notice,
        .on_assistant_message = Sink.message,
        .on_approval = Sink.approve,
    };

    try rt.rebuildHistory(arena, &events);
    try std.testing.expectEqual(@as(usize, 4), rt.history.items.len);

    try std.testing.expectEqual(core_types.ChatRole.user, rt.history.items[0].role);
    // The assistant tool-call message survives resume, so the tool result can
    // still be paired on the wire.
    try std.testing.expectEqual(core_types.ChatRole.assistant, rt.history.items[1].role);
    try std.testing.expect(rt.history.items[1].tool_calls_json != null);
    try std.testing.expectEqualStrings("c1", rt.history.items[2].tool_call_id.?);
    try std.testing.expectEqual(core_types.ChatRole.tool, rt.history.items[2].role);
    try std.testing.expect(rt.history.items[2].is_error);
    try std.testing.expectEqualStrings("done", rt.history.items[3].content);
}
