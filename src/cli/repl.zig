//! Interactive streaming REPL (DESIGN §6, DECISIONS section R).
//!
//! Line-oriented inline streaming UI: works on a TTY, over SSH, and with
//! piped stdin/stdout. Slash commands are built-in; disk-backed commands
//! load from `.ifnh/commands/*.md`. Approvals are interactive prompts that
//! can grant session-scoped permission patterns.

const std = @import("std");
const fsutil = @import("../core/fsutil.zig");
const config_mod = @import("../core/config/config.zig");
const keys_mod = @import("../core/config/keys.zig");
const session_mod = @import("../core/session/store.zig");
const journal_mod = @import("../core/journal.zig");
const engine_mod = @import("../core/permissions/engine.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const agent_engine = @import("../core/agent/engine.zig");
const subagent_mod = @import("../core/agent/subagent.zig");
const git_mod = @import("../core/git.zig");
const mcp_mod = @import("../core/mcp.zig");
const skills_mod = @import("../core/skills.zig");
const hooks_mod = @import("../core/hooks.zig");
const compaction_mod = @import("../core/compaction.zig");
const lifecycle_mod = @import("../core/lifecycle.zig");
const executions_mod = @import("../core/executions.zig");
const style_mod = @import("../ui/style.zig");
const secret_mod = @import("../ui/secret.zig");
const models_mod = @import("../providers/models.zig");
const tool_mod = @import("../tools/tool.zig");
const core_types = @import("../core/types.zig");
const openai = @import("../providers/openai.zig");
const anthropic = @import("../providers/anthropic.zig");

const max_output_bytes: usize = 256 * 1024;

pub const Options = struct {
    resume_id: ?[]const u8 = null,
    json: bool = false,
    no_color: bool = false,
};

const Session = struct {
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
    user_keys: ?*keys_mod.Keys = null,
};

var global_user_keys: keys_mod.Keys = undefined;

var palette: style_mod.Palette = .{};
var g_environ: ?*const std.process.Environ.Map = null;
var g_no_color: bool = false;
var g_merged_env: ?*std.process.Environ.Map = null; // mutable overlay (provider keys)

fn envLookup(key: []const u8) ?[]const u8 {
    const e = g_environ orelse return null;
    return e.get(key);
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    opts: Options,
) !void {
    g_environ = environ;
    g_no_color = opts.no_color;

    // Persistent provider keys (~/.config/ifnh/env) overlay the process
    // environment for lookups (D022; real env wins).
    var user_keys = keys_mod.Keys.init(arena);
    user_keys.load(io, arena, environ);
    var merged = std.process.Environ.Map.init(arena);
    var keit = environ.iterator();
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
    g_environ = merged_env;
    g_merged_env = merged_env;
    global_user_keys = user_keys;
    const cwd = std.Io.Dir.cwd();

    // ---- configuration ----
    var cfg = try config_mod.load(arena, io, environ, cwd);
    defer cfg.deinit();
    for (cfg.errors.items) |err| {
        try out(io, "config error [{s}]: {s}\n", .{ err.path, err.message });
    }
    if (cfg.errors.items.len > 0) return error.InvalidConfig;
    for (cfg.warnings.items) |w| try out(io, "config warning: {s}\n", .{w});

    palette = style_mod.Palette.detect(arena, io, envLookup, cfg.getBool("ui.colors", true), g_no_color);

    // ---- first-run setup (interactive TTY only; skipped when piped) ----
    if (cfg.getString("model.model", "").len == 0 and
        (std.Io.File.stdin().isTty(io) catch false))
    {
        runFirstRunSetup(io, arena, &cfg, environ) catch {};
    }

    // ---- session state (zero-config: lazily create .ifnh) ----
    ensureIfnh(io, cwd) catch {};
    const sessions_dir_name = ".ifnh/sessions";

    var sess: Session = blk: {
        if (opts.resume_id) |id| {
            const store = try session_mod.Session.open(cwd, io, arena, sessions_dir_name, id);
            const j = try journal_mod.Journal.open(io, arena, store.dir);
            var s = Session{ .io = io, .store = store, .journal = j, .engine = engineFromConfig(arena, &cfg) };
            try rebuildHistory(arena, &s);
            break :blk s;
        } else {
            const cwd_copy: []const u8 = if (environ.get("PWD")) |pwd| pwd else ".";
            const store = try session_mod.Session.create(cwd, io, arena, sessions_dir_name, cwd_copy);
            const j = try journal_mod.Journal.open(io, arena, store.dir);
            break :blk Session{ .io = io, .store = store, .journal = j, .engine = engineFromConfig(arena, &cfg) };
        }
    };
    sess.user_keys = &global_user_keys;
    defer {
        if (sess.executions) |reg| reg.deinit(); // kill background children (I125)
        if (sess.mcp_registry) |reg| reg.deinit();
        sess.store.close();
        sess.journal.close();
    }

    // ---- skills catalog (K148/149) ----
    sess.skills = blk: {
        const user_dir = std.fmt.allocPrint(arena, "{s}/.config/ifnh/skills", .{environ.get("HOME") orelse ""}) catch break :blk null;
        const catalog = skills_mod.discover(cwd, io, arena, user_dir) catch break :blk null;
        break :blk catalog;
    };

    // ---- background executions (I123-125) ----
    sess.executions = blk: {
        const reg = arena.create(executions_mod.Registry) catch break :blk null;
        reg.* = executions_mod.Registry.init(io, arena, cwd);
        break :blk reg;
    };

    // ---- MCP registry (lazy servers, J137/138) ----
    sess.mcp_registry = blk: {
        const reg = arena.create(mcp_mod.Registry) catch break :blk null;
        reg.* = mcp_mod.Registry.init(io, arena, cfg.get("mcp_servers")) catch break :blk null;
        break :blk reg;
    };

    // ---- provider ----
    const pcfg = buildProviderConfig(&cfg, environ);
    const provider_name = cfg.getString("model.provider", "openai");

    // ---- instructions ----
    const builtin_prompt = system_prompt.system_prompt;
    const instr = try instructions_mod.assemble(cwd, io, arena, builtin_prompt, &.{});

    // ---- welcome ----
    {
        const key_note = if (pcfg.api_key.len == 0) blk: {
            const key_env = cfg.getOptionalString("model.api_key_env") orelse
                (if (std.mem.eql(u8, provider_name, "anthropic")) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
            break :blk std.fmt.allocPrint(arena, " — {s}run /provider key {s} <value>{s}", .{ palette.warn("", arena), key_env, "\x1b[0m" }) catch ", no api key";
        } else "";
        try out(io, "{s}ifnh session{s} {s} ({s}{s}/{s}{s}){s}\n", .{
            palette.accent("", arena),
            "\x1b[0m",
            sess.store.manifest.id,
            palette.dim("", arena),
            provider_name,
            pcfg.model,
            "\x1b[0m",
            key_note,
        });
        try out(io, "{s}type a message, or /help for commands{s}\n", .{ palette.dim("", arena), "\x1b[0m" });
    }

    // ---- input loop ----
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);

    while (true) {
        try out(io, "> ", .{});
        const line_raw = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try out(io, "\n", .{});
                break;
            },
            else => break,
        };
        var line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        if (line[0] == '/') {
            const cmd_end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const cmd = line[1..cmd_end];
            const rest = if (cmd_end < line.len) std.mem.trim(u8, line[cmd_end + 1 ..], " \t") else "";
            const action = handleCommand(io, arena, cwd, environ, &sess, &cfg, cmd, rest, instr);
            switch (action) {
                .quit => break,
                .submit => |prompt| {
                    try submitTurn(io, arena, environ, &sess, &cfg, buildProviderConfig(&cfg, environ), instr.text, prompt, cwd);
                },
                .none => {},
            }
            continue;
        }

        // ---- policy boundary (D029): re-read disk config, re-assemble
        // instructions with focus dirs from recent tool activity ----
        if (reloadConfig(io, arena, cwd, environ, &sess)) |fresh| {
            cfg.deinit();
            cfg = fresh;
        }
        const focus = instructions_mod.focusDirsFromHistory(arena, sess.history.items, 8);
        const turn_instr = instructions_mod.assemble(cwd, io, arena, system_prompt.system_prompt, focus) catch instr;
        // Skills catalog appendix (budgeted, K148).
        const skill_prompt = blk: {
            if (sess.skills) |catalog| {
                const rendered = skills_mod.renderCatalog(arena, catalog) catch "";
                if (rendered.len > 0) {
                    break :blk std.fmt.allocPrint(arena, "{s}\n\nAvailable skills (load with the skill tool):\n{s}", .{ turn_instr.text, rendered }) catch turn_instr.text;
                }
            }
            break :blk turn_instr.text;
        };

        try submitTurn(io, arena, environ, &sess, &cfg, buildProviderConfig(&cfg, environ), skill_prompt, line, cwd);
    }
}

// ---------------------------------------------------------------- turn flow

fn submitTurn(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    sess: *Session,
    cfg: *config_mod.Store,
    pcfg: agent_engine.ProviderConfig,
    system: []const u8,
    user_text: []const u8,
    cwd: std.Io.Dir,
) !void {
    if (pcfg.model.len == 0) {
        try out(io, "no model configured — run /provider set <openai|anthropic> <model> [base_url] [key_env]\n", .{});
        return;
    }
    if (pcfg.api_key.len == 0) {
        const key_env = cfg.getOptionalString("model.api_key_env") orelse "OPENAI_API_KEY";
        try out(io, "note: no api key — run /provider key {s} <value> (or export it) before sending a message\n", .{key_env});
    }

    _ = try sess.store.append(.{ .user = .{ .text = user_text } });
    try sess.history.append(arena, .{ .role = .user, .content = user_text });

    var cancel = std.atomic.Value(bool).init(false);
    var approver = Approver{ .io = io, .engine = &sess.engine };
    var host = subagent_mod.Host{
        .io = io,
        .workspace = cwd,
        .base_system = system,
        .provider = pcfg.provider,
        .base_url = pcfg.base_url,
        .api_key = pcfg.api_key,
        .default_model = pcfg.model,
        .mode = sess.engine.mode,
        .read_globs = sess.engine.read_globs,
        .write_globs = sess.engine.write_globs,
        .command_allow = sess.engine.command_allow,
        .command_deny = sess.engine.command_deny,
        .env_allow = sess.engine.env_allow,
        .journal = &sess.journal,
        .approval_ctx = &approver,
        .approval_fn = Approver.approve,
        .max_depth = cfg.getU32("agents.max_depth", 1),
        .max_concurrent = cfg.getU32("agents.max_concurrent", 4),
        .max_rounds = 25,
        .redactions = redactionsFor(arena, pcfg.api_key),
        .temperature = cfg.getOptionalF64("model.temperature"),
        .max_output_tokens = cfg.getOptionalU32("model.max_output_tokens"),
        .cancel = &cancel,
        .git = blk: {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = cwd.realPath(io, &path_buf) catch break :blk null;
            const repo_path = arena.dupe(u8, path_buf[0..n]) catch break :blk null;
            const g = git_mod.Git.init(io, repo_path);
            if (!g.isRepo(arena)) break :blk null;
            break :blk g;
        },
        .worktree_root = blk: {
            const home = environ.get("HOME") orelse break :blk null;
            const root = std.fmt.allocPrint(arena, "{s}/.local/state/ifnh/worktrees", .{home}) catch break :blk null;
            std.Io.Dir.cwd().createDirPath(io, root) catch {};
            break :blk root;
        },
        .session_hint = sess.store.manifest.id,
    };
    var tool_ctx = tool_mod.ToolContext{
        .io = io,
        .arena = arena,
        .workspace = cwd,
        .engine = &sess.engine,
        .journal = &sess.journal,
        .max_file_read_bytes = cfg.getU32("context.max_file_read_bytes", 262144),
        .approval_ctx = &approver,
        .approval_fn = Approver.approve,
        .agent_spawn_fn = subagent_mod.spawnHookFn,
        .agent_spawn_ctx = &host,
        .agent_depth = 0,
        .agent_label = "parent",
        .mcp_list_fn = mcpListHook,
        .mcp_call_fn = mcpCallHook,
        .mcp_ctx = sess.mcp_registry orelse mcp_registry_sentinel,
        .skill_load_fn = skillLoadHook,
        .skill_ctx = sess,
        .exec_start_fn = execStartHook,
        .exec_query_fn = execQueryHook,
        .exec_ctx = sess,
    };
    tool_ctx.approval_ctx = &approver;
    tool_ctx.approval_fn = Approver.approve;

    const TurnUi = struct {
        io: std.Io,
        fn onText(ctx: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.Io.File.stdout().writeStreamingAll(self.io, text) catch {};
        }
        fn onToolStart(ctx: *anyopaque, name: []const u8, arguments_json: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            out(self.io, "\n[tool] {s} {s}\n", .{ name, arguments_json }) catch {};
        }
        fn onToolResult(ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = name;
            const max_show: usize = 400;
            const shown = if (output.len > max_show) output[0..max_show] else output;
            var scratch: [64]u8 = undefined;
            const tag = std.fmt.bufPrint(&scratch, "[{s}]", .{@tagName(status)}) catch "[?]";
            const pa: style_mod.Palette = palette;
            const colored = switch (status) {
                .ok => pa.green(tag, std.heap.page_allocator),
                .denied => pa.yellow(tag, std.heap.page_allocator),
                else => pa.red(tag, std.heap.page_allocator),
            };
            out(self.io, "{s} {s}{s}\n", .{ colored, shown, if (output.len > max_show) "..." else "" }) catch {};
        }
        fn onNotice(ctx: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            out(self.io, "! {s}\n", .{text}) catch {};
        }
    };
    var ui = TurnUi{ .io = io };

    var hook_engine = hooks_mod.Engine.init(io, cwd, try hooks_mod.Engine.fromConfig(arena, cfg.get("hooks")), arena);
    const pre = hook_engine.dispatch(.before_agent, "{}");
    if (pre.blocked) {
        try out(io, "before_agent hook blocked the turn: {s}\n", .{pre.output});
        return;
    }

    // ---- automatic context compaction (C36, PLAN §24) ----
    if (cfg.getBool("context.auto_compact", true)) {
        const threshold: usize = cfg.getU32("context.max_context_tokens", 96_000);
        const plan = compaction_mod.planCompaction(sess.history.items, threshold, cfg.getF64("context.compact_at_fraction", 0.8));
        if (plan.should_compact) {
            try out(io, "[compacting context... {d} tokens]\n", .{plan.estimated_tokens});
            const res_opt: ?compaction_mod.Result = blk: {
                break :blk compaction_mod.compact(arena, io, pcfg, &sess.history, redactionsFor(arena, pcfg.api_key)) catch |err| {
                    try out(io, "[compaction failed: {s}; continuing with full context]\n", .{@errorName(err)});
                    break :blk null;
                };
            };
            if (res_opt) |res| {
                sess.history.clearRetainingCapacity();
                try sess.history.appendSlice(arena, res.history);
                _ = try sess.store.append(.{ .note = .{
                    .text = try std.fmt.allocPrint(arena, "context compacted: {d} -> {d} tokens", .{ res.tokens_before, res.tokens_after }),
                } });
                try out(io, "[context compacted: {d} -> {d} tokens]\n", .{ res.tokens_before, res.tokens_after });
            }
        }
    }

    const outcome = agent_engine.runTurn(.{
        .io = io,
        .arena = arena,
        .pcfg = pcfg,
        .system = system,
        .history = &sess.history,
        .tool_ctx = &tool_ctx,
        .callbacks = .{
            .ctx = &ui,
            .on_text = TurnUi.onText,
            .on_tool_start = TurnUi.onToolStart,
            .on_tool_result = TurnUi.onToolResult,
            .on_notice = TurnUi.onNotice,
        },
        .cancel = &cancel,
        .max_retries = cfg.getU32("agents.max_retries", 3),
        .redactions = redactionsFor(arena, pcfg.api_key),
    }) catch |err| {
        try out(io, "\nturn failed: {s}\n", .{@errorName(err)});
        return;
    };

    _ = hook_engine.dispatch(.after_agent, "{}");
    try out(io, "\n", .{});
    switch (outcome.status) {
        .completed => {
            _ = try sess.store.append(.{ .assistant = .{ .text = outcome.reply } });
        },
        .failed => {
            try out(io, "provider error: {s}\n", .{outcome.error_message});
            _ = try sess.store.append(.{ .note = .{ .text = outcome.error_message } });
        },
        .cancelled => {
            try out(io, "(interrupted)\n", .{});
            _ = try sess.store.append(.interrupted);
        },
    }
    if (outcome.usage.input_tokens > 0 or outcome.usage.output_tokens > 0) {
        try out(io, "[tokens: {d} in / {d} out, {d} tool calls]\n", .{ outcome.usage.input_tokens, outcome.usage.output_tokens, outcome.tool_calls });
        // Session usage log (S254-258).
        const usage_line = try std.fmt.allocPrint(arena, "{{\"ts_ms\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"tool_calls\":{d}}}\n", .{
            @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms))),
            outcome.usage.input_tokens,
            outcome.usage.output_tokens,
            outcome.tool_calls,
        });
        var usage_buf: [256]u8 = undefined;
        @memcpy(usage_buf[0..usage_line.len], usage_line);
        const f = sess.store.dir.createFile(io, "usage.jsonl", .{ .truncate = false }) catch null;
        if (f) |file| {
            defer file.close(io);
            const st = file.stat(io) catch null;
            const off: u64 = if (st) |s| s.size else 0;
            file.writePositionalAll(io, usage_line, off) catch {};
        }
    }
    try sess.store.syncWatermark();
}

const Approver = struct {
    io: std.Io,
    engine: *engine_mod.Engine,
    mutex: std.Io.Mutex = .init,
    /// SHA-256 of policy-relevant files at session start (G99/M0-T30).
    policy_hash: [32]u8 = [_]u8{0} ** 32,
    policy_hashed: bool = false,

    fn policyFingerprint(self: *Approver, arena: std.mem.Allocator) ?[32]u8 {
        const cwd = std.Io.Dir.cwd();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const files = [_][]const u8{
            ".ifnh/config.json",
            ".ifnh/config.d",
            ".ifnh/lifecycle",
            ".ifnh/instructions",
            ".ifnh/commands",
            ".ifnh/skills",
            "AGENTS.md",
            "CLAUDE.md",
        };
        var any = false;
        for (files) |f| {
            const stat = cwd.statFile(self.io, f, .{}) catch continue;
            any = true;
            hasher.update(f);
            if (stat.kind == .directory) {
                // Hash directory entries (names only; content via children below).
                var d = cwd.openDir(self.io, f, .{ .iterate = true }) catch continue;
                defer d.close(self.io);
                var it = d.iterate();
                while (it.next(self.io) catch null) |entry| {
                    hasher.update(entry.name);
                    const child = std.fmt.allocPrint(arena, "{s}/{s}", .{ f, entry.name }) catch continue;
                    if (fsutil.readSmallFile(cwd, self.io, arena, child, 1024 * 1024)) |content| {
                        hasher.update(content);
                    } else |_| {}
                }
            } else if (fsutil.readSmallFile(cwd, self.io, arena, f, 1024 * 1024)) |content| {
                hasher.update(content);
            } else |_| {}
        }
        if (!any) return null;
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    /// Fail-closed on policy tampering between session start and now (G99).
    fn verifyPolicy(self: *Approver, arena: std.mem.Allocator) bool {
        if (!self.policy_hashed) {
            self.policy_hash = self.policyFingerprint(arena) orelse [_]u8{0} ** 32;
            self.policy_hashed = true;
            return true;
        }
        const current = self.policyFingerprint(arena) orelse [_]u8{0} ** 32;
        if (!std.mem.eql(u8, &current, &self.policy_hash)) {
            out(self.io, "\nPOLICY CHANGE DETECTED: .ifnh policy files changed since session start.\nApproval denied (fail-closed). Restart the session to adopt the new policy.\n", .{}) catch {};
            return false;
        }
        return true;
    }

    fn approve(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Approver = @ptrCast(@alignCast(ctx));
        self.mutex.lock(self.io) catch return .denied;
        defer self.mutex.unlock(self.io);
        var fba: [4096]u8 = undefined;
        var fba_state = std.heap.FixedBufferAllocator.init(&fba);
        if (!self.verifyPolicy(fba_state.allocator())) return .denied;
        const head = std.fmt.allocPrint(std.heap.page_allocator, "\n{s}approval needed:{s} {s}\n  {s}\n[y] once  [s] session  [n] no: ", .{
            palette.warn("", std.heap.page_allocator), "\x1b[0m", req.title, req.detail,
        }) catch "approval needed: ";
        out(self.io, "{s}", .{head}) catch return .denied;
        var buf: [64]u8 = undefined;
        var stdin_r = std.Io.File.stdin().reader(self.io, &buf);
        const line = stdin_r.interface.takeDelimiterInclusive('\n') catch return .denied;
        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(answer, "y")) {
            return .approved_once;
        } else if (std.ascii.eqlIgnoreCase(answer, "s")) {
            switch (req.grant) {
                .command_prefix => |prefix| self.engine.commandPrefixGrant(prefix, .session) catch {},
                .path_write => |path| self.engine.pathWriteGrant(path, .session) catch {},
                .none => {},
            }
            return .approved_session;
        }
        return .denied;
    }
};

// ---------------------------------------------------------------- history rebuild

fn rebuildHistory(arena: std.mem.Allocator, sess: *Session) !void {
    const events = try sess.store.readEvents(arena, 10_000);
    for (events) |ev| {
        switch (ev.event) {
            .user => |v| try sess.history.append(arena, .{ .role = .user, .content = v.text }),
            .assistant => |v| try sess.history.append(arena, .{
                .role = .assistant,
                .content = v.text,
                .tool_calls_json = v.tool_calls_json,
            }),
            .tool_call => {},
            .tool_result => |v| try sess.history.append(arena, .{
                .role = .tool,
                .content = v.output,
                .tool_call_id = v.call_id,
            }),
            .note, .interrupted => {},
        }
    }
}

/// Re-read disk config at a turn boundary, re-applying session overrides
/// and preserving permission grants (T10/D029). Returns the replacement
/// store, or null when the reload failed (caller keeps the last-good one).
fn reloadConfig(
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    sess: *Session,
) ?config_mod.Store {
    var fresh = config_mod.load(arena, io, environ, cwd) catch return null;
    for (sess.overrides.items) |ov| {
        fresh.applyOverride(ov.path, ov.json, .{ .layer = .session, .origin = "session" }) catch {};
    }
    if (fresh.errors.items.len > 0) {
        fresh.deinit();
        return null; // keep the last-good config on invalid reload
    }
    // Rebuild the engine against the fresh store's slices, carrying grants
    // (grant patterns were duped into the long-lived REPL arena).
    var new_engine = engineFromConfig(arena, &fresh);
    new_engine.grants = sess.engine.grants;
    sess.engine = new_engine;
    return fresh;
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

fn execStartHook(ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) []const u8 {
    const sess: *Session = @ptrCast(@alignCast(ctx));
    const reg = sess.executions orelse return "error: background executions unavailable";
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
    const sess: *Session = @ptrCast(@alignCast(ctx));
    const reg = sess.executions orelse return "error: background executions unavailable";
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

fn u8ToStateLocal(v: u8) executions_mod.State {
    return switch (v) {
        1 => .completed,
        2 => .stopped,
        3 => .failed_spawn,
        else => .running,
    };
}

fn skillLoadHook(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const sess: *Session = @ptrCast(@alignCast(ctx));
    const catalog = sess.skills orelse return null;
    const cwd = std.Io.Dir.cwd();
    return skills_mod.loadSkill(cwd, sess.io, arena, catalog, name) catch null;
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

fn redactionsFor(arena: std.mem.Allocator, api_key: []const u8) []const []const u8 {
    if (api_key.len < 8) return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    list.append(arena, api_key) catch return &.{};
    return list.items;
}

/// Persist provider settings into .ifnh/config.json (developer action,
/// not an agent write): read -> set paths -> atomic write.
fn persistProjectConfig(
    io: std.Io,
    arena: std.mem.Allocator,
    cfg: *config_mod.Store,
    prov: []const u8,
    model_name: []const u8,
    base_url: ?[]const u8,
    key_env: ?[]const u8,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var root: std.json.Value = blk: {
        const text = fsutil.readSmallFile(cwd, io, arena, ".ifnh/config.json", config_mod.max_config_bytes) catch
            break :blk .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
    };
    var tmp_store = try config_mod.Store.init(arena);
    defer tmp_store.deinit();
    tmp_store.value = root;
    try tmp_store.setPath("model.provider", .{ .string = prov });
    try tmp_store.setPath("model.model", .{ .string = model_name });
    if (base_url) |b| try tmp_store.setPath("model.base_url", .{ .string = b });
    if (key_env) |k| try tmp_store.setPath("model.api_key_env", .{ .string = k });
    root = tmp_store.value;

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = aw.written() });

    // Live-apply to this session too.
    try cfg.applyOverride("model.provider", try std.fmt.allocPrint(arena, "\"{s}\"", .{prov}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    try cfg.applyOverride("model.model", try std.fmt.allocPrint(arena, "\"{s}\"", .{model_name}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    if (base_url) |b| {
        try cfg.applyOverride("model.base_url", try std.fmt.allocPrint(arena, "\"{s}\"", .{b}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    }
    if (key_env) |k| {
        try cfg.applyOverride("model.api_key_env", try std.fmt.allocPrint(arena, "\"{s}\"", .{k}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    }
    return "saved .ifnh/config.json — applied to this session";
}

// -------------------------------------------------------------- first-run setup

pub const ProviderPreset = struct {
    id: []const u8, // "openai" | "anthropic"
    label: []const u8,
    base_url: []const u8,
    key_env: []const u8,
    default_model: []const u8,
    needs_key: bool,
};

pub const presets = [_]ProviderPreset{
    .{ .id = "openai", .label = "OpenRouter", .base_url = "https://openrouter.ai/api/v1", .key_env = "OPENROUTER_API_KEY", .default_model = "openrouter/auto", .needs_key = true },
    .{ .id = "anthropic", .label = "Anthropic", .base_url = "https://api.anthropic.com", .key_env = "ANTHROPIC_API_KEY", .default_model = "claude-sonnet-4-6", .needs_key = true },
    .{ .id = "openai", .label = "OpenAI", .base_url = "https://api.openai.com/v1", .key_env = "OPENAI_API_KEY", .default_model = "gpt-5.1", .needs_key = true },
    .{ .id = "openai", .label = "Ollama (local)", .base_url = "http://localhost:11434/v1", .key_env = "", .default_model = "qwen3-coder", .needs_key = false },
};

/// A model id must not look like a credential: rejects API-key shapes
/// (the `sk-or-v1-... is not a valid model ID` bug class), overlong
/// strings, and multi-token values.
pub fn validModelId(s: []const u8) bool {
    if (s.len == 0 or s.len > 100) return false;
    if (std.mem.startsWith(u8, s, "sk-")) return false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '=' or c == '"') return false;
    }
    return true;
}

pub fn presetForChoice(choice: u8) ?ProviderPreset {
    if (choice == 0 or choice > presets.len) return null;
    return presets[choice - 1];
}

/// Guided first-run setup. Only invoked when stdin is a TTY and no model
/// is configured. Flow: provider -> API key (noecho) -> live model list
/// picker (or typed fallback) -> persist to USER config so every project
/// inherits it.
fn runFirstRunSetup(
    io: std.Io,
    arena: std.mem.Allocator,
    cfg: *config_mod.Store,
    environ: *const std.process.Environ.Map,
) !void {
    try out(io, "{s}", .{palette.heading("\nfirst-run setup: no model is configured yet.", arena)});
    try out(io, "\npick a provider (enter a number, or press enter to skip and configure later with /provider):\n", .{});
    for (presets, 0..) |p, i| {
        try out(io, "  {d}) {s}\n", .{ i + 1, p.label });
    }
    try out(io, "choice: ", .{});

    var stdin_buf: [256]u8 = undefined;
    var stdin_r = std.Io.File.stdin().reader(io, &stdin_buf);
    const line_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
    const line = std.mem.trim(u8, line_raw, " \t\r\n");
    if (line.len == 0) {
        try out(io, "{s}(skipped — configure later with /provider set ...)\n", .{palette.dim("", arena)});
        return;
    }
    const choice = std.fmt.parseInt(u8, line, 10) catch return error.SetupAborted;
    const preset = presetForChoice(choice) orelse return error.SetupAborted;

    // API key first (noecho, never echoed back).
    var key_value: []const u8 = "";
    if (preset.needs_key) {
        try out(io, "{s}\n", .{palette.info(preset.key_env, arena)});
        try out(io, "paste your API key (input hidden): ", .{});
        key_value = secret_mod.readSecret(io, arena) catch "";
        if (key_value.len == 0) {
            try out(io, "{s}no key entered — continuing; set it later with /provider key {s} <value>{s}\n", .{
                palette.warn("", arena), preset.key_env, "\x1b[0m",
            });
        }
    }

    // Live model list; typed fallback when unavailable.
    var model_name: []const u8 = preset.default_model;
    const models_res = models_mod.fetchModels(arena, io, preset.base_url, key_value, std.mem.eql(u8, preset.id, "anthropic"));
    switch (models_res) {
        .models => |list| {
            try out(io, "{s}({d} models available — enter a number, or type a model id){s}\n", .{
                palette.dim("", arena), list.len, "\x1b[0m",
            });
            const shown = @min(list.len, 30);
            for (list[0..shown], 0..) |m, i| {
                try out(io, "  {d}) {s}\n", .{ i + 1, m });
            }
            if (list.len > shown) {
                try out(io, "  {s}...and {d} more — type the exact model id{s}\n", .{ palette.dim("", arena), list.len - shown, "\x1b[0m" });
            }
            try out(io, "model: ", .{});
            const pick_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
            const pick = std.mem.trim(u8, pick_raw, " \t\r\n");
            if (pick.len > 0) {
                if (std.fmt.parseInt(usize, pick, 10)) |n| {
                    if (n >= 1 and n <= list.len) {
                        model_name = list[n - 1];
                    } else {
                        try out(io, "{s}number not in list; using default {s}{s}\n", .{ palette.warn("", arena), preset.default_model, "\x1b[0m" });
                    }
                } else |_| {
                    if (validModelId(pick)) {
                        model_name = pick;
                    } else {
                        try out(io, "{s}that does not look like a model id; using default {s}{s}\n", .{ palette.warn("", arena), preset.default_model, "\x1b[0m" });
                    }
                }
            }
        },
        .failure => |why| {
            try out(io, "{s}could not fetch models ({s}) — type the model id manually.{s}\n", .{ palette.warn("", arena), why, "\x1b[0m" });
            try out(io, "model [{s}]: ", .{preset.default_model});
            const pick_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
            const pick = std.mem.trim(u8, pick_raw, " \t\r\n");
            if (pick.len > 0 and validModelId(pick)) model_name = pick;
        },
    }

    // Persist to USER config (applies to all projects).
    const user_cfg_path = config_mod.userConfigPath(arena, environ) orelse return error.SetupAborted;
    const cwd = std.Io.Dir.cwd();
    var root: std.json.Value = blk: {
        const text = fsutil.readSmallFile(cwd, io, arena, user_cfg_path, config_mod.max_config_bytes) catch
            break :blk .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
    };
    var tmp_store = try config_mod.Store.init(arena);
    defer tmp_store.deinit();
    tmp_store.value = root;
    try tmp_store.setPath("model.provider", .{ .string = preset.id });
    try tmp_store.setPath("model.model", .{ .string = model_name });
    try tmp_store.setPath("model.base_url", .{ .string = preset.base_url });
    if (preset.key_env.len > 0) {
        try tmp_store.setPath("model.api_key_env", .{ .string = preset.key_env });
    }
    root = tmp_store.value;
    if (std.mem.lastIndexOfScalar(u8, user_cfg_path, '/')) |slash| {
        try cwd.createDirPath(io, user_cfg_path[0..slash]);
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = user_cfg_path, .data = aw.written() });

    // Store the key.
    if (key_value.len > 0) {
        try global_user_keys.store(io, arena, environ, preset.key_env, key_value);
        g_merged_env.?.put(preset.key_env, key_value) catch {};
    }

    // Live-apply.
    try cfg.applyOverride("model.provider", try std.fmt.allocPrint(arena, "\"{s}\"", .{preset.id}), .{ .layer = .user, .origin = user_cfg_path });
    try cfg.applyOverride("model.model", try std.fmt.allocPrint(arena, "\"{s}\"", .{model_name}), .{ .layer = .user, .origin = user_cfg_path });
    try cfg.applyOverride("model.base_url", try std.fmt.allocPrint(arena, "\"{s}\"", .{preset.base_url}), .{ .layer = .user, .origin = user_cfg_path });
    if (preset.key_env.len > 0) {
        try cfg.applyOverride("model.api_key_env", try std.fmt.allocPrint(arena, "\"{s}\"", .{preset.key_env}), .{ .layer = .user, .origin = user_cfg_path });
    }

    try out(io, "\n{s}setup complete — model {s}/{s} saved to {s}{s}\n", .{
        palette.success("", arena), preset.id, model_name, user_cfg_path, "\x1b[0m",
    });
    if (key_value.len > 0) {
        try out(io, "{s}key stored ({s}){s}\n", .{ palette.dim("", arena), secret_mod.masked(arena, key_value), "\x1b[0m" });
    }
}

fn buildProviderConfig(cfg: *config_mod.Store, environ: *const std.process.Environ.Map) agent_engine.ProviderConfig {
    const provider_name = cfg.getString("model.provider", "openai");
    const is_anthropic = std.mem.eql(u8, provider_name, "anthropic");
    const base_url = cfg.getOptionalString("model.base_url") orelse
        (if (is_anthropic) "https://api.anthropic.com" else "https://api.openai.com/v1");
    const model = cfg.getString("model.model", "");
    const api_key_env = cfg.getOptionalString("model.api_key_env") orelse
        (if (is_anthropic) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
    // g_environ is the merged overlay (process env + ~/.config/ifnh/env);
    // fall back to the raw process env.
    const api_key = blk2: {
        if (g_environ) |ge| {
            if (ge.get(api_key_env)) |k| break :blk2 k;
        }
        break :blk2 (environ.get(api_key_env) orelse "");
    };
    return .{
        .provider = if (is_anthropic) anthropic.instance else openai.instance,
        .model = model,
        .base_url = base_url,
        .api_key = api_key,
    };
}

fn engineFromConfig(arena: std.mem.Allocator, cfg: *config_mod.Store) engine_mod.Engine {
    var e = engine_mod.Engine.init(arena, if (std.mem.eql(u8, cfg.getString("permissions.default_mode", "ask"), "auto")) .auto else .ask);
    e.read_globs = cfg.getStringList("permissions.read");
    e.write_globs = cfg.getStringList("permissions.write");
    e.command_allow = cfg.getStringList("permissions.command_allow");
    e.command_deny = cfg.getStringList("permissions.command_deny");
    e.env_allow = cfg.getStringList("permissions.env_allow");
    return e;
}

fn ensureIfnh(io: std.Io, cwd: std.Io.Dir) !void {
    const dirs = [_][]const u8{ ".ifnh", ".ifnh/sessions", ".ifnh/plans" };
    for (dirs) |d| try cwd.createDirPath(io, d);
    if (!isFile(cwd, io, ".ifnh/.gitignore")) {
        try cwd.writeFile(io, .{ .sub_path = ".ifnh/.gitignore", .data = "sessions/\ncache/\ndebug/\nreports/\n" });
    }
}

fn isFile(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const st = cwd.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

// ---------------------------------------------------------------- slash commands

const CommandAction = union(enum) { none, quit, submit: []const u8 };

fn handleCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    sess: *Session,
    cfg: *config_mod.Store,
    cmd: []const u8,
    rest: []const u8,
    instr: instructions_mod.Assembled,
) CommandAction {
    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
        return .quit;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
        out(io,
            \\commands:
            \\  /help                 this text
            \\  /quit                 exit ifnh
            \\  /model <name>         switch model for this session
            \\  /config               show resolved configuration
            \\  /context              show assembled system prompt sources
            \\  /undo                 undo last file-mutation group
            \\  /redo                 redo
            \\  /diff                 show git diff of the working tree
            \\  /plan <title>         create a plan artifact in .ifnh/plans/
            \\  /agents               list subagent reports
            \\  /mcp                  list MCP servers/tools
            \\  /exec                 list background executions
            \\  /review override <r>  override last blocked review (audited)
            \\  /reconcile <path>     spawn reconciliation agent for a path
            \\  /usage                session token usage
            \\  /compact              compact the conversation context
            \\  /sessions             list sessions (use `ifnh resume <id>`)
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "model")) {
        if (rest.len > 0) {
            if (!validModelId(rest)) {
                out(io, "{s}'{s}' does not look like a model id (api keys are not model ids){s}\n", .{ palette.warn("", arena), rest, "\x1b[0m" }) catch {};
                return .none;
            }
            const json = std.fmt.allocPrint(arena, "\"{s}\"", .{rest}) catch return .none;
            cfg.applyOverride("model.model", json, .{ .layer = .session, .origin = "session" }) catch {
                out(io, "invalid model value\n", .{}) catch {};
                return .none;
            };
            sess.overrides.append(arena, .{ .path = "model.model", .json = json }) catch {};
            out(io, "model set to {s} for this session\n", .{rest}) catch {};
        } else {
            out(io, "usage: /model <name>\n", .{}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "config")) {
        out(io, "model: {s} / {s}\n", .{ cfg.getString("model.provider", ""), cfg.getString("model.model", "") }) catch {};
        out(io, "permissions.default_mode: {s}\n", .{cfg.getString("permissions.default_mode", "")}) catch {};
        out(io, "agents.max_depth: {d}\n", .{cfg.getU32("agents.max_depth", 1)}) catch {};
    } else if (std.mem.eql(u8, cmd, "context")) {
        out(io, "assembled context ({d} sources):\n", .{instr.sources.len}) catch {};
        for (instr.sources) |s| out(io, "  [{s}] {s}\n", .{ s.layer, s.path }) catch {};
    } else if (std.mem.eql(u8, cmd, "undo")) {
        if (sess.journal.undo() catch null) |gid| {
            out(io, "undone group {d}\n", .{gid}) catch {};
        } else out(io, "nothing to undo\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "redo")) {
        if (sess.journal.redo() catch null) |gid| {
            out(io, "redone group {d}\n", .{gid}) catch {};
        } else out(io, "nothing to redo\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "diff")) {
        const diff_result = std.process.run(arena, io, .{
            .argv = &.{ "git", "diff" },
            .stdout_limit = .limited(max_output_bytes),
        }) catch {
            out(io, "git diff failed (is this a git repository?)\n", .{}) catch {};
            return .none;
        };
        if (diff_result.stdout.len == 0) out(io, "(no unstaged changes)\n", .{}) catch {};
        out(io, "{s}", .{diff_result.stdout}) catch {};
    } else if (std.mem.eql(u8, cmd, "plan")) {
        createPlan(io, cwd, arena, rest) catch |err| {
            out(io, "plan creation failed: {s}\n", .{@errorName(err)}) catch {};
        };
    } else if (std.mem.eql(u8, cmd, "lifecycle")) {
        if (!std.mem.startsWith(u8, rest, "run ")) {
            out(io, "usage: /lifecycle run <file.json>\n", .{}) catch {};
            return .none;
        }
        var file_part = std.mem.trim(u8, rest[4..], " \t");
        var start_stage: usize = 0;
        if (std.mem.indexOf(u8, file_part, "--from ")) |pos| {
            const stage_name = std.mem.trim(u8, file_part[pos + 7 ..], " \t");
            file_part = std.mem.trim(u8, file_part[0..pos], " \t");
            start_stage = std.fmt.parseInt(usize, stage_name, 10) catch 0;
        }
        const text = fsutil.readSmallFile(cwd, io, arena, file_part, 256 * 1024) catch {
            out(io, "cannot read {s}\n", .{file_part}) catch {};
            return .none;
        };
        const lc = lifecycle_mod.parse(arena, text) catch {
            out(io, "invalid lifecycle file {s}\n", .{file_part}) catch {};
            return .none;
        };
        out(io, "running lifecycle '{s}' ({d} stages, from {d})\n", .{ lc.name, lc.stages.len, start_stage }) catch {};

        // Build a host for lifecycle children (reuses the turn host pieces).
        var cancel2 = std.atomic.Value(bool).init(false);
        var approver2 = Approver{ .io = io, .engine = &sess.engine };
        var host2 = subagent_mod.Host{
            .io = io,
            .workspace = cwd,
            .base_system = instr.text,
            .provider = buildProviderConfig(cfg, environ).provider,
            .base_url = buildProviderConfig(cfg, environ).base_url,
            .api_key = buildProviderConfig(cfg, environ).api_key,
            .default_model = buildProviderConfig(cfg, environ).model,
            .mode = sess.engine.mode,
            .read_globs = sess.engine.read_globs,
            .write_globs = sess.engine.write_globs,
            .command_allow = sess.engine.command_allow,
            .command_deny = sess.engine.command_deny,
            .env_allow = sess.engine.env_allow,
            .journal = &sess.journal,
            .approval_ctx = &approver2,
            .approval_fn = Approver.approve,
            .max_depth = cfg.getU32("agents.max_depth", 1),
            .max_concurrent = cfg.getU32("agents.max_concurrent", 4),
            .max_rounds = 25,
            .redactions = &.{},
            .cancel = &cancel2,
            .git = blk: {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = cwd.realPath(io, &path_buf) catch break :blk null;
                const repo_path = arena.dupe(u8, path_buf[0..n]) catch break :blk null;
                const g = git_mod.Git.init(io, repo_path);
                if (!g.isRepo(arena)) break :blk null;
                break :blk g;
            },
            .worktree_root = blk: {
                const home = environ.get("HOME") orelse break :blk null;
                const root2 = std.fmt.allocPrint(arena, "{s}/.local/state/ifnh/worktrees", .{home}) catch break :blk null;
                cwd.createDirPath(io, root2) catch {};
                break :blk root2;
            },
            .session_hint = sess.store.manifest.id,
        };
        const outcomes = lifecycle_mod.run(arena, io, &host2, lc, start_stage, .{
            .ctx = io.userdata.?,
            .on_stage_start = struct {
                fn f(_: *anyopaque, stage: []const u8, role: []const u8) void {
                    _ = stage;
                    _ = role;
                }
            }.f,
            .on_stage_done = struct {
                fn f(_: *anyopaque, o: lifecycle_mod.StageOutcome) void {
                    _ = o;
                }
            }.f,
            .approve = struct {
                fn f(_: *anyopaque, stage: []const u8, summary: []const u8) bool {
                    _ = stage;
                    _ = summary;
                    return true; // approval surfaces via child reports in M1
                }
            }.f,
        }) catch |err| {
            out(io, "lifecycle failed: {s}\n", .{@errorName(err)}) catch {};
            return .none;
        };
        for (outcomes) |o| {
            out(io, "  [{s}] {s}{s}\n", .{
                @tagName(o.status),
                o.stage,
                if (o.blockers > 0) " (blockers)" else "",
            }) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "exec")) {
        if (sess.executions) |reg| {
            _ = reg.reap();
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (&reg.slots) |*s| {
                if (!s.used) continue;
                buf.print(arena, "  exec {d}: {s} [{s}]\n", .{ s.id, s.command[0..s.command_len], @tagName(u8ToStateLocal(s.state.load(.acquire))) }) catch {};
            }
            if (buf.items.len == 0) out(io, "no background executions\n", .{}) catch {} else out(io, "{s}", .{buf.items}) catch {};
        } else out(io, "background executions unavailable\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "provider")) {
        const pcfg_now = buildProviderConfig(cfg, g_environ.?);
        if (rest.len == 0 or std.mem.eql(u8, rest, "show")) {
            const key_state = if (pcfg_now.api_key.len > 0)
                palette.success("found", arena)
            else
                palette.warn("MISSING", arena);
            out(io, "provider: {s}\nmodel: {s}\nbase_url: {s}\nkey env: {s} ({s})\n", .{
                cfg.getString("model.provider", "openai"),
                pcfg_now.model,
                pcfg_now.base_url,
                cfg.getOptionalString("model.api_key_env") orelse "(default)",
                key_state,
            }) catch {};
            if (rest.len == 0) out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n       /provider key <ENV_NAME> <value>\n", .{}) catch {};
        } else if (std.mem.startsWith(u8, rest, "set ")) {
            var toks = std.mem.tokenizeAny(u8, rest[4..], " ");
            const prov = toks.next() orelse {
                out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n", .{}) catch {};
                return .none;
            };
            const model_name = toks.next() orelse {
                out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n", .{}) catch {};
                return .none;
            };
            if (!validModelId(model_name)) {
                out(io, "{s}'{s}' does not look like a model id (api keys are not model ids){s}\n", .{ palette.warn("", arena), model_name, "\x1b[0m" }) catch {};
                return .none;
            }
            const base = toks.next();
            const key_env = toks.next();
            if (persistProjectConfig(io, arena, cfg, prov, model_name, base, key_env)) |msg| {
                out(io, "{s}\n", .{msg}) catch {};
            } else |err| {
                out(io, "failed to write .ifnh/config.json: {s}\n", .{@errorName(err)}) catch {};
            }
        } else if (std.mem.startsWith(u8, rest, "key ")) {
            var toks = std.mem.tokenizeAny(u8, rest[4..], " ");
            const name = toks.next() orelse {
                out(io, "usage: /provider key <ENV_NAME> [value]  (value prompted hidden if omitted)\n", .{}) catch {};
                return .none;
            };
            var value = toks.next();
            if (value != null and std.mem.indexOfScalar(u8, value.?, ' ') != null) {
                out(io, "key values must not contain spaces\n", .{}) catch {};
                return .none;
            }
            if (value == null) {
                // Secure entry: no echo, nothing in scrollback or args.
                out(io, "value for {s} (input hidden): ", .{name}) catch {};
                value = secret_mod.readSecret(io, arena) catch null;
                if (value == null or value.?.len == 0) {
                    out(io, "no key entered\n", .{}) catch {};
                    return .none;
                }
            }
            global_user_keys.store(io, arena, environ, name, value.?) catch |err| {
                out(io, "failed to store key: {s}\n", .{@errorName(err)}) catch {};
                return .none;
            };
            // Visible for the rest of this session immediately.
            g_merged_env.?.put(name, value.?) catch {};
            out(io, "{s}stored {s} in ~/.config/ifnh/env (0600); takes effect immediately{s}\n", .{
                palette.success("", arena), name, "\x1b[0m",
            }) catch {};
        } else {
            out(io, "usage: /provider [show|set <provider> <model> [base_url] [key_env]|key <ENV_NAME> <value>]\n", .{}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "review")) {
        // M2-T03 (G96/97): developer-only override of the last blocked review.
        if (!std.mem.startsWith(u8, rest, "override ")) {
            out(io, "usage: /review override <reason>\n", .{}) catch {};
            return .none;
        }
        const reason = std.mem.trim(u8, rest[9..], " \t");
        if (reason.len == 0) {
            out(io, "a reason is required for audit purposes\n", .{}) catch {};
            return .none;
        }
        const stage = sess.last_blocked_stage orelse {
            out(io, "no blocked review in this session to override\n", .{}) catch {};
            return .none;
        };
        cwd.createDirPath(io, ".ifnh/reports") catch {};
        const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
        const audit_path = std.fmt.allocPrint(arena, ".ifnh/reports/override-{d}.md", .{ts_ms}) catch return .none;
        const audit = std.fmt.allocPrint(arena,
            \\# Review Override
            \\
            \\- stage: {s}
            \\- ts_ms: {d}
            \\- decided_by: developer (only a human may override a review)
            \\- reason: {s}
            \\
            \\The blocked review for this stage was explicitly overridden by the
            \\developer. This record is the durable audit trail (G97).
            \\
        , .{ stage, ts_ms, reason }) catch return .none;
        fsutil.atomicWriteFile(cwd, io, arena, audit_path, audit) catch {};
        sess.last_blocked_stage = null;
        out(io, "review for '{s}' overridden; audit: {s}\n", .{ stage, audit_path }) catch {};
        out(io, "resume with /lifecycle run <file> --from <n>\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "reconcile")) {
        // M2-T04 (D045/046): reconciliation agent for conflicting edits.
        const rpath = std.mem.trim(u8, rest, " \t");
        if (rpath.len == 0) {
            out(io, "usage: /reconcile <path>\n", .{}) catch {};
            return .none;
        }
        const versions = sess.journal.versionsForPath(arena, rpath) catch &.{};
        if (versions.len < 2) {
            out(io, "no conflicting versions of '{s}' in the journal\n", .{rpath}) catch {};
            return .none;
        }
        out(io, "reconciling '{s}': {d} competing versions found\n", .{ rpath, versions.len }) catch {};
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        payload.print(arena,
            \\Reconcile conflicting implementations of '{s}'. Below are the
            \\competing versions recorded in the undo journal. Produce a combined
            \\solution that preserves the intent of both, then verify it compiles
            \\and tests pass. The result goes through normal review and approval.
            \\
            \\
        , .{rpath}) catch return .none;
        for (versions, 0..) |v, i| {
            payload.print(arena, "\n## Version {d}\n```\n{s}\n```\n", .{ i + 1, v }) catch {};
        }
        return .{ .submit = payload.items };
    } else if (std.mem.eql(u8, cmd, "usage")) {
        var total_in: u64 = 0;
        var total_out: u64 = 0;
        var turns: usize = 0;
        const raw = fsutil.readSmallFile(sess.store.dir, io, arena, "usage.jsonl", 1024 * 1024) catch "";
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
            if (v != .object) continue;
            if (v.object.get("input_tokens")) |ti| {
                if (ti == .integer) total_in += @intCast(ti.integer);
            }
            if (v.object.get("output_tokens")) |to| {
                if (to == .integer) total_out += @intCast(to.integer);
            }
            turns += 1;
        }
        out(io, "session usage: {d} turns, {d} tokens in, {d} tokens out\n", .{ turns, total_in, total_out }) catch {};
    } else if (std.mem.eql(u8, cmd, "compact")) {
        const pcfg2 = buildProviderConfig(cfg, environ);
        out(io, "[compacting context...]\n", .{}) catch {};
        const res_opt: ?compaction_mod.Result = blk: {
            break :blk compaction_mod.compact(arena, io, pcfg2, &sess.history, &.{}) catch |err| {
                out(io, "compaction failed: {s}\n", .{@errorName(err)}) catch {};
                break :blk null;
            };
        };
        if (res_opt) |res| {
            sess.history.clearRetainingCapacity();
            sess.history.appendSlice(arena, res.history) catch {};
            _ = sess.store.append(.{ .note = .{ .text = "manual compaction" } }) catch {};
            out(io, "[compacted: {d} -> {d} tokens]\n", .{ res.tokens_before, res.tokens_after }) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "skills")) {
        if (sess.skills) |catalog| {
            if (catalog.skills.len == 0) {
                out(io, "no skills installed (.ifnh/skills/, ~/.config/ifnh/skills/)\n", .{}) catch {};
            }
            for (catalog.skills) |s| {
                out(io, "  [{s}] {s}: {s}\n", .{ s.scope, s.name, s.description }) catch {};
            }
        } else out(io, "skills unavailable\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        if (sess.mcp_registry) |reg| {
            if (reg.configs.len == 0) {
                out(io, "no MCP servers configured (mcp_servers in config)\n", .{}) catch {};
            }
            for (reg.configs) |c| {
                out(io, "  {s}: {s}\n", .{ c.name, c.command }) catch {};
            }
            out(io, "{s}", .{mcpListHook(@ptrCast(reg), arena)}) catch {};
        } else out(io, "MCP not available\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "agents")) {
        _ = &sess;
        out(io, "subagents run inline during turns; reports:\n", .{}) catch {};
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (cwd.openDir(io, ".ifnh/reports", .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                names.append(arena, arena.dupe(u8, entry.name) catch continue) catch {};
            }
        } else |_| {}
        if (names.items.len == 0) {
            out(io, "no agent reports\n", .{}) catch {};
        } else {
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (names.items) |n| out(io, "  .ifnh/reports/{s}\n", .{n}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "sessions")) {
        const summaries = session_mod.list(cwd, io, arena, ".ifnh/sessions") catch &.{};
        if (summaries.len == 0) {
            out(io, "no sessions\n", .{}) catch {};
        }
        for (summaries) |s| {
            out(io, "  {s}  {d}  {s}\n", .{ s.id, s.created_ms, s.cwd }) catch {};
        }
    } else if (loadDiskCommand(io, arena, cwd, cmd, rest)) |prompt| {
        return .{ .submit = prompt };
    } else {
        out(io, "unknown command /{s} (try /help)\n", .{cmd}) catch {};
    }
    return .none;
}

/// Disk-backed slash command (D030, M0-T37): `.ifnh/commands/<name>.md`
/// with optional frontmatter; `$ARGS` in the body is replaced by the
/// command arguments. The body is submitted as the user's prompt.
fn loadDiskCommand(io: std.Io, arena: std.mem.Allocator, cwd: std.Io.Dir, cmd: []const u8, args: []const u8) ?[]const u8 {
    var name_buf: [128]u8 = undefined;
    if (cmd.len == 0 or cmd.len > 64) return null;
    for (cmd) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    const rel = std.fmt.bufPrint(&name_buf, ".ifnh/commands/{s}.md", .{cmd}) catch return null;
    const raw = fsutil.readSmallFile(cwd, io, arena, rel, 64 * 1024) catch return null;

    // Strip YAML-ish frontmatter (--- ... ---) if present.
    var body = raw;
    if (std.mem.startsWith(u8, body, "---")) {
        if (std.mem.indexOfPos(u8, body, 3, "\n---")) |end| {
            const after = body[end + 4 ..];
            body = if (after.len > 0 and after[0] == '\n') after[1..] else after;
        }
    }
    if (std.mem.indexOf(u8, body, "$ARGS")) |pos| {
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ body[0..pos], args, body[pos + "$ARGS".len ..] }) catch null;
    }
    if (args.len > 0) {
        return std.fmt.allocPrint(arena, "{s}\n\nArguments: {s}", .{ body, args }) catch null;
    }
    return body;
}

fn createPlan(io: std.Io, cwd: std.Io.Dir, arena: std.mem.Allocator, title: []const u8) !void {
    try cwd.createDirPath(io, ".ifnh/plans");
    const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const id = std.fmt.allocPrint(arena, "plan-{d}", .{ts_ms}) catch return error.OutOfMemory;
    const path = std.fmt.allocPrint(arena, ".ifnh/plans/{s}.md", .{id}) catch return error.OutOfMemory;
    const content = std.fmt.allocPrint(arena,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: draft
        \\created_ms: {d}
        \\---
        \\
        \\# Plan: {s}
        \\
        \\## Goal
        \\
        \\## Approach
        \\
        \\## Steps
        \\
        \\1.
        \\
        \\## Verification
        \\
        \\
    , .{ id, if (title.len > 0) title else "untitled", ts_ms, if (title.len > 0) title else "untitled" }) catch return error.OutOfMemory;
    try cwd.writeFile(io, .{ .sub_path = path, .data = content });
    out(io, "created {s}\n", .{path}) catch {};
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try std.Io.File.stdout().writeStreamingAll(io, text);
}
