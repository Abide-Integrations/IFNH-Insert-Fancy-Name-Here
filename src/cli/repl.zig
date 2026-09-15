//! Interactive streaming REPL (DESIGN §6, DECISIONS section R).
//!
//! Line-oriented inline streaming UI: works on a TTY, over SSH, and with
//! piped stdin/stdout. Slash commands are built-in; disk-backed commands
//! load from `.ifnh/commands/*.md`. Approvals are interactive prompts that
//! can grant session-scoped permission patterns.

const std = @import("std");
const fsutil = @import("../core/fsutil.zig");
const config_mod = @import("../core/config/config.zig");
const session_mod = @import("../core/session/store.zig");
const journal_mod = @import("../core/journal.zig");
const engine_mod = @import("../core/permissions/engine.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const agent_engine = @import("../core/agent/engine.zig");
const subagent_mod = @import("../core/agent/subagent.zig");
const git_mod = @import("../core/git.zig");
const tool_mod = @import("../tools/tool.zig");
const core_types = @import("../core/types.zig");
const openai = @import("../providers/openai.zig");
const anthropic = @import("../providers/anthropic.zig");

const max_output_bytes: usize = 256 * 1024;

pub const Options = struct {
    resume_id: ?[]const u8 = null,
    json: bool = false,
};

const Session = struct {
    store: session_mod.Session,
    journal: journal_mod.Journal,
    engine: engine_mod.Engine,
    history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty,
    /// Session-layer overrides (path, JSON value text) re-applied after
    /// config re-reads at turn boundaries (DECISIONS B24).
    overrides: std.ArrayListUnmanaged(struct { path: []const u8, json: []const u8 }) = .empty,
};

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    opts: Options,
) !void {
    const cwd = std.Io.Dir.cwd();

    // ---- configuration ----
    var cfg = try config_mod.load(arena, io, environ, cwd);
    defer cfg.deinit();
    for (cfg.errors.items) |err| {
        try out(io, "config error [{s}]: {s}\n", .{ err.path, err.message });
    }
    if (cfg.errors.items.len > 0) return error.InvalidConfig;
    for (cfg.warnings.items) |w| try out(io, "config warning: {s}\n", .{w});

    // ---- session state (zero-config: lazily create .ifnh) ----
    ensureIfnh(io, cwd) catch {};
    const sessions_dir_name = ".ifnh/sessions";

    var sess: Session = blk: {
        if (opts.resume_id) |id| {
            const store = try session_mod.Session.open(cwd, io, arena, sessions_dir_name, id);
            const j = try journal_mod.Journal.open(io, arena, store.dir);
            var s = Session{ .store = store, .journal = j, .engine = engineFromConfig(arena, &cfg) };
            try rebuildHistory(arena, &s);
            break :blk s;
        } else {
            const cwd_copy: []const u8 = if (environ.get("PWD")) |pwd| pwd else ".";
            const store = try session_mod.Session.create(cwd, io, arena, sessions_dir_name, cwd_copy);
            const j = try journal_mod.Journal.open(io, arena, store.dir);
            break :blk Session{ .store = store, .journal = j, .engine = engineFromConfig(arena, &cfg) };
        }
    };
    defer {
        sess.store.close();
        sess.journal.close();
    }

    // ---- provider ----
    const pcfg = buildProviderConfig(&cfg, environ);
    const provider_name = cfg.getString("model.provider", "openai");

    // ---- instructions ----
    const builtin_prompt = system_prompt.system_prompt;
    const instr = try instructions_mod.assemble(cwd, io, arena, builtin_prompt, &.{});

    // ---- welcome ----
    try out(io, "ifnh session {s} (model: {s}/{s}{s})\n", .{
        sess.store.manifest.id,
        provider_name,
        if (pcfg.model.len > 0) pcfg.model else "<unset>",
        if (pcfg.api_key.len == 0) ", no api key" else "",
    });
    try out(io, "type a message, or /help for commands\n", .{});

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
            const action = handleCommand(io, arena, cwd, &sess, &cfg, cmd, rest, instr);
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

        try submitTurn(io, arena, environ, &sess, &cfg, buildProviderConfig(&cfg, environ), turn_instr.text, line, cwd);
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
        try out(io, "no model configured: set model.model in .ifnh/config.json or IFNH_MODEL__MODEL\n", .{});
        return;
    }
    if (pcfg.api_key.len == 0) {
        try out(io, "note: no api key found in environment; the provider will likely reject the request\n", .{});
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
            out(self.io, "[{s}] {s}{s}\n", .{ @tagName(status), shown, if (output.len > max_show) "..." else "" }) catch {};
        }
        fn onNotice(ctx: *anyopaque, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            out(self.io, "! {s}\n", .{text}) catch {};
        }
    };
    var ui = TurnUi{ .io = io };

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
    }
    try sess.store.syncWatermark();
}

const Approver = struct {
    io: std.Io,
    engine: *engine_mod.Engine,
    mutex: std.Io.Mutex = .init,

    fn approve(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Approver = @ptrCast(@alignCast(ctx));
        self.mutex.lock(self.io) catch return .denied;
        defer self.mutex.unlock(self.io);
        out(self.io, "\napproval needed: {s}\n  {s}\n[y] once  [s] session  [n] no: ", .{ req.title, req.detail }) catch return .denied;
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

fn redactionsFor(arena: std.mem.Allocator, api_key: []const u8) []const []const u8 {
    if (api_key.len < 8) return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    list.append(arena, api_key) catch return &.{};
    return list.items;
}

fn buildProviderConfig(cfg: *config_mod.Store, environ: *const std.process.Environ.Map) agent_engine.ProviderConfig {
    const provider_name = cfg.getString("model.provider", "openai");
    const is_anthropic = std.mem.eql(u8, provider_name, "anthropic");
    const base_url = cfg.getOptionalString("model.base_url") orelse
        (if (is_anthropic) "https://api.anthropic.com" else "https://api.openai.com/v1");
    const model = cfg.getString("model.model", "");
    const api_key_env = cfg.getOptionalString("model.api_key_env") orelse
        (if (is_anthropic) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
    const api_key = environ.get(api_key_env) orelse "";
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
            \\  /sessions             list sessions (use `ifnh resume <id>`)
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "model")) {
        if (rest.len > 0) {
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
