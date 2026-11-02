//! Hooks engine (M1-T07, DECISIONS section P, D031; hooks v2 in D-07).
//!
//! Config-driven shell hooks at defined lifecycle events (P212). Synchronous:
//! `before_*` hooks may block progression (non-zero exit, P213/214) and can
//! additionally deny or rewrite a tool call through a JSON decision on
//! stdout. Hooks cannot mutate state through the runtime (P215) and cannot
//! trigger hooks (P220 — depth-1 events only). Repo-provided hooks live in
//! `.ifnh/` (trusted because they are committed config the developer
//! reviewed; trust gating for downloaded content is M2).
//!
//! Each hook receives the event payload as JSON on stdin and the same
//! identity in `IFNH_EVENT`, `IFNH_SESSION_ID` and `IFNH_TOOL_NAME`.

const std = @import("std");

pub const Event = enum {
    session_start,
    session_end,
    before_agent,
    after_agent,
    before_stage,
    after_stage,
    before_tool,
    after_tool,
    before_merge,
    after_merge,

    pub fn name(self: Event) []const u8 {
        return @tagName(self);
    }

    /// `before_*` events are gates: a failing hook (or a `deny` decision)
    /// stops the work they guard. Every other event is advisory.
    pub fn isBefore(self: Event) bool {
        return switch (self) {
            .before_agent, .before_stage, .before_tool, .before_merge => true,
            else => false,
        };
    }

    /// Events whose hooks may be filtered by tool name (`matcher`).
    pub fn toolScoped(self: Event) bool {
        return switch (self) {
            .before_tool, .after_tool => true,
            else => false,
        };
    }
};

pub const default_timeout_s: u32 = 30;
pub const max_timeout_s: u32 = 300;
/// Per-stream cap on what a single hook may print (D-07).
pub const output_limit: usize = 64 * 1024;

pub const HookDef = struct {
    event: Event,
    command: []const u8,
    /// `|`-separated exact tool names; empty or `*` matches every tool.
    matcher: []const u8 = "",
    /// Wall-clock limit for one run, 1..300 seconds (D-07).
    timeout_s: u32 = default_timeout_s,

    pub fn matchesTool(self: HookDef, tool_name: []const u8) bool {
        const m = std.mem.trim(u8, self.matcher, " ");
        if (m.len == 0 or std.mem.eql(u8, m, "*")) return true;
        var it = std.mem.splitScalar(u8, m, '|');
        while (it.next()) |part| {
            const name = std.mem.trim(u8, part, " ");
            if (name.len > 0 and std.mem.eql(u8, name, tool_name)) return true;
        }
        return false;
    }
};

/// What a hook told the runtime to do with the call it guards (D-07).
pub const Decision = enum { run, deny, rewrite };

pub const HookResult = struct {
    ok: bool,
    blocked: bool = false,
    output: []const u8 = "",
    decision: Decision = .run,
    /// Replacement tool input from the last `rewrite` decision (JSON object).
    rewritten_json: []const u8 = "",
};

/// Fields of the JSON payload a hook reads on stdin. Empty fields are
/// omitted, so a session hook payload is just `{"event":"session_start"}`.
pub const PayloadFields = struct {
    session_id: []const u8 = "",
    tool_name: []const u8 = "",
    /// Raw JSON for the tool input object ("" omits it).
    tool_input_json: []const u8 = "",
    stage: []const u8 = "",
    /// Extra `"key": value` JSON members, inserted verbatim.
    extra_json: []const u8 = "",
};

pub const Engine = struct {
    io: std.Io,
    workspace: std.Io.Dir,
    hooks: []const HookDef,
    /// Arena for this dispatch (scratch).
    alloc: std.mem.Allocator,
    /// Environment inherited by hooks (hooks add IFNH_* to a copy). When
    /// null the hook runs with only the IFNH_* variables.
    environ: ?*const std.process.Environ.Map = null,

    pub fn init(io: std.Io, workspace: std.Io.Dir, hooks: []const HookDef, alloc: std.mem.Allocator) Engine {
        return .{ .io = io, .workspace = workspace, .hooks = hooks, .alloc = alloc };
    }

    /// Copy with a different scratch allocator: parallel tool threads each
    /// dispatch into their own arena (D-07).
    pub fn withAlloc(self: Engine, alloc: std.mem.Allocator) Engine {
        var e = self;
        e.alloc = alloc;
        return e;
    }

    /// Parse `hooks` config:
    /// `{ event: "command" | [ "command" | {"command":..., "matcher":...,
    /// "timeout_s":...} ... ] }`.
    pub fn fromConfig(arena: std.mem.Allocator, v: ?std.json.Value) ![]HookDef {
        var out: std.ArrayListUnmanaged(HookDef) = .empty;
        const val = v orelse return &.{};
        if (val != .object) return &.{};
        var it = val.object.iterator();
        while (it.next()) |entry| {
            const event = std.meta.stringToEnum(Event, entry.key_ptr.*) orelse continue;
            switch (entry.value_ptr.*) {
                .string => |s| try appendDef(arena, &out, event, .{ .string = s }),
                .array => |arr| for (arr.items) |item| try appendDef(arena, &out, event, item),
                .object => |o| try appendDef(arena, &out, event, .{ .object = o }),
                else => {},
            }
        }
        return out.items;
    }

    fn appendDef(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(HookDef), event: Event, item: std.json.Value) !void {
        switch (item) {
            .string => |s| try out.append(arena, .{ .event = event, .command = try arena.dupe(u8, s) }),
            .object => |o| {
                const cmd = o.get("command") orelse return;
                if (cmd != .string) return;
                var def = HookDef{ .event = event, .command = try arena.dupe(u8, cmd.string) };
                if (o.get("matcher")) |m| {
                    if (m == .string) def.matcher = try arena.dupe(u8, m.string);
                }
                if (o.get("timeout_s")) |t| {
                    if (t == .integer) def.timeout_s = clampTimeout(t.integer);
                }
                try out.append(arena, def);
            },
            else => {},
        }
    }

    fn clampTimeout(seconds: i64) u32 {
        if (seconds < 1 or seconds > @as(i64, max_timeout_s)) return default_timeout_s;
        return @intCast(seconds);
    }

    /// Build the JSON payload handed to a hook. Never fails: a payload that
    /// cannot be assembled degrades to `{}`.
    pub fn payload(arena: std.mem.Allocator, event: Event, fields: PayloadFields) []const u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.writeAll("{\"event\":") catch return "{}";
        std.json.Stringify.value(event.name(), .{}, w) catch return "{}";
        stringField(w, "session_id", fields.session_id) catch return "{}";
        stringField(w, "tool_name", fields.tool_name) catch return "{}";
        stringField(w, "stage", fields.stage) catch return "{}";
        if (fields.tool_input_json.len > 0) {
            w.writeAll(",\"tool_input\":") catch return "{}";
            const valid = std.json.Scanner.validate(arena, fields.tool_input_json) catch false;
            if (valid) {
                w.writeAll(fields.tool_input_json) catch return "{}";
            } else {
                std.json.Stringify.value(fields.tool_input_json, .{}, w) catch return "{}";
            }
        }
        if (fields.extra_json.len > 0) {
            w.writeAll(",") catch return "{}";
            w.writeAll(fields.extra_json) catch return "{}";
        }
        w.writeAll("}") catch return "{}";
        return aw.written();
    }

    fn stringField(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (value.len == 0) return;
        try w.writeAll(",\"");
        try w.writeAll(key);
        try w.writeAll("\":");
        try std.json.Stringify.value(value, .{}, w);
    }

    /// Dispatch with a caller-built payload body (legacy entry point).
    pub fn dispatch(self: *Engine, event: Event, payload_json: []const u8) HookResult {
        return self.runEvent(event, .{}, payload_json);
    }

    /// Dispatch with structured fields: the payload is built (and, for
    /// `rewrite` decisions on `before_tool`, rebuilt) here.
    pub fn dispatchFor(self: *Engine, event: Event, fields: PayloadFields) HookResult {
        return self.runEvent(event, fields, null);
    }

    fn runEvent(self: *Engine, event: Event, fields: PayloadFields, raw: ?[]const u8) HookResult {
        var current = fields;
        var payload_json: []const u8 = if (raw) |r| r else payload(self.alloc, event, current);
        const tool_name: []const u8 = if (event.toolScoped()) current.tool_name else "";

        var any_output: std.ArrayListUnmanaged(u8) = .empty;
        var rewritten: []const u8 = "";
        var saw_rewrite = false;

        for (self.hooks) |hook| {
            if (hook.event != event) continue;
            if (tool_name.len > 0 and !hook.matchesTool(tool_name)) continue;

            const run = self.runHook(hook, event, current, payload_json);
            if (run.stdout.len > 0 or run.stderr.len > 0) {
                any_output.print(self.alloc, "[{s}] {s}{s}", .{ hook.command, run.stdout, run.stderr }) catch {};
            }
            if (!run.ok) {
                if (run.failure.len > 0) {
                    any_output.print(self.alloc, "[{s}] {s}", .{ hook.command, run.failure }) catch {};
                }
                return .{
                    .ok = false,
                    .blocked = event.isBefore(),
                    .output = any_output.items,
                    .decision = if (event.isBefore()) .deny else .run,
                };
            }
            // Only structured `before_tool` dispatches can be steered: a
            // literal payload body has nowhere to splice new arguments.
            if (event == .before_tool and raw == null) {
                switch (parseDecision(self.alloc, run.stdout)) {
                    .run => {},
                    .deny => |reason| {
                        any_output.print(self.alloc, "blocked: {s}", .{reason}) catch {};
                        return .{
                            .ok = true,
                            .blocked = true,
                            .output = any_output.items,
                            .decision = .deny,
                        };
                    },
                    .rewrite => |json| {
                        saw_rewrite = true;
                        rewritten = json;
                        current.tool_input_json = json;
                        payload_json = payload(self.alloc, event, current);
                    },
                }
            }
        }
        return .{
            .ok = true,
            .output = any_output.items,
            .decision = if (saw_rewrite) .rewrite else .run,
            .rewritten_json = rewritten,
        };
    }

    const HookRun = struct {
        ok: bool,
        stdout: []const u8,
        stderr: []const u8,
        /// Set when the hook never ran to completion (spawn, timeout, cap).
        failure: []const u8 = "",
    };

    /// Run one hook with the payload on stdin, a per-hook deadline and a
    /// 64 KiB cap per stream.
    fn runHook(self: *Engine, hook: HookDef, event: Event, fields: PayloadFields, payload_json: []const u8) HookRun {
        const alloc = self.alloc;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        argv.append(alloc, "/bin/sh") catch return failed("out of memory");
        argv.append(alloc, "-c") catch return failed("out of memory");
        argv.append(alloc, hook.command) catch return failed("out of memory");

        // Hooks see the parent environment plus their own identity.
        var env = std.process.Environ.Map.init(alloc);
        if (self.environ) |base| {
            var it = base.iterator();
            while (it.next()) |entry| env.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        } else {
            // No parent environment to inherit: a bare but usable shell.
            env.put("PATH", "/usr/local/bin:/usr/bin:/bin") catch {};
        }
        env.put("IFNH_EVENT", event.name()) catch {};
        if (fields.session_id.len > 0) env.put("IFNH_SESSION_ID", fields.session_id) catch {};
        if (fields.tool_name.len > 0) env.put("IFNH_TOOL_NAME", fields.tool_name) catch {};

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .dir = self.workspace },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| return failed(@errorName(err));
        defer child.kill(self.io);

        // Write the payload and close stdin so the hook sees EOF.
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(self.io, payload_json) catch {};
            stdin.close(self.io);
            child.stdin = null;
        }

        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(alloc, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();
        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        const timeout: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromSeconds(@intCast(hook.timeout_s)),
        } };
        const deadline = timeout.toDeadline(self.io);

        var aborted = false;
        while (multi_reader.fill(64, deadline)) |_| {
            if (stdout_reader.buffered().len > output_limit or stderr_reader.buffered().len > output_limit) {
                aborted = true;
                break;
            }
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => {
                aborted = true;
            },
        }
        if (aborted) return failed("hook timed out or exceeded the 64 KiB output limit");

        multi_reader.checkAnyError() catch {};
        const term = child.wait(self.io) catch return failed("hook wait failed");
        const exited_ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        return .{
            .ok = exited_ok,
            .stdout = multi_reader.toOwnedSlice(0) catch "",
            .stderr = multi_reader.toOwnedSlice(1) catch "",
        };
    }

    fn failed(reason: []const u8) HookRun {
        return .{ .ok = false, .stdout = "", .stderr = "", .failure = reason };
    }
};

const ParsedDecision = union(enum) {
    run,
    deny: []const u8,
    rewrite: []const u8,
};

/// Read the decision protocol from a hook's stdout: the last non-empty line
/// may be `{"decision":"deny","reason":"..."}` or
/// `{"decision":"rewrite","arguments":{...}}`. Anything else means "run".
fn parseDecision(arena: std.mem.Allocator, stdout: []const u8) ParsedDecision {
    const line = lastNonEmptyLine(stdout) orelse return .run;
    if (line[0] != '{') return .run;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return .run;
    if (v != .object) return .run;
    const d = v.object.get("decision") orelse return .run;
    if (d != .string) return .run;
    if (std.mem.eql(u8, d.string, "deny")) {
        const reason = v.object.get("reason") orelse return .{ .deny = line };
        return .{ .deny = if (reason == .string) reason.string else line };
    }
    if (std.mem.eql(u8, d.string, "rewrite")) {
        const args = v.object.get("arguments") orelse return .run;
        if (args != .object) return .run;
        var aw: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(args, .{}, &aw.writer) catch return .run;
        return .{ .rewrite = aw.written() };
    }
    return .run;
}

fn lastNonEmptyLine(text: []const u8) ?[]const u8 {
    var end = text.len;
    while (end > 0) {
        var start = end;
        while (start > 0 and text[start - 1] != '\n') start -= 1;
        const trimmed = std.mem.trim(u8, text[start..end], " \t\r");
        if (trimmed.len > 0) return trimmed;
        if (start == 0) break;
        end = start - 1;
    }
    return null;
}

// ---------------------------------------------------------------- tests

fn testEngine(tmp: *std.testing.TmpDir, hooks: []const HookDef, alloc: std.mem.Allocator) Engine {
    // A minimal environment: the test host's own env is not available here,
    // and the hooks below need a usable PATH.
    var env = std.process.Environ.Map.init(alloc);
    env.put("PATH", "/usr/local/bin:/usr/bin:/bin") catch {};
    const stored = alloc.create(std.process.Environ.Map) catch unreachable;
    stored.* = env;
    var engine = Engine.init(std.testing.io, tmp.dir, hooks, alloc);
    engine.environ = stored;
    return engine;
}

test "hooks fromConfig parses string, array and object forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{
        \\  "before_tool": ["echo a", {"command": "lint.sh", "matcher": "edit|write", "timeout_s": 5}],
        \\  "after_tool": {"command": "fmt.sh", "timeout_s": 900},
        \\  "session_start": "hello",
        \\  "bogus_event": "x"
        \\}
    , .{});
    const hooks = try Engine.fromConfig(a, v);
    try std.testing.expectEqual(@as(usize, 4), hooks.len);
    try std.testing.expectEqual(Event.before_tool, hooks[0].event);
    try std.testing.expectEqualStrings("echo a", hooks[0].command);
    try std.testing.expectEqualStrings("edit|write", hooks[1].matcher);
    try std.testing.expectEqual(@as(u32, 5), hooks[1].timeout_s);
    // Out-of-range timeouts fall back to the default rather than hanging.
    try std.testing.expectEqual(default_timeout_s, hooks[2].timeout_s);
    try std.testing.expectEqualStrings("", hooks[0].matcher);
}

test "hooks matcher selects exact tool names and wildcards" {
    const def = HookDef{ .event = .before_tool, .command = "x", .matcher = " edit | write " };
    try std.testing.expect(def.matchesTool("edit"));
    try std.testing.expect(def.matchesTool("write"));
    try std.testing.expect(!def.matchesTool("read"));
    try std.testing.expect(!def.matchesTool("edi"));
    const all = HookDef{ .event = .before_tool, .command = "x" };
    try std.testing.expect(all.matchesTool("read"));
    const star = HookDef{ .event = .before_tool, .command = "x", .matcher = "*" };
    try std.testing.expect(star.matchesTool("bash"));
}

test "hooks run and after_* failures do not block" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var hooks: [1]HookDef = .{.{ .event = .after_tool, .command = "exit 3" }};
    var e = Engine.init(io, tmp.dir, &hooks, a);
    const r = e.dispatch(.after_tool, "{}");
    try std.testing.expect(!r.ok);
    try std.testing.expect(!r.blocked);

    hooks[0] = .{ .event = .before_tool, .command = "exit 3" };
    const r2 = e.dispatch(.before_tool, "{}");
    try std.testing.expect(!r2.ok);
    try std.testing.expect(r2.blocked);

    hooks[0] = .{ .event = .before_tool, .command = "echo check" };
    const r3 = e.dispatch(.before_tool, "{}");
    try std.testing.expect(r3.ok);
    try std.testing.expect(!r3.blocked);
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "check") != null);
}

test "hooks receive the payload on stdin and the event in env" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .before_tool, .command = "echo \"$IFNH_EVENT $IFNH_TOOL_NAME\"; cat" }};
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.before_tool, .{
        .session_id = "sess-1",
        .tool_name = "edit",
        .tool_input_json = "{\"path\":\"a.txt\"}",
    });
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "before_tool edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"tool_name\":\"edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"session_id\":\"sess-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"tool_input\":{\"path\":\"a.txt\"}") != null);
}

test "hooks payload embeds valid objects and escapes bad tool input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ok = Engine.payload(a, .after_agent, .{ .session_id = "s", .extra_json = "\"turn\":2" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, ok, .{});
    try std.testing.expectEqualStrings("after_agent", parsed.object.get("event").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.object.get("turn").?.integer);

    const bad = Engine.payload(a, .before_tool, .{ .tool_name = "bash", .tool_input_json = "{not json" });
    const parsed_bad = try std.json.parseFromSliceLeaky(std.json.Value, a, bad, .{});
    try std.testing.expectEqualStrings("{not json", parsed_bad.object.get("tool_input").?.string);
}

test "before_tool hooks can deny with a JSON decision" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .before_tool, .command = "echo '{\"decision\":\"deny\",\"reason\":\"no edits today\"}'" }};
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.before_tool, .{ .tool_name = "edit", .tool_input_json = "{}" });
    try std.testing.expect(r.blocked);
    try std.testing.expectEqual(Decision.deny, r.decision);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "no edits today") != null);
}

test "before_tool hooks can rewrite arguments and the rewrite is chained" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{
        .{ .event = .before_tool, .command = "echo '{\"decision\":\"rewrite\",\"arguments\":{\"path\":\"b.txt\"}}'" },
        // Sees the rewritten input: 1 when the payload carries b.txt.
        .{ .event = .before_tool, .command = "grep -c b.txt" },
    };
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.before_tool, .{ .tool_name = "write", .tool_input_json = "{\"path\":\"a.txt\"}" });
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(Decision.rewrite, r.decision);
    try std.testing.expectEqualStrings("{\"path\":\"b.txt\"}", r.rewritten_json);
    const second = std.mem.lastIndexOf(u8, r.output, "[grep -c b.txt] ").?;
    try std.testing.expect(std.mem.indexOf(u8, r.output[second..], "1") != null);
}

test "after_tool hooks never block on a deny decision" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .after_tool, .command = "echo '{\"decision\":\"deny\",\"reason\":\"late\"}'" }};
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.after_tool, .{ .tool_name = "edit", .tool_input_json = "{}" });
    try std.testing.expect(r.ok);
    try std.testing.expect(!r.blocked);
    try std.testing.expectEqual(Decision.run, r.decision);
}

test "hooks with a non-matching matcher are skipped" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .before_tool, .command = "exit 9", .matcher = "edit|write" }};
    var e = testEngine(&tmp, &hooks, a);
    const skipped = e.dispatchFor(.before_tool, .{ .tool_name = "read", .tool_input_json = "{}" });
    try std.testing.expect(skipped.ok);
    try std.testing.expectEqualStrings("", skipped.output);

    const run = e.dispatchFor(.before_tool, .{ .tool_name = "write", .tool_input_json = "{}" });
    try std.testing.expect(!run.ok);
    try std.testing.expect(run.blocked);
}

test "hooks are dispatched in config order and only for their event" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{
        .{ .event = .before_tool, .command = "echo one" },
        .{ .event = .after_tool, .command = "echo skipped" },
        .{ .event = .before_tool, .command = "echo two" },
    };
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.before_tool, .{ .tool_name = "edit" });
    try std.testing.expect(r.ok);
    const one = std.mem.indexOf(u8, r.output, "one").?;
    const two = std.mem.indexOf(u8, r.output, "two").?;
    try std.testing.expect(one < two);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "skipped") == null);
}

test "hooks that time out block a before event and are killed" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .before_stage, .command = "sleep 5", .timeout_s = 1 }};
    var e = testEngine(&tmp, &hooks, a);
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    const r = e.dispatchFor(.before_stage, .{ .stage = "implement" });
    const elapsed = std.Io.Timestamp.durationTo(started, std.Io.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(!r.ok);
    try std.testing.expect(r.blocked);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "timed out") != null);
    try std.testing.expect(elapsed.nanoseconds < std.time.ns_per_s * 4);
}

test "hooks that flood stdout are cut off at the output cap" {
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hooks = [_]HookDef{.{ .event = .after_tool, .command = "i=0; while [ $i -lt 300 ]; do printf '%01024d' 0; i=$((i+1)); done" }};
    var e = testEngine(&tmp, &hooks, a);
    const r = e.dispatchFor(.after_tool, .{ .tool_name = "bash" });
    try std.testing.expect(!r.ok);
    try std.testing.expect(!r.blocked);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "output limit") != null);
    try std.testing.expect(r.output.len < output_limit);
}

test "hook decisions parse from the last non-empty line only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqual(ParsedDecision.run, parseDecision(a, "plain output"));
    try std.testing.expectEqual(ParsedDecision.run, parseDecision(a, ""));
    try std.testing.expectEqual(ParsedDecision.run, parseDecision(a, "{\"decision\":\"run\"}"));
    const noisy = parseDecision(a, "thinking...\n{\"decision\":\"deny\",\"reason\":\"x\"}\n\n");
    try std.testing.expectEqualStrings("x", noisy.deny);
    const no_reason = parseDecision(a, "{\"decision\":\"deny\"}");
    try std.testing.expect(no_reason.deny.len > 0);
    try std.testing.expectEqual(ParsedDecision.run, parseDecision(a, "{\"decision\":\"rewrite\",\"arguments\":3}"));
}
