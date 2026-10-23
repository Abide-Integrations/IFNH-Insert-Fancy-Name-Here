//! `ifnh ask` / `ifnh -p`: one headless turn against the configured
//! provider and tools, with optional NDJSON event output (C-02).
//!
//! No terminal UI, no ANSI styling, no second turn loop: the runtime in
//! `core/agent/session_runtime.zig` executes the turn and this module only
//! renders its callbacks and maps the result to an exit code.

const std = @import("std");
const cli_args = @import("args.zig");
const fsutil = @import("../core/fsutil.zig");
const config_mod = @import("../core/config/config.zig");
const keys_mod = @import("../core/config/keys.zig");
const session_mod = @import("../core/session/store.zig");
const journal_mod = @import("../core/journal.zig");
const engine_mod = @import("../core/permissions/engine.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const agent_engine = @import("../core/agent/engine.zig");
const session_runtime = @import("../core/agent/session_runtime.zig");
const mcp_mod = @import("../core/mcp.zig");
const skills_mod = @import("../core/skills.zig");
const executions_mod = @import("../core/executions.zig");
const openai = @import("../providers/openai.zig");
const anthropic = @import("../providers/anthropic.zig");
const tool_mod = @import("../tools/tool.zig");
const core_types = @import("../core/types.zig");

/// Exit codes for headless runs (documented in docs/USAGE.md).
pub const exit_ok: u8 = 0;
pub const exit_turn_failed: u8 = 1;
pub const exit_usage: u8 = 2;
pub const exit_provider: u8 = 3;
pub const exit_denied: u8 = 4;

pub fn exitCode(result: session_runtime.TurnResult) u8 {
    if (result.denied_tools > 0) return exit_denied;
    return switch (result.status) {
        .completed => exit_ok,
        .failed => if (result.hook_blocked) exit_turn_failed else exit_provider,
        .cancelled => exit_turn_failed,
    };
}

// ---------------------------------------------------------------- NDJSON

pub const JsonEmitter = struct {
    writer: *std.Io.Writer,

    fn raw(self: *JsonEmitter, bytes: []const u8) void {
        self.writer.writeAll(bytes) catch {};
    }

    pub fn text(self: *JsonEmitter, delta: []const u8) void {
        self.raw("{\"type\":\"text\",\"delta\":");
        std.json.Stringify.value(delta, .{}, self.writer) catch {};
        self.raw("}\n");
    }

    pub fn toolCall(self: *JsonEmitter, name: []const u8, arguments_json: []const u8) void {
        self.raw("{\"type\":\"tool_call\",\"name\":");
        std.json.Stringify.value(name, .{}, self.writer) catch {};
        self.raw(",\"arguments\":");
        std.json.Stringify.value(arguments_json, .{}, self.writer) catch {};
        self.raw("}\n");
    }

    pub fn toolResult(self: *JsonEmitter, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        self.raw("{\"type\":\"tool_result\",\"name\":");
        std.json.Stringify.value(name, .{}, self.writer) catch {};
        self.raw(",\"status\":");
        std.json.Stringify.value(@tagName(status), .{}, self.writer) catch {};
        self.raw(",\"output\":");
        std.json.Stringify.value(output, .{}, self.writer) catch {};
        self.raw("}\n");
    }

    pub fn notice(self: *JsonEmitter, text_value: []const u8) void {
        self.raw("{\"type\":\"notice\",\"text\":");
        std.json.Stringify.value(text_value, .{}, self.writer) catch {};
        self.raw("}\n");
    }

    pub fn usage(self: *JsonEmitter, input_tokens: u64, output_tokens: u64, tool_calls: usize) void {
        self.raw("{\"type\":\"usage\",\"input_tokens\":");
        self.writer.print("{d}", .{input_tokens}) catch {};
        self.raw(",\"output_tokens\":");
        self.writer.print("{d}", .{output_tokens}) catch {};
        self.raw(",\"tool_calls\":");
        self.writer.print("{d}", .{tool_calls}) catch {};
        self.raw("}\n");
    }

    pub fn done(self: *JsonEmitter, result: session_runtime.TurnResult) void {
        self.raw("{\"type\":\"done\",\"ok\":");
        self.raw(if (result.status == .completed and result.denied_tools == 0) "true" else "false");
        self.raw(",\"status\":");
        std.json.Stringify.value(@tagName(result.status), .{}, self.writer) catch {};
        self.raw(",\"text\":");
        std.json.Stringify.value(result.reply, .{}, self.writer) catch {};
        self.raw(",\"error\":");
        std.json.Stringify.value(result.error_message, .{}, self.writer) catch {};
        self.raw("}\n");
    }

    fn onText(ctx: *anyopaque, delta: []const u8) void {
        const self: *JsonEmitter = @ptrCast(@alignCast(ctx));
        self.text(delta);
    }
    fn onToolStart(ctx: *anyopaque, name: []const u8, args_json: []const u8) void {
        const self: *JsonEmitter = @ptrCast(@alignCast(ctx));
        self.toolCall(name, args_json);
    }
    fn onToolResult(ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        const self: *JsonEmitter = @ptrCast(@alignCast(ctx));
        self.toolResult(name, status, output);
    }
    fn onNotice(ctx: *anyopaque, text_value: []const u8) void {
        const self: *JsonEmitter = @ptrCast(@alignCast(ctx));
        self.notice(text_value);
    }

    pub fn callbacks(self: *JsonEmitter) agent_engine.Callbacks {
        return .{
            .ctx = self,
            .on_text = onText,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
        };
    }
};

const TextEmitter = struct {
    writer: *std.Io.Writer,

    fn onText(ctx: *anyopaque, delta: []const u8) void {
        const self: *TextEmitter = @ptrCast(@alignCast(ctx));
        self.writer.writeAll(delta) catch {};
    }
    fn onToolStart(ctx: *anyopaque, name: []const u8, args_json: []const u8) void {
        const self: *TextEmitter = @ptrCast(@alignCast(ctx));
        self.writer.print("[tool] {s} {s}\n", .{ name, args_json }) catch {};
    }
    fn onToolResult(ctx: *anyopaque, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        const self: *TextEmitter = @ptrCast(@alignCast(ctx));
        self.writer.print("[{s}] {s}: {s}\n", .{ @tagName(status), name, output }) catch {};
    }
    fn onNotice(ctx: *anyopaque, text_value: []const u8) void {
        const self: *TextEmitter = @ptrCast(@alignCast(ctx));
        self.writer.print("! {s}\n", .{text_value}) catch {};
    }

    fn callbacks(self: *TextEmitter) agent_engine.Callbacks {
        return .{
            .ctx = self,
            .on_text = onText,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
        };
    }
};

// ---------------------------------------------------------------- approvals

const PolicyApprover = struct {
    mode: cli_args.ApprovalMode,

    fn approve(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *PolicyApprover = @ptrCast(@alignCast(ctx));
        _ = req;
        return switch (self.mode) {
            .yes => .approved_once,
            .deny_all => .denied,
        };
    }
};

// ---------------------------------------------------------------- policy file

fn stringList(arena: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const v = value orelse return null;
    if (v != .array) return error.InvalidPolicy;
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item != .string) return error.InvalidPolicy;
        try list.append(arena, item.string);
    }
    return list.items;
}

/// Load the same shape as the config `permissions` block for this run only.
pub fn applyPolicy(arena: std.mem.Allocator, engine: *engine_mod.Engine, text: []const u8) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.InvalidPolicy;
    if (root != .object) return error.InvalidPolicy;
    const obj = if (root.object.get("permissions")) |p|
        (if (p == .object) p.object else return error.InvalidPolicy)
    else
        root.object;

    if (obj.get("default_mode")) |v| {
        if (v != .string) return error.InvalidPolicy;
        engine.mode = if (std.mem.eql(u8, v.string, "auto")) .auto else if (std.mem.eql(u8, v.string, "ask")) .ask else return error.InvalidPolicy;
    }
    if (try stringList(arena, obj.get("read"))) |v| engine.read_globs = v;
    if (try stringList(arena, obj.get("write"))) |v| engine.write_globs = v;
    if (try stringList(arena, obj.get("command_allow"))) |v| engine.command_allow = v;
    if (try stringList(arena, obj.get("command_deny"))) |v| engine.command_deny = v;
    if (try stringList(arena, obj.get("env_allow"))) |v| engine.env_allow = v;
    if (try stringList(arena, obj.get("mcp_allow"))) |v| engine.mcp_allow = v;
    if (try stringList(arena, obj.get("mcp_deny"))) |v| engine.mcp_deny = v;
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

fn buildProviderConfig(cfg: *config_mod.Store, environ: *const std.process.Environ.Map, stored: *keys_mod.Keys) agent_engine.ProviderConfig {
    const provider_name = cfg.getString("model.provider", "openai");
    const is_anthropic = std.mem.eql(u8, provider_name, "anthropic");
    const base_url = cfg.getOptionalString("model.base_url") orelse
        (if (is_anthropic) "https://api.anthropic.com" else "https://api.openai.com/v1");
    const api_key_env = cfg.getOptionalString("model.api_key_env") orelse
        (if (is_anthropic) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
    const api_key = environ.get(api_key_env) orelse (stored.map.get(api_key_env) orelse "");
    return .{
        .provider = if (is_anthropic) anthropic.instance else openai.instance,
        .model = cfg.getString("model.model", ""),
        .base_url = base_url,
        .api_key = api_key,
    };
}

fn readPrompt(io: std.Io, arena: std.mem.Allocator, given: ?[]const u8) !?[]const u8 {
    if (given) |p| return std.mem.trim(u8, p, " \t\r\n");
    if (std.Io.File.stdin().isTty(io) catch false) return null;
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const text = reader.interface.allocRemaining(arena, .limited(1024 * 1024)) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn errOut(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

// ---------------------------------------------------------------- run

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    opts: cli_args.AskOptions,
) !u8 {
    const prompt = try readPrompt(io, arena, opts.prompt) orelse {
        errOut(io, "usage: ifnh ask [--json] [--yes|--deny-all] [--policy <path>] \"<prompt>\"\n", .{});
        return exit_usage;
    };
    if (prompt.len == 0) {
        errOut(io, "error: empty prompt\n", .{});
        return exit_usage;
    }

    const cwd = std.Io.Dir.cwd();
    var cfg = config_mod.load(arena, io, environ, cwd) catch |err| {
        errOut(io, "error: config load failed: {s}\n", .{@errorName(err)});
        return exit_turn_failed;
    };
    defer cfg.deinit();
    if (cfg.errors.items.len > 0) {
        for (cfg.errors.items) |e| errOut(io, "config error [{s}]: {s}\n", .{ e.path, e.message });
        return exit_turn_failed;
    }

    var stored = keys_mod.Keys.init(arena);
    stored.load(io, arena, environ);
    const pcfg = buildProviderConfig(&cfg, environ, &stored);

    var eng = engineFromConfig(arena, &cfg);
    if (opts.policy_path) |path| {
        const text = fsutil.readSmallFile(cwd, io, arena, path, 1024 * 1024) catch |err| {
            errOut(io, "error: cannot read policy {s}: {s}\n", .{ path, @errorName(err) });
            return exit_usage;
        };
        applyPolicy(arena, &eng, text) catch |err| {
            errOut(io, "error: invalid policy {s}: {s}\n", .{ path, @errorName(err) });
            return exit_usage;
        };
    }

    cwd.createDirPath(io, ".ifnh/sessions") catch |err| {
        errOut(io, "error: cannot create .ifnh/sessions: {s}\n", .{@errorName(err)});
        return exit_turn_failed;
    };
    const cwd_text: []const u8 = if (environ.get("PWD")) |p| p else ".";
    var store = session_mod.Session.create(cwd, io, arena, ".ifnh/sessions", cwd_text) catch |err| {
        errOut(io, "error: cannot start session: {s}\n", .{@errorName(err)});
        return exit_turn_failed;
    };
    defer store.close();
    var journal = journal_mod.Journal.open(io, arena, store.dir) catch |err| {
        errOut(io, "error: cannot open journal: {s}\n", .{@errorName(err)});
        return exit_turn_failed;
    };
    defer journal.close();

    const skills: ?skills_mod.Catalog = blk: {
        const user_dir = std.fmt.allocPrint(arena, "{s}/.config/ifnh/skills", .{environ.get("HOME") orelse ""}) catch break :blk null;
        break :blk skills_mod.discover(cwd, io, arena, user_dir) catch null;
    };
    var executions = executions_mod.Registry.init(io, arena, cwd);
    defer executions.deinit();
    var mcp_registry = mcp_mod.Registry.init(io, arena, cfg.get("mcp_servers")) catch null;
    defer if (mcp_registry) |*r| r.deinit();

    const instr = instructions_mod.assemble(cwd, io, arena, system_prompt.system_prompt, &.{}) catch {
        errOut(io, "error: cannot assemble instructions\n", .{});
        return exit_turn_failed;
    };

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(false);
    var approver = PolicyApprover{ .mode = opts.approval };

    var out_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &err_buf);
    var json_emitter = JsonEmitter{ .writer = &stdout_writer.interface };
    var text_emitter = TextEmitter{ .writer = &stdout_writer.interface };

    var runtime = session_runtime.Runtime{
        .io = io,
        .arena = arena,
        .cwd = cwd,
        .cfg = &cfg,
        .pcfg = pcfg,
        .system = instr.text,
        .history = &history,
        .engine = &eng,
        .journal = &journal,
        .store = &store,
        .mcp_registry = if (mcp_registry) |*r| r else null,
        .skills = skills,
        .executions = &executions,
        .session_id = store.manifest.id,
        .environ = environ,
        .callbacks = if (opts.json) json_emitter.callbacks() else text_emitter.callbacks(),
        .approval = .{ .ctx = &approver, .approve_fn = PolicyApprover.approve },
        .cancel = &cancel,
        .notice = if (opts.json) .{ .ctx = &json_emitter, .notify_fn = struct {
            fn f(ctx: *anyopaque, text: []const u8) void {
                const e: *JsonEmitter = @ptrCast(@alignCast(ctx));
                e.notice(text);
            }
        }.f } else .{ .ctx = &text_emitter, .notify_fn = struct {
            fn f(ctx: *anyopaque, text: []const u8) void {
                const e: *TextEmitter = @ptrCast(@alignCast(ctx));
                e.writer.print("! {s}\n", .{text}) catch {};
            }
        }.f },
    };

    const result = runtime.submit(prompt);
    if (opts.json) {
        json_emitter.usage(result.usage.input_tokens, result.usage.output_tokens, result.tool_calls);
        json_emitter.done(result);
    } else {
        if (result.status != .completed or result.reply.len > 0) stdout_writer.interface.writeAll("\n") catch {};
        if (result.status == .failed or result.denied_tools > 0) {
            stderr_writer.interface.print("ifnh ask: {s}\n", .{if (result.error_message.len > 0) result.error_message else "turn failed"}) catch {};
        }
    }
    stdout_writer.interface.flush() catch {};
    stderr_writer.interface.flush() catch {};

    return exitCode(result);
}

// ---------------------------------------------------------------- tests

const agent_testing = @import("../core/agent/testing.zig");

fn noopText(_: *anyopaque, _: []const u8) void {}
fn noopStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopResult(_: *anyopaque, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
fn noopNotice(_: *anyopaque, _: []const u8) void {}

fn approveYes(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
    return .approved_once;
}
fn approveNo(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
    return .denied;
}

test "ask: scripted fake provider emits NDJSON events and exit code" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\n" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = agent_testing.Fake{ .script = &.{
        &.{
            .{ .text = "Looking at the file." },
            .{ .tool_call = .{ .id = "c1", .name = "read", .arguments_json = "{\"path\":\"f.txt\"}" } },
            .{ .usage = .{ .input_tokens = 10, .output_tokens = 5 } },
        },
        &.{
            .{ .text = "The file has two lines." },
            .{ .usage = .{ .input_tokens = 20, .output_tokens = 9 } },
        },
    } };

    var cfg = try config_mod.Store.init(arena);
    defer cfg.deinit();
    var eng = engine_mod.Engine.init(arena, .auto);

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(false);
    var aw: std.Io.Writer.Allocating = .init(arena);
    var emitter = JsonEmitter{ .writer = &aw.writer };
    var approver = PolicyApprover{ .mode = .deny_all };

    var runtime = session_runtime.Runtime{
        .io = io,
        .arena = arena,
        .cwd = tmp.dir,
        .cfg = &cfg,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "fake-key-1234567890" },
        .system = "system",
        .history = &history,
        .engine = &eng,
        .callbacks = emitter.callbacks(),
        .approval = .{ .ctx = &approver, .approve_fn = PolicyApprover.approve },
        .cancel = &cancel,
    };
    const result = runtime.submit("what is in f.txt?");
    emitter.usage(result.usage.input_tokens, result.usage.output_tokens, result.tool_calls);
    emitter.done(result);

    try std.testing.expectEqual(agent_engine.Status.completed, result.status);
    try std.testing.expectEqual(exit_ok, exitCode(result));
    try std.testing.expectEqualStrings("The file has two lines.", result.reply);

    // Exactly one JSON object per line; `done` carries success and final text.
    var types: std.ArrayListUnmanaged([]const u8) = .empty;
    var done_seen = false;
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try std.testing.expect(v == .object);
        const t = v.object.get("type") orelse return error.MissingType;
        try std.testing.expect(t == .string);
        try types.append(arena, t.string);
        if (std.mem.eql(u8, t.string, "done")) {
            done_seen = true;
            try std.testing.expect(v.object.get("ok").? == .bool and v.object.get("ok").?.bool);
            try std.testing.expectEqualStrings(result.reply, v.object.get("text").?.string);
        }
    }
    try std.testing.expect(done_seen);
    try std.testing.expectEqual(@as(usize, 6), types.items.len);
    try std.testing.expectEqualStrings("text", types.items[0]); // "Looking at the file."
    try std.testing.expectEqualStrings("tool_call", types.items[1]);
    try std.testing.expectEqualStrings("tool_result", types.items[2]);
    try std.testing.expectEqualStrings("text", types.items[3]); // final reply
    try std.testing.expectEqualStrings("usage", types.items[4]);
    try std.testing.expectEqualStrings("done", types.items[5]);
}

test "ask: --deny-all denies an approval tool, --yes lets it run" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const script: agent_testing.Script = &.{
        &.{
            .{ .tool_call = .{ .id = "w1", .name = "write", .arguments_json = "{\"path\":\"out.txt\",\"content\":\"hello\"}" } },
        },
        &.{.{ .text = "done" }},
    };

    // Default non-interactive policy: deny.
    {
        var fake = agent_testing.Fake{ .script = script };
        var cfg = try config_mod.Store.init(arena);
        defer cfg.deinit();
        var eng = engine_mod.Engine.init(arena, .ask);
        var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
        var cancel = std.atomic.Value(bool).init(false);
        var approver = PolicyApprover{ .mode = .deny_all };
        var runtime = session_runtime.Runtime{
            .io = io,
            .arena = arena,
            .cwd = tmp.dir,
            .cfg = &cfg,
            .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
            .system = "",
            .history = &history,
            .engine = &eng,
            .callbacks = .{ .ctx = undefined, .on_text = noopText, .on_tool_start = noopStart, .on_tool_result = noopResult, .on_notice = noopNotice },
            .approval = .{ .ctx = &approver, .approve_fn = PolicyApprover.approve },
            .cancel = &cancel,
        };
        const denied = runtime.submit("write the file");
        try std.testing.expectEqual(@as(usize, 1), denied.denied_tools);
        try std.testing.expectEqual(exit_denied, exitCode(denied));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "out.txt", .{}));
    }

    // --yes: the same tool runs.
    {
        var fake = agent_testing.Fake{ .script = script };
        var cfg = try config_mod.Store.init(arena);
        defer cfg.deinit();
        var eng = engine_mod.Engine.init(arena, .ask);
        var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
        var cancel = std.atomic.Value(bool).init(false);
        var approver = PolicyApprover{ .mode = .yes };
        var runtime = session_runtime.Runtime{
            .io = io,
            .arena = arena,
            .cwd = tmp.dir,
            .cfg = &cfg,
            .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
            .system = "",
            .history = &history,
            .engine = &eng,
            .callbacks = .{ .ctx = undefined, .on_text = noopText, .on_tool_start = noopStart, .on_tool_result = noopResult, .on_notice = noopNotice },
            .approval = .{ .ctx = &approver, .approve_fn = PolicyApprover.approve },
            .cancel = &cancel,
        };
        const approved = runtime.submit("write the file");
        try std.testing.expectEqual(@as(usize, 0), approved.denied_tools);
        try std.testing.expectEqual(exit_ok, exitCode(approved));
        const data = try tmp.dir.readFileAlloc(io, "out.txt", arena, .limited(1024));
        try std.testing.expectEqualStrings("hello", data);
    }
}

test "ask: provider failure maps to transport exit code" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake = agent_testing.Fake{ .script = &.{
        &.{.{ .failure = .{ .kind = .network, .message = "connection refused" } }},
    } };
    var cfg = try config_mod.Store.init(arena);
    defer cfg.deinit();
    var eng = engine_mod.Engine.init(arena, .auto);
    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(false);
    var approver = PolicyApprover{ .mode = .deny_all };
    var runtime = session_runtime.Runtime{
        .io = io,
        .arena = arena,
        .cwd = std.Io.Dir.cwd(),
        .cfg = &cfg,
        .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "fake-key-1234567890" },
        .system = "",
        .history = &history,
        .engine = &eng,
        .callbacks = .{ .ctx = undefined, .on_text = noopText, .on_tool_start = noopStart, .on_tool_result = noopResult, .on_notice = noopNotice },
        .approval = .{ .ctx = &approver, .approve_fn = PolicyApprover.approve },
        .cancel = &cancel,
    };
    const result = runtime.submit("hello");
    try std.testing.expectEqual(agent_engine.Status.failed, result.status);
    try std.testing.expectEqual(exit_provider, exitCode(result));
}

test "ask: policy file overrides this-run permissions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var eng = engine_mod.Engine.init(arena, .ask);
    try applyPolicy(arena, &eng, "{\"default_mode\":\"auto\",\"write\":[\"docs/**\"],\"command_deny\":[\"rm\"]}");
    try std.testing.expectEqual(engine_mod.Mode.auto, eng.mode);
    try std.testing.expectEqual(engine_mod.Decision.allow, eng.decidePath(.write, "docs/a.md"));
    try std.testing.expectEqual(engine_mod.Decision.deny, eng.decideCommand("rm -rf build"));
}
