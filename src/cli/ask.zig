//! Headless one-shot turns: `ifnh ask "<prompt>"` (ACTIVE_PLAN C-02).
//!
//! Runs exactly one turn through `core/agent/session_runtime.zig` and exits.
//! The prompt comes from the command line or from stdin (piped), approvals
//! come from `--yes`/`--deny-all`/`--policy` (or `/dev/tty` when stdin is a
//! terminal), and `--json` turns stdout into an NDJSON event stream.
//!
//! The runtime never writes to the terminal: this module owns the sink and
//! the approval callback, and nothing here goes through the REPL.

const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("../core/config/config.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const session_runtime = @import("../core/agent/session_runtime.zig");
const tool_mod = @import("../tools/tool.zig");

/// Usage errors (bad flag, missing/empty prompt, conflicting approvals).
pub const exit_usage: u8 = 2;

/// Facts about a finished run. Several may hold at once; `runStatus` applies
/// the documented precedence.
pub const Facts = struct {
    interrupted: bool = false,
    failed: bool = false,
    denied: bool = false,
};

pub const RunStatus = enum { ok, failed, denied, interrupted };

/// Precedence when several conditions hold: interrupted > failed > denied > ok.
pub fn runStatus(facts: Facts) RunStatus {
    if (facts.interrupted) return .interrupted;
    if (facts.failed) return .failed;
    if (facts.denied) return .denied;
    return .ok;
}

/// Exit code for a finished run: 0 ok, 1 failed, 3 denied, 130 interrupted.
pub fn exitCode(status: RunStatus) u8 {
    return switch (status) {
        .ok => 0,
        .failed => 1,
        .denied => 3,
        .interrupted => 130,
    };
}

/// One NDJSON event. `writeEvent` is the single place the wire shape lives.
pub const Event = union(enum) {
    start: struct { session: []const u8, model: []const u8 },
    text: []const u8,
    tool_start: []const u8,
    tool_end: struct { name: []const u8, ok: bool },
    approval: struct { tool: []const u8, detail: []const u8, decision: tool_mod.ApprovalResponse },
    err: []const u8,
    end: RunStatus,
};

/// Append one event as a single JSON line (no pretty printing, no CR).
pub fn writeEvent(w: *std.Io.Writer, ev: Event) !void {
    switch (ev) {
        .start => |s| {
            try w.writeAll("{\"type\":\"start\",\"session\":");
            try std.json.Stringify.value(s.session, .{}, w);
            try w.writeAll(",\"model\":");
            try std.json.Stringify.value(s.model, .{}, w);
            try w.writeAll("}");
        },
        .text => |text| {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(text, .{}, w);
            try w.writeAll("}");
        },
        .tool_start => |name| {
            try w.writeAll("{\"type\":\"tool\",\"name\":");
            try std.json.Stringify.value(name, .{}, w);
            try w.writeAll(",\"phase\":\"start\"}");
        },
        .tool_end => |t| {
            try w.writeAll("{\"type\":\"tool\",\"name\":");
            try std.json.Stringify.value(t.name, .{}, w);
            try w.writeAll(if (t.ok) ",\"phase\":\"end\",\"ok\":true}" else ",\"phase\":\"end\",\"ok\":false}");
        },
        .approval => |a| {
            try w.writeAll("{\"type\":\"approval\",\"tool\":");
            try std.json.Stringify.value(a.tool, .{}, w);
            try w.writeAll(",\"detail\":");
            try std.json.Stringify.value(a.detail, .{}, w);
            try w.writeAll(",\"decision\":\"");
            try w.writeAll(@tagName(a.decision));
            try w.writeAll("\"}");
        },
        .err => |message| {
            try w.writeAll("{\"type\":\"error\",\"message\":");
            try std.json.Stringify.value(message, .{}, w);
            try w.writeAll("}");
        },
        .end => |status| {
            try w.writeAll("{\"type\":\"end\",\"status\":\"");
            try w.writeAll(@tagName(status));
            try w.writeAll("\"}");
        },
    }
    try w.writeByte('\n');
}

/// Flatten a multi-line approval detail (command lines, paths) into one line
/// and drop control bytes, so the NDJSON line stays single-line and ANSI-free.
pub fn oneLine(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const out = arena.alloc(u8, text.len) catch return text;
    for (text, 0..) |c, i| out[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
    return out;
}

/// Where a turn's events go. In `--json` mode stdout carries NDJSON and
/// nothing else; in plain mode it carries only the assistant text.
const Sink = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    json: bool,
    policy: args_mod.ApprovalPolicy,
    /// True once any tool call was denied (engine policy or approval).
    denied: bool = false,

    fn events(self: *Sink) session_runtime.Events {
        return .{
            .ctx = @ptrCast(self),
            .on_text = onText,
            .on_status = onStatus,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
            .on_assistant_message = onAssistantMessage,
            .on_approval = onApproval,
        };
    }

    fn emit(self: *Sink, ev: Event) void {
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        writeEvent(&aw.writer, ev) catch return;
        std.Io.File.stdout().writeStreamingAll(self.io, aw.written()) catch {};
    }

    /// Diagnostics never touch stdout.
    fn diag(self: *Sink, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, text) catch {};
    }

    fn onText(ctx: *anyopaque, text: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (self.json) {
            self.emit(.{ .text = text });
        } else {
            std.Io.File.stdout().writeStreamingAll(self.io, text) catch {};
        }
    }

    fn onStatus(ctx: *anyopaque, level: session_runtime.Level, text: []const u8) void {
        _ = level;
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.diag("{s}", .{text});
    }

    fn onToolStart(ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void {
        _ = call_id;
        _ = arguments_json;
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (self.json) {
            self.emit(.{ .tool_start = name });
        } else {
            self.diag("[tool] {s}\n", .{name});
        }
    }

    fn onToolResult(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        _ = call_id;
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (status == .denied) self.denied = true;
        if (self.json) {
            self.emit(.{ .tool_end = .{ .name = name, .ok = status == .ok } });
        } else {
            const max_show: usize = 200;
            self.diag("[{s}] {s}: {s}{s}\n", .{
                @tagName(status),
                name,
                if (output.len > max_show) output[0..max_show] else output,
                if (output.len > max_show) "..." else "",
            });
        }
    }

    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.diag("! {s}\n", .{text});
    }

    fn onAssistantMessage(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
        _ = ctx;
        _ = content;
        _ = tool_calls_json;
    }

    fn onApproval(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        const decision: tool_mod.ApprovalResponse = switch (self.policy) {
            .allow => .approved_once,
            .deny => .denied,
            .ask => self.askTty(req),
        };
        if (decision == .denied) self.denied = true;
        if (self.json) {
            self.emit(.{ .approval = .{
                .tool = req.tool,
                .detail = oneLine(self.arena, req.detail),
                .decision = decision,
            } });
        } else {
            self.diag("approval: {s} ({s}) -> {s}\n", .{ req.title, req.detail, @tagName(decision) });
        }
        return decision;
    }

    /// `--policy ask`: prompt on /dev/tty, never on stdin (stdin may carry the
    /// prompt). Without a terminal, fail closed.
    fn askTty(self: *Sink, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        if (!(std.Io.File.stdin().isTty(self.io) catch false)) return .denied;
        const tty = std.Io.Dir.openFileAbsolute(self.io, "/dev/tty", .{ .mode = .read_write }) catch return .denied;
        defer tty.close(self.io);
        var head_buf: [1024]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "\napproval needed: {s}\n  {s}\n[y] once  [s] session  [n] no: ", .{
            req.title, req.detail,
        }) catch "approval needed [y/n]: ";
        tty.writeStreamingAll(self.io, head) catch return .denied;
        var buf: [64]u8 = undefined;
        var reader = tty.reader(self.io, &buf);
        const line = reader.interface.takeDelimiterInclusive('\n') catch return .denied;
        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(answer, "y")) return .approved_once;
        if (std.ascii.eqlIgnoreCase(answer, "s")) return .approved_session;
        return .denied;
    }

    /// Finish the stream: exactly one error (on failure) and one final `end`.
    fn finish(self: *Sink, facts: Facts, message: []const u8) void {
        const status = runStatus(facts);
        if (self.json) {
            if (facts.failed and message.len > 0) self.emit(.{ .err = message });
            self.emit(.{ .end = status });
            return;
        }
        switch (status) {
            .interrupted => self.diag("(interrupted)\n", .{}),
            .failed => {
                if (message.len > 0) self.diag("error: {s}\n", .{message});
            },
            .denied, .ok => {},
        }
    }
};

fn effectivePolicy(ask: args_mod.AskArgs) args_mod.ApprovalPolicy {
    if (ask.yes) return .allow;
    if (ask.deny_all) return .deny;
    return ask.policy orelse .ask;
}

fn sessionsDir(cfg: *const config_mod.Store) []const u8 {
    const v = cfg.getString("sessions.dir", "project");
    if (v.len == 0 or std.mem.eql(u8, v, "project")) return ".ifnh/sessions";
    return v;
}

/// Read the whole prompt from stdin until EOF. A trailing newline is trimmed;
/// everything else (including internal newlines) is kept.
fn readStdinPrompt(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    const raw = try reader.interface.allocRemaining(arena, .limited(1024 * 1024));
    return std.mem.trimEnd(u8, raw, "\r\n");
}

/// `ifnh ask`: run one turn and return the process exit code.
pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    global: args_mod.GlobalFlags,
    ask: args_mod.AskArgs,
) u8 {
    const json = ask.json or global.json;
    const cwd = std.Io.Dir.cwd();

    const prompt = ask.prompt orelse readStdinPrompt(io, arena) catch |err| {
        stderrPrint(io, "error: cannot read prompt from stdin: {s}\n", .{@errorName(err)});
        return exitCode(.failed);
    };
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
        stderrPrint(io, "error: empty prompt\nusage: ifnh ask \"<prompt>\"  (or pipe one on stdin)\n", .{});
        return exit_usage;
    }

    var cfg = config_mod.load(arena, io, environ, cwd) catch |err| {
        stderrPrint(io, "error: {s}\n(run 'ifnh doctor' for diagnostics)\n", .{@errorName(err)});
        return exitCode(.failed);
    };
    defer cfg.deinit();
    for (cfg.errors.items) |e| stderrPrint(io, "config error [{s}]: {s}\n", .{ e.path, e.message });
    if (cfg.errors.items.len > 0) return exitCode(.failed);
    for (cfg.warnings.items) |w| stderrPrint(io, "config warning: {s}\n", .{w});

    var rt = session_runtime.SessionRuntime.init(io, arena, environ, &cfg, cwd, .{
        .sessions_dir = sessionsDir(&cfg),
        .cwd_label = if (environ.get("PWD")) |pwd| pwd else ".",
    }) catch |err| {
        stderrPrint(io, "error: cannot start a session: {s}\n", .{@errorName(err)});
        return exitCode(.failed);
    };
    defer rt.deinit();

    const instr = instructions_mod.assemble(cwd, io, arena, system_prompt.system_prompt, &.{}) catch |err| {
        stderrPrint(io, "error: cannot assemble instructions: {s}\n", .{@errorName(err)});
        return exitCode(.failed);
    };

    var sink = Sink{
        .io = io,
        .arena = arena,
        .json = json,
        .policy = effectivePolicy(ask),
    };
    const events = sink.events();
    const pcfg = rt.providerConfig(&cfg);
    if (json) sink.emit(.{ .start = .{ .session = rt.store.manifest.id, .model = pcfg.model } });

    const outcome = rt.submitTurn(arena, &cfg, pcfg, instr.text, instr.stable_len, prompt, cwd, &events) catch |err| {
        sink.finish(.{ .failed = true }, @errorName(err));
        return exitCode(.failed);
    };

    const facts = Facts{
        .interrupted = outcome.status == .cancelled,
        .failed = outcome.status == .failed or !outcome.ran,
        .denied = sink.denied,
    };
    const message = if (outcome.error_message.len > 0)
        outcome.error_message
    else if (!outcome.ran)
        "turn did not run"
    else
        "";
    sink.finish(facts, message);
    return exitCode(runStatus(facts));
}

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

// ---------------------------------------------------------------- tests

test "exit codes map from run status" {
    const cases = [_]struct { status: RunStatus, code: u8 }{
        .{ .status = .ok, .code = 0 },
        .{ .status = .failed, .code = 1 },
        .{ .status = .denied, .code = 3 },
        .{ .status = .interrupted, .code = 130 },
    };
    for (cases) |c| try std.testing.expectEqual(c.code, exitCode(c.status));
    try std.testing.expectEqual(@as(u8, 2), exit_usage);
}

test "run status precedence: interrupted > failed > denied > ok" {
    try std.testing.expectEqual(RunStatus.ok, runStatus(.{}));
    try std.testing.expectEqual(RunStatus.denied, runStatus(.{ .denied = true }));
    // A hard failure outranks a denial in the same turn.
    try std.testing.expectEqual(RunStatus.failed, runStatus(.{ .denied = true, .failed = true }));
    // An interrupt outranks everything.
    try std.testing.expectEqual(RunStatus.interrupted, runStatus(.{ .denied = true, .failed = true, .interrupted = true }));
    try std.testing.expectEqual(@as(u8, 130), exitCode(runStatus(.{ .failed = true, .interrupted = true })));
    try std.testing.expectEqual(@as(u8, 1), exitCode(runStatus(.{ .denied = true, .failed = true })));
}

fn encodeEvents(arena: std.mem.Allocator, events: []const Event) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (events) |ev| try writeEvent(&aw.writer, ev);
    return aw.written();
}

test "NDJSON: each event type serialises to its exact line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { ev: Event, line: []const u8 }{
        .{
            .ev = .{ .start = .{ .session = "s_abc", .model = "gpt-x" } },
            .line = "{\"type\":\"start\",\"session\":\"s_abc\",\"model\":\"gpt-x\"}\n",
        },
        .{ .ev = .{ .text = "hi" }, .line = "{\"type\":\"text\",\"text\":\"hi\"}\n" },
        .{ .ev = .{ .text = "a\nb" }, .line = "{\"type\":\"text\",\"text\":\"a\\nb\"}\n" },
        .{ .ev = .{ .tool_start = "read" }, .line = "{\"type\":\"tool\",\"name\":\"read\",\"phase\":\"start\"}\n" },
        .{
            .ev = .{ .tool_end = .{ .name = "read", .ok = true } },
            .line = "{\"type\":\"tool\",\"name\":\"read\",\"phase\":\"end\",\"ok\":true}\n",
        },
        .{
            .ev = .{ .tool_end = .{ .name = "write", .ok = false } },
            .line = "{\"type\":\"tool\",\"name\":\"write\",\"phase\":\"end\",\"ok\":false}\n",
        },
        .{
            .ev = .{ .approval = .{ .tool = "write", .detail = "a.txt", .decision = .approved_once } },
            .line = "{\"type\":\"approval\",\"tool\":\"write\",\"detail\":\"a.txt\",\"decision\":\"approved_once\"}\n",
        },
        .{
            .ev = .{ .approval = .{ .tool = "write", .detail = "a.txt", .decision = .approved_session } },
            .line = "{\"type\":\"approval\",\"tool\":\"write\",\"detail\":\"a.txt\",\"decision\":\"approved_session\"}\n",
        },
        .{
            .ev = .{ .approval = .{ .tool = "write", .detail = "a.txt", .decision = .denied } },
            .line = "{\"type\":\"approval\",\"tool\":\"write\",\"detail\":\"a.txt\",\"decision\":\"denied\"}\n",
        },
        .{ .ev = .{ .err = "boom" }, .line = "{\"type\":\"error\",\"message\":\"boom\"}\n" },
        .{ .ev = .{ .end = .ok }, .line = "{\"type\":\"end\",\"status\":\"ok\"}\n" },
        .{ .ev = .{ .end = .failed }, .line = "{\"type\":\"end\",\"status\":\"failed\"}\n" },
        .{ .ev = .{ .end = .denied }, .line = "{\"type\":\"end\",\"status\":\"denied\"}\n" },
        .{ .ev = .{ .end = .interrupted }, .line = "{\"type\":\"end\",\"status\":\"interrupted\"}\n" },
    };
    for (cases) |c| {
        const got = try encodeEvents(arena, &.{c.ev});
        try std.testing.expectEqualStrings(c.line, got);
    }
}

test "NDJSON: every line is valid JSON and carries no ESC byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detail = oneLine(arena, "rm -rf build\nsecond line\x1b[31m");
    const text = try encodeEvents(arena, &.{
        .{ .start = .{ .session = "s_1", .model = "m" } },
        .{ .text = "hello" },
        .{ .tool_start = "bash" },
        .{ .tool_end = .{ .name = "bash", .ok = false } },
        .{ .approval = .{ .tool = "bash", .detail = detail, .decision = .denied } },
        .{ .err = "nope" },
        .{ .end = .denied },
    });
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            std.debug.print("not JSON: {s}\n", .{line});
            return error.InvalidJson;
        };
        try std.testing.expect(parsed == .object);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), count);
}

test "NDJSON: one text line per streamed delta, start first and end last" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try encodeEvents(arena, &.{
        .{ .start = .{ .session = "s_1", .model = "m" } },
        .{ .text = "a" },
        .{ .text = "b" },
        .{ .text = "c" },
        .{ .end = .ok },
    });
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    var kinds: [8][]const u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        kinds[count] = parsed.object.get("type").?.string;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings("start", kinds[0]);
    try std.testing.expectEqualStrings("text", kinds[1]);
    try std.testing.expectEqualStrings("text", kinds[2]);
    try std.testing.expectEqualStrings("text", kinds[3]);
    try std.testing.expectEqualStrings("end", kinds[4]);
    // One line per delta, in order.
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"type\":\"text\",\"text\":\"a\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"type\":\"text\",\"text\":\"c\"}\n") != null);
}

test "oneLine flattens and strips control bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("a b c ", oneLine(arena_state.allocator(), "a\nb\tc\x1b"));
}
