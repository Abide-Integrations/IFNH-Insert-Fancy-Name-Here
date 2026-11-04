//! libifnh: the ifnh agent runtime as a library (ACTIVE_PLAN E-06b).
//!
//! Two layers in one file:
//!
//!  * `Runtime`, a small Zig API over `SessionRuntime`: one conversation
//!    rooted at a directory, driven by `prompt`. It never touches the
//!    terminal, installs no signal handlers and reads no config files: the
//!    embedder is the config source (`config_json` over the builtin defaults).
//!  * A C ABI (`include/ifnh.h`) over `Runtime`, exported only when the
//!    library is built with libc (the static `libifnh.a` is).
//!
//! The runtime is single-threaded and not reentrant: call it from one thread
//! at a time and never from inside an event callback. Shell commands and
//! hooks run in the process working directory, so `chdir` to the project
//! before prompting if it differs from `cwd`. Landlock is unavailable here
//! (it re-executes the `ifnh` binary, which an embedder is not).

const std = @import("std");
const builtin = @import("builtin");
const version_mod = @import("version.zig");
const config_mod = @import("core/config/config.zig");
const session_runtime = @import("core/agent/session_runtime.zig");
const instructions_mod = @import("core/instructions.zig");
const system_prompt = @import("core/agent/system_prompt.zig");
const tool_mod = @import("tools/tool.zig");
const core_types = @import("core/types.zig");
const ask_mod = @import("cli/ask.zig");

pub const Events = session_runtime.Events;
pub const TurnOutcome = session_runtime.TurnOutcome;
pub const ImagePart = core_types.ImagePart;

/// The library version (the same string as `ifnh version`).
pub fn version() []const u8 {
    return version_mod.version;
}

/// Why `Runtime.init` failed, for the embedder to show. `message` is empty
/// unless the error is `error.InvalidConfig` or `error.BadCwd`.
pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..self.buf.len];
        self.len = text.len;
    }
};

pub const InitError = error{ InvalidConfig, BadCwd, OutOfMemory, SessionFailed };

/// One conversation. Heap-allocated and never moved: the runtime keeps
/// pointers into its own arena.
pub const Runtime = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    cwd: std.Io.Dir,
    cfg: config_mod.Store,
    rt: session_runtime.SessionRuntime,
    instr: instructions_mod.Assembled,
    cancel: std.atomic.Value(bool) = .init(false),

    /// Build a runtime rooted at `cwd_path`. `config_json`, when given, must
    /// be a JSON object; it is merged over the builtin defaults as the
    /// highest layer and validated like any config. `environ` supplies API
    /// keys and `HOME`; `io` is used for every file, process and network
    /// operation. Free with `deinit`.
    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        cwd_path: []const u8,
        config_json: ?[]const u8,
        diag: *Diag,
    ) InitError!*Runtime {
        const self = try alloc.create(Runtime);
        errdefer alloc.destroy(self);
        self.* = .{ .backing = alloc, .arena = std.heap.ArenaAllocator.init(alloc), .cwd = undefined, .cfg = undefined, .rt = undefined, .instr = undefined };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        self.cwd = std.Io.Dir.cwd().openDir(io, cwd_path, .{}) catch {
            diag.set("cannot open directory '{s}'", .{cwd_path});
            return error.BadCwd;
        };
        errdefer self.cwd.close(io);

        self.cfg = config_mod.Store.init(a) catch return error.OutOfMemory;
        if (config_json) |json| try mergeOverlay(&self.cfg, json, diag);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const label = if (self.cwd.realPathFile(io, ".", &path_buf)) |n| try a.dupe(u8, path_buf[0..n]) else |_| try a.dupe(u8, cwd_path);
        self.rt = session_runtime.SessionRuntime.init(io, a, environ, &self.cfg, self.cwd, .{
            .sessions_dir = sessionsDir(&self.cfg),
            .cwd_label = label,
            .sandbox_exe = "",
        }) catch |err| {
            diag.set("cannot start a session: {s}", .{@errorName(err)});
            return error.SessionFailed;
        };
        errdefer self.rt.deinit();
        self.instr = instructions_mod.assemble(self.cwd, io, a, system_prompt.system_prompt, &.{}) catch {
            diag.set("cannot assemble instructions", .{});
            return error.SessionFailed;
        };
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const io = self.rt.io;
        self.rt.deinit();
        self.cwd.close(io);
        const backing = self.backing;
        var arena = self.arena;
        backing.destroy(self);
        arena.deinit();
    }

    /// Ask the in-flight `prompt` to stop. Safe to call from another thread.
    pub fn requestCancel(self: *Runtime) void {
        self.cancel.store(true, .release);
    }

    /// Run one turn. `text` and `images` are copied into the runtime's arena,
    /// which grows with the conversation (as the REPL's does). `events`
    /// receives text, status, notices and tool activity; its `on_approval`
    /// decides every permission ask.
    pub fn prompt(self: *Runtime, text: []const u8, images: []const ImagePart, events: *const Events) !TurnOutcome {
        const a = self.arena.allocator();
        self.rt.cancel_flag = &self.cancel;
        const owned = try a.dupe(u8, text);
        const pcfg = self.rt.providerConfig(&self.cfg);
        return self.rt.submitTurn(a, &self.cfg, pcfg, self.instr.text, self.instr.stable_len, owned, images, self.cwd, events);
    }
};

fn sessionsDir(cfg: *const config_mod.Store) []const u8 {
    const v = cfg.getString("sessions.dir", "project");
    if (v.len == 0 or std.mem.eql(u8, v, "project")) return ".ifnh/sessions";
    return v;
}

fn mergeOverlay(cfg: *config_mod.Store, json: []const u8, diag: *Diag) InitError!void {
    const value = std.json.parseFromSliceLeaky(std.json.Value, cfg.alloc(), json, .{}) catch {
        diag.set("config_json is not valid JSON", .{});
        return error.InvalidConfig;
    };
    if (value != .object) {
        diag.set("config_json must be a JSON object", .{});
        return error.InvalidConfig;
    }
    cfg.mergeValue(value, .{ .layer = .cli, .origin = "libifnh" }) catch return error.OutOfMemory;
    cfg.errors.clearRetainingCapacity();
    cfg.warnings.clearRetainingCapacity();
    cfg.validate() catch return error.OutOfMemory;
    if (cfg.errors.items.len > 0) {
        const first = cfg.errors.items[0];
        diag.set("config error [{s}]: {s}", .{ first.path, first.message });
        return error.InvalidConfig;
    }
}

// ---------------------------------------------------------------- C ABI

/// Event kinds of `ifnh_event_cb`; the numbers are part of the ABI.
pub const EventKind = enum(c_int) { text = 0, status = 1, notice = 2, tool_start = 3, tool_result = 4 };

pub const EventCb = *const fn (user: ?*anyopaque, kind: c_int, text: [*:0]const u8, status: c_int) callconv(.c) void;

/// What the C handle owns. The `Io` implementation lives here so `Runtime`
/// can keep a copy of the `std.Io` interface for its whole life.
const Handle = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    runtime: *Runtime,
};

const c_alloc = std.heap.c_allocator;

/// Adapts `Events` to the C callback. Strings are NUL-terminated copies that
/// live for the duration of the callback.
const CSink = struct {
    cb: EventCb,
    user: ?*anyopaque,
    /// A tool call was refused (by policy: there is no one to ask).
    denied: bool = false,

    fn events(self: *CSink) Events {
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

    fn emit(self: *CSink, kind: EventKind, text: []const u8, status: c_int) void {
        const z = c_alloc.dupeSentinel(u8, text, 0) catch return;
        defer c_alloc.free(z);
        self.cb(self.user, @intFromEnum(kind), z.ptr, status);
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const self: *CSink = @ptrCast(@alignCast(ctx));
        self.emit(.text, chunk, 0);
    }

    fn onStatus(ctx: *anyopaque, level: session_runtime.Level, text: []const u8) void {
        const self: *CSink = @ptrCast(@alignCast(ctx));
        self.emit(.status, text, @intFromEnum(level));
    }

    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *CSink = @ptrCast(@alignCast(ctx));
        self.emit(.notice, text, 0);
    }

    fn onToolStart(ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void {
        _ = call_id;
        _ = arguments_json;
        const self: *CSink = @ptrCast(@alignCast(ctx));
        self.emit(.tool_start, name, 0);
    }

    fn onToolResult(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        _ = call_id;
        _ = name;
        const self: *CSink = @ptrCast(@alignCast(ctx));
        if (status == .denied) self.denied = true;
        self.emit(.tool_result, output, @intFromEnum(status));
    }

    fn onAssistantMessage(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
        _ = ctx;
        _ = content;
        _ = tool_calls_json;
    }

    /// The C API has no approval channel: an ask is a refusal. Allow tools in
    /// `config_json` (`permissions`) instead.
    fn onApproval(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        _ = req;
        const self: *CSink = @ptrCast(@alignCast(ctx));
        self.denied = true;
        return .denied;
    }
};

fn setErr(err: ?*?[*:0]u8, comptime fmt: []const u8, args: anytype) void {
    const slot = err orelse return;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
    const z = c_alloc.dupeSentinel(u8, text, 0) catch {
        slot.* = null;
        return;
    };
    slot.* = z.ptr;
}

fn envBlock() std.process.Environ {
    const raw = std.c.environ;
    var n: usize = 0;
    while (raw[n] != null) n += 1;
    return .{ .block = .{ .slice = raw[0..n :null] } };
}

fn runtimeNew(cwd: [*:0]const u8, config_json: ?[*:0]const u8, err: ?*?[*:0]u8) callconv(.c) ?*Handle {
    if (err) |slot| slot.* = null;
    const h = c_alloc.create(Handle) catch {
        setErr(err, "out of memory", .{});
        return null;
    };
    const environ = envBlock();
    h.env = environ.createMap(c_alloc) catch {
        c_alloc.destroy(h);
        setErr(err, "out of memory", .{});
        return null;
    };
    h.threaded = std.Io.Threaded.init(c_alloc, .{ .environ = environ });
    var diag = Diag{};
    h.runtime = Runtime.init(h.threaded.io(), c_alloc, &h.env, std.mem.span(cwd), if (config_json) |j| std.mem.span(j) else null, &diag) catch |e| {
        h.threaded.deinit();
        h.env.deinit();
        c_alloc.destroy(h);
        if (diag.len > 0) setErr(err, "{s}", .{diag.message()}) else setErr(err, "cannot create the runtime: {s}", .{@errorName(e)});
        return null;
    };
    return h;
}

fn runtimePrompt(h: *Handle, text: [*:0]const u8, cb: EventCb, user: ?*anyopaque, err: ?*?[*:0]u8) callconv(.c) c_int {
    if (err) |slot| slot.* = null;
    var sink = CSink{ .cb = cb, .user = user };
    const events = sink.events();
    const outcome = h.runtime.prompt(std.mem.span(text), &.{}, &events) catch |e| {
        setErr(err, "turn failed: {s}", .{@errorName(e)});
        return 1;
    };
    const facts = ask_mod.Facts{
        .interrupted = outcome.status == .cancelled,
        .budget = outcome.budget_exceeded,
        .failed = outcome.status == .failed or !outcome.ran,
        .denied = sink.denied,
    };
    const status = ask_mod.runStatus(facts);
    if (status == .failed) {
        setErr(err, "{s}", .{if (outcome.error_message.len > 0) outcome.error_message else "turn did not run (is a model configured?)"});
    }
    return switch (status) {
        .ok => 0,
        .failed => 1,
        .interrupted => 2,
        .denied => 3,
        .budget => 4,
    };
}

fn runtimeFree(h: ?*Handle) callconv(.c) void {
    const handle = h orelse return;
    handle.runtime.deinit();
    handle.threaded.deinit();
    handle.env.deinit();
    c_alloc.destroy(handle);
}

fn versionC() callconv(.c) [*:0]const u8 {
    return version_mod.version;
}

fn stringFree(s: ?[*:0]u8) callconv(.c) void {
    const p = s orelse return;
    c_alloc.free(std.mem.span(p));
}

comptime {
    if (builtin.link_libc and !builtin.is_test) {
        @export(&runtimeNew, .{ .name = "ifnh_runtime_new" });
        @export(&runtimePrompt, .{ .name = "ifnh_runtime_prompt" });
        @export(&runtimeFree, .{ .name = "ifnh_runtime_free" });
        @export(&versionC, .{ .name = "ifnh_version" });
        @export(&stringFree, .{ .name = "ifnh_string_free" });
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Recorder = struct {
    kinds: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    statuses: std.ArrayListUnmanaged(u8) = .empty,

    fn events(self: *Recorder) Events {
        return .{
            .ctx = @ptrCast(self),
            .on_text = onText,
            .on_status = onStatus,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
            .on_assistant_message = onAssistant,
            .on_approval = onApproval,
        };
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.kinds.append(testing.allocator, .text) catch {};
        self.text.appendSlice(testing.allocator, chunk) catch {};
    }
    fn onStatus(ctx: *anyopaque, _: session_runtime.Level, text: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.kinds.append(testing.allocator, .status) catch {};
        self.statuses.appendSlice(testing.allocator, text) catch {};
    }
    fn onNotice(ctx: *anyopaque, _: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.kinds.append(testing.allocator, .notice) catch {};
    }
    fn onToolStart(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.kinds.append(testing.allocator, .tool_start) catch {};
    }
    fn onToolResult(ctx: *anyopaque, _: []const u8, _: []const u8, _: tool_mod.Status, _: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.kinds.append(testing.allocator, .tool_result) catch {};
    }
    fn onAssistant(_: *anyopaque, _: []const u8, _: ?[]const u8) void {}
    fn onApproval(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        return .denied;
    }
    fn deinit(self: *Recorder) void {
        self.kinds.deinit(testing.allocator);
        self.text.deinit(testing.allocator);
        self.statuses.deinit(testing.allocator);
    }
};

fn testEnv() !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(testing.allocator);
    try env.put("IFNH_LIB_TEST_KEY", "test-key-1234567890");
    return env;
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

test "libifnh version matches version.zig" {
    try testing.expectEqualStrings(version_mod.version, version());
    try testing.expectEqualStrings(version_mod.version, std.mem.span(versionC()));
}

test "Runtime.init works in a temp dir; a prompt with no model does not run" {
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var env = try testEnv();
    defer env.deinit();
    var diag = Diag{};
    const rt = try Runtime.init(testing.io, testing.allocator, &env, try tmpPath(&tmp, &buf), null, &diag);
    defer rt.deinit();

    var rec = Recorder{};
    defer rec.deinit();
    const events = rec.events();
    const outcome = try rt.prompt("hello", &.{}, &events);
    try testing.expect(!outcome.ran);
    try testing.expect(std.mem.indexOf(u8, rec.statuses.items, "no model configured") != null);
    try testing.expectEqual(EventKind.status, rec.kinds.items[0]);
}

test "Runtime.init reports a bad config overlay and a bad directory" {
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buf);
    var env = try testEnv();
    defer env.deinit();
    var diag = Diag{};

    try testing.expectError(error.InvalidConfig, Runtime.init(testing.io, testing.allocator, &env, path, "{not json", &diag));
    try testing.expectEqualStrings("config_json is not valid JSON", diag.message());
    try testing.expectError(error.InvalidConfig, Runtime.init(testing.io, testing.allocator, &env, path, "[1]", &diag));
    try testing.expectError(error.InvalidConfig, Runtime.init(testing.io, testing.allocator, &env, path, "{\"sandbox\":{\"mode\":\"strict\"}}", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "sandbox.mode") != null);
    try testing.expectError(error.BadCwd, Runtime.init(testing.io, testing.allocator, &env, "/no/such/dir/ifnh-lib", null, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "/no/such/dir/ifnh-lib") != null);
}

const stream_body = "data: {\"choices\":[{\"delta\":{\"content\":\"lib \"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n" ++
    "data: [DONE]\n\n";

fn modelOverlay(arena: std.mem.Allocator, port: u16) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{"model":{{"provider":"openai","model":"lib-test","base_url":"http://127.0.0.1:{d}","api_key_env":"IFNH_LIB_TEST_KEY"}}}}
    , .{port});
}

test "Runtime.prompt streams a scripted turn through the events (Zig API)" {
    const providers_testing = @import("providers/testing.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var env = try testEnv();
    defer env.deinit();
    const fake = try providers_testing.FakeServer.start(testing.io, arena, stream_body);
    defer fake.stop();

    var diag = Diag{};
    const rt = try Runtime.init(testing.io, testing.allocator, &env, try tmpPath(&tmp, &buf), try modelOverlay(arena, fake.port), &diag);
    defer rt.deinit();
    var rec = Recorder{};
    defer rec.deinit();
    const events = rec.events();
    const outcome = try rt.prompt("hi", &.{}, &events);
    fake.wait();
    try testing.expect(outcome.ran);
    try testing.expect(outcome.status == .completed);
    try testing.expectEqualStrings("lib ok", rec.text.items);
    try testing.expectEqual(EventKind.text, rec.kinds.items[0]);
}

const CRecord = struct {
    kinds: [16]c_int = undefined,
    count: usize = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
};

fn recordCb(user: ?*anyopaque, kind: c_int, text: [*:0]const u8, status: c_int) callconv(.c) void {
    _ = status;
    const rec: *CRecord = @ptrCast(@alignCast(user.?));
    if (rec.count < rec.kinds.len) rec.kinds[rec.count] = kind;
    rec.count += 1;
    if (kind == @intFromEnum(EventKind.text)) {
        const s = std.mem.span(text);
        const n = @min(s.len, rec.text.len - rec.text_len);
        @memcpy(rec.text[rec.text_len..][0..n], s[0..n]);
        rec.text_len += n;
    }
}

test "C ABI: new, prompt with callbacks, string free, free" {
    const providers_testing = @import("providers/testing.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try arena.dupeSentinel(u8, try tmpPath(&tmp, &buf), 0);

    // Bad config: a message, no runtime.
    var err: ?[*:0]u8 = null;
    try testing.expect(runtimeNew(cwd, "{broken", &err) == null);
    try testing.expect(err != null);
    try testing.expectEqualStrings("config_json is not valid JSON", std.mem.span(err.?));
    stringFree(err);

    // Good config against the fake model. The key comes from the real environment.
    const fake = try providers_testing.FakeServer.start(testing.io, arena, stream_body);
    defer fake.stop();
    const overlay = try arena.dupeSentinel(u8, try modelOverlay(arena, fake.port), 0);
    // The C layer reads the real process environment.
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    _ = c.setenv("IFNH_LIB_TEST_KEY", "test-key-1234567890", 1);
    const h = runtimeNew(cwd, overlay, &err) orelse return error.TestUnexpectedResult;
    try testing.expect(err == null);
    defer runtimeFree(h);
    var rec = CRecord{};
    const code = runtimePrompt(h, "hi", recordCb, &rec, &err);
    fake.wait();
    if (code != 0) std.debug.print("prompt failed: {s}\n", .{if (err) |e| std.mem.span(e) else "(no message)"});
    try testing.expectEqual(@as(c_int, 0), code);
    try testing.expectEqualStrings("lib ok", rec.text[0..rec.text_len]);
    try testing.expectEqual(@as(c_int, 0), rec.kinds[0]);
}

test "C ABI: a prompt with no model returns 1 with a message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try arena.dupeSentinel(u8, try tmpPath(&tmp, &buf), 0);
    var err: ?[*:0]u8 = null;
    const h = runtimeNew(cwd, null, &err) orelse return error.TestUnexpectedResult;
    defer runtimeFree(h);
    var rec = CRecord{};
    try testing.expectEqual(@as(c_int, 1), runtimePrompt(h, "hi", recordCb, &rec, &err));
    try testing.expect(err != null);
    stringFree(err);
    // The "no model configured" status reached the callback as a status event.
    try testing.expectEqual(@as(c_int, @intFromEnum(EventKind.status)), rec.kinds[0]);
    runtimeFree(null);
    stringFree(null);
}
