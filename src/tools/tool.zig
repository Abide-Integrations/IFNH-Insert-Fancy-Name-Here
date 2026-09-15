//! Tool contract, registry, and dispatch (DESIGN §3.2).
//!
//! M0 tools: read, glob, grep, edit, write, bash, git. Tool arguments are
//! JSON objects decoded with std.json. Mutating tools journal their file
//! operations (bash/git side effects are opaque and not journaled — they
//! are gated by approvals instead, DECISIONS M185-186).
//!
//! Every tool result is model-facing text, UTF-8-safe, and capped.

const std = @import("std");
const engine_mod = @import("../core/permissions/engine.zig");
const journal_mod = @import("../core/journal.zig");
const globm = @import("../core/permissions/glob.zig");
const cmd_class = @import("../core/permissions/command_class.zig");

pub const max_tool_output_bytes: usize = 64 * 1024;
pub const max_file_size_bytes: usize = 1024 * 1024;

pub const Status = enum { ok, denied, failed, timeout };

pub const ApprovalRequest = struct {
    pub const Grant = union(enum) {
        none,
        command_prefix: []const u8,
        path_write: []const u8,
    };

    title: []const u8,
    detail: []const u8, // command line or path
    /// What a session-scope approval should grant.
    grant: Grant = .none,
};

pub const ApprovalResponse = enum { approved_once, approved_session, denied };

pub const ToolContext = struct {
    io: std.Io,
    /// Scratch arena for this tool call only.
    arena: std.mem.Allocator,
    workspace: std.Io.Dir,
    engine: *engine_mod.Engine,
    journal: ?*journal_mod.Journal,
    max_file_read_bytes: usize,
    /// Approval callback wired to the UI; used when the engine says `ask`.
    approval_ctx: *anyopaque,
    approval_fn: *const fn (ctx: *anyopaque, req: ApprovalRequest) ApprovalResponse,

    pub fn requestApproval(self: *ToolContext, title: []const u8, detail: []const u8, grant: ApprovalRequest.Grant) bool {
        const resp = self.approval_fn(self.approval_ctx, .{ .title = title, .detail = detail, .grant = grant });
        switch (resp) {
            .approved_once, .approved_session => return true,
            .denied => return false,
        }
    }
};

pub const ToolResult = struct {
    output: []const u8,
    status: Status = .ok,
};

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// Tool specs advertised to the model (order = advertisement order).
pub const specs = [_]Spec{
    .{ .name = "read", .description = "Read a text file with line numbers. Supports offset/limit for paging.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"0-based start line"},"limit":{"type":"integer"}},"required":["path"]}
    },
    .{ .name = "glob", .description = "List files matching a glob pattern (** crosses directories, * stays within one).", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}
    },
    .{ .name = "grep", .description = "Literal substring search across repository text files.", .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"subdirectory to search"}},"required":["pattern"]}
    },
    .{ .name = "edit", .description = "Replace exactly one occurrence of old_string with new_string in a file. Refuses if the text appears zero or multiple times.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}
    },
    .{ .name = "write", .description = "Create a file or overwrite it entirely. Prefer edit for existing files.", .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
    },
    .{ .name = "bash", .description = "Run a shell command in the workspace. Read-only commands run freely; anything that changes state requires approval.", .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
    },
    .{ .name = "git", .description = "Run a git subcommand in the workspace (porcelain operations only).", .parameters_json =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"}}},"required":["args"]}
    },
};

// ---------------------------------------------------------------- helpers

fn truncateUtf8(arena: std.mem.Allocator, text: []const u8, marker: []const u8) ![]const u8 {
    if (text.len <= max_tool_output_bytes) return text;
    var end = max_tool_output_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\n...[{s}: {d} bytes truncated]\n", .{ text[0..end], marker, text.len - end });
}

fn errResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ToolResult {
    const msg = std.fmt.allocPrint(arena, "error: " ++ fmt, args) catch "error: out of memory";
    return .{ .output = msg, .status = .failed };
}

fn deniedResult(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ToolResult {
    const msg = std.fmt.allocPrint(arena, "permission denied: " ++ fmt, args) catch "permission denied";
    return .{ .output = msg, .status = .denied };
}

const Args = struct {
    obj: std.json.ObjectMap,

    fn str(self: Args, key: []const u8) ?[]const u8 {
        const v = self.obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn int(self: Args, key: []const u8) ?usize {
        const v = self.obj.get(key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0) @as(usize, @intCast(i)) else null,
            else => null,
        };
    }
};

/// Dispatch a tool call by name. `args_json` must be a JSON object.
pub fn execute(name: []const u8, args_json: []const u8, ctx: *ToolContext) ToolResult {
    const V = std.json.Value;
    const args: V = std.json.parseFromSliceLeaky(V, ctx.arena, args_json, .{}) catch
        return errResult(ctx.arena, "invalid JSON arguments", .{});
    if (args != .object) return errResult(ctx.arena, "arguments must be a JSON object", .{});
    const a = Args{ .obj = args.object };

    if (std.mem.eql(u8, name, "read")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "read: missing path", .{});
        return toolRead(path, a.int("offset"), a.int("limit"), ctx);
    } else if (std.mem.eql(u8, name, "glob")) {
        const pattern = a.str("pattern") orelse return errResult(ctx.arena, "glob: missing pattern", .{});
        return toolGlob(pattern, ctx);
    } else if (std.mem.eql(u8, name, "grep")) {
        const pattern = a.str("pattern") orelse return errResult(ctx.arena, "grep: missing pattern", .{});
        const root = a.str("path") orelse "";
        return toolGrep(pattern, root, ctx);
    } else if (std.mem.eql(u8, name, "edit")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "edit: missing path", .{});
        const old_s = a.str("old_string") orelse return errResult(ctx.arena, "edit: missing old_string", .{});
        const new_s = a.str("new_string") orelse return errResult(ctx.arena, "edit: missing new_string", .{});
        return toolEdit(path, old_s, new_s, ctx);
    } else if (std.mem.eql(u8, name, "write")) {
        const path = a.str("path") orelse return errResult(ctx.arena, "write: missing path", .{});
        const content = a.str("content") orelse return errResult(ctx.arena, "write: missing content", .{});
        return toolWrite(path, content, ctx);
    } else if (std.mem.eql(u8, name, "bash")) {
        const command = a.str("command") orelse return errResult(ctx.arena, "bash: missing command", .{});
        return toolBash(command, ctx);
    } else if (std.mem.eql(u8, name, "git")) {
        const args_v = a.obj.get("args") orelse return errResult(ctx.arena, "git: missing args", .{});
        if (args_v != .array) return errResult(ctx.arena, "git: args must be an array of strings", .{});
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        argv.append(ctx.arena, "git") catch return errResult(ctx.arena, "oom", .{});
        for (args_v.array.items) |item| {
            if (item != .string) return errResult(ctx.arena, "git: args must be strings", .{});
            argv.append(ctx.arena, item.string) catch return errResult(ctx.arena, "oom", .{});
        }
        return toolGit(argv.items, ctx);
    }
    return errResult(ctx.arena, "unknown tool '{s}'", .{name});
}

// ---------------------------------------------------------------- read

fn toolRead(path: []const u8, offset: ?usize, limit: ?usize, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, path)) {
        .allow => {},
        .ask => return deniedResult(ctx.arena, "read '{s}' not covered by read policy", .{path}),
        .deny => return deniedResult(ctx.arena, "read '{s}'", .{path}),
    }
    const stat = ctx.workspace.statFile(ctx.io, path, .{}) catch
        return errResult(ctx.arena, "read: cannot stat '{s}'", .{path});
    if (stat.kind == .directory) return errResult(ctx.arena, "read: '{s}' is a directory", .{path});

    const cap = ctx.max_file_read_bytes;
    const data = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(cap)) catch |err| switch (err) {
        error.StreamTooLong => return errResult(ctx.arena, "read: '{s}' exceeds {d} byte cap; use offset/limit paging", .{ path, cap }),
        else => return errResult(ctx.arena, "read: cannot read '{s}': {s}", .{ path, @errorName(err) }),
    };

    const start_line: usize = offset orelse 0;
    var max_lines: usize = limit orelse 2000;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < start_line) continue;
        if (max_lines == 0) {
            // Only mention truncation when real content remains.
            var more = false;
            if (line.len > 0) more = true else {
                var rest = it;
                while (rest.next()) |l2| {
                    if (l2.len > 0) {
                        more = true;
                        break;
                    }
                }
            }
            if (more) out.appendSlice(ctx.arena, "...[more lines; call read again with offset]") catch {};
            break;
        }
        out.print(ctx.arena, "{d: >6}| {s}\n", .{ line_no + 1, std.mem.trimEnd(u8, line, "\r") }) catch {};
        max_lines -= 1;
    }
    const body = truncateUtf8(ctx.arena, out.items, "read output truncated") catch out.items;
    return .{ .output = body, .status = .ok };
}

// ---------------------------------------------------------------- filesystem walk

const WalkLimits = struct {
    max_files: usize = 20_000,
    max_depth: usize = 16,
    max_matches: usize = 500,
};

const skip_dirs = [_][]const u8{
    ".git",        "node_modules", "zig-cache", "zig-out", ".ifnh/sessions",
    ".ifnh/cache", "__pycache__",  "target",    "dist",    "build",
};

fn shouldSkipDir(rel: []const u8) bool {
    for (skip_dirs) |sd| {
        if (std.mem.eql(u8, rel, sd)) return true;
        if (std.mem.endsWith(u8, rel, sd) and
            (rel.len == sd.len or rel[rel.len - sd.len - 1] == '/')) return true;
    }
    return false;
}

fn collectMatching(
    ctx: *ToolContext,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: usize,
    limits: *WalkLimits,
    out: *std.ArrayListUnmanaged([]const u8),
    pattern: []const u8,
) void {
    if (depth > limits.max_depth or out.items.len >= limits.max_matches or limits.max_files == 0) return;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (out.items.len >= limits.max_matches or limits.max_files == 0) return;
        const child_rel = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ rel_prefix, entry.name }) catch return;
        limits.max_files -|= 1;
        if (entry.kind == .directory) {
            if (shouldSkipDir(child_rel)) continue;
            const sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(ctx.io);
            const next_prefix = std.fmt.allocPrint(ctx.arena, "{s}/", .{child_rel}) catch return;
            collectMatching(ctx, sub, next_prefix, depth + 1, limits, out, pattern);
        } else if (globm.match(pattern, child_rel)) {
            out.append(ctx.arena, child_rel) catch return;
        }
    }
}

fn toolGlob(pattern: []const u8, ctx: *ToolContext) ToolResult {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var limits = WalkLimits{};
    collectMatching(ctx, ctx.workspace, "", 0, &limits, &out, pattern);
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    const body = std.mem.join(ctx.arena, "\n", out.items) catch return errResult(ctx.arena, "oom", .{});
    return .{ .output = truncateUtf8(ctx.arena, body, "glob results") catch body, .status = .ok };
}

// ---------------------------------------------------------------- grep

fn toolGrep(pattern: []const u8, root: []const u8, ctx: *ToolContext) ToolResult {
    switch (ctx.engine.decidePath(.read, root)) {
        .allow => {},
        else => return deniedResult(ctx.arena, "grep under '{s}'", .{root}),
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var limits = WalkLimits{ .max_matches = 200 };
    grepDir(ctx, ctx.workspace, root, pattern, &limits, &out, 0);
    if (out.items.len == 0) return .{ .output = "no matches", .status = .ok };
    return .{ .output = truncateUtf8(ctx.arena, out.items, "grep results") catch out.items, .status = .ok };
}

fn grepDir(
    ctx: *ToolContext,
    dir: std.Io.Dir,
    rel: []const u8,
    pattern: []const u8,
    limits: *WalkLimits,
    out: *std.ArrayListUnmanaged(u8),
    depth: usize,
) void {
    if (depth > limits.max_depth or limits.max_matches == 0 or limits.max_files == 0) return;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (limits.max_matches == 0 or limits.max_files == 0) return;
        const child_rel = if (rel.len == 0)
            std.fmt.allocPrint(ctx.arena, "{s}", .{entry.name}) catch return
        else
            std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ rel, entry.name }) catch return;
        limits.max_files -|= 1;
        if (entry.kind == .directory) {
            if (shouldSkipDir(child_rel)) continue;
            const sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(ctx.io);
            grepDir(ctx, sub, child_rel, pattern, limits, out, depth + 1);
        } else {
            grepFile(ctx, child_rel, pattern, limits, out);
        }
    }
}

fn grepFile(ctx: *ToolContext, rel: []const u8, pattern: []const u8, limits: *WalkLimits, out: *std.ArrayListUnmanaged(u8)) void {
    const data = ctx.workspace.readFileAlloc(ctx.io, rel, ctx.arena, .limited(max_file_size_bytes)) catch return;
    if (!std.unicode.utf8ValidateSlice(data)) return; // skip binary
    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    var file_hits: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        if (file_hits >= 10 or limits.max_matches == 0) return;
        if (std.mem.indexOf(u8, line, pattern) != null) {
            out.print(ctx.arena, "{s}:{d}: {s}\n", .{ rel, line_no + 1, std.mem.trimEnd(u8, line, "\r") }) catch return;
            file_hits += 1;
            limits.max_matches -= 1;
        }
    }
}

// ---------------------------------------------------------------- edit / write

fn prepareWrite(ctx: *ToolContext, path: []const u8, after: []const u8) ?ToolResult {
    switch (ctx.engine.decidePath(.write, path)) {
        .allow => {},
        .ask => {
            if (!ctx.requestApproval("write file", path, .{ .path_write = path })) return deniedResult(ctx.arena, "write '{s}' (declined)", .{path});
        },
        .deny => return deniedResult(ctx.arena, "write '{s}' (protected path)", .{path}),
    }
    _ = after;
    return null;
}

fn toolEdit(path: []const u8, old_string: []const u8, new_string: []const u8, ctx: *ToolContext) ToolResult {
    if (old_string.len == 0) return errResult(ctx.arena, "edit: old_string must not be empty", .{});
    if (prepareWrite(ctx, path, new_string)) |r| return r;

    const before = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(max_file_size_bytes)) catch
        return errResult(ctx.arena, "edit: cannot read '{s}'", .{path});

    const first = std.mem.indexOf(u8, before, old_string) orelse
        return errResult(ctx.arena, "edit: old_string not found in '{s}' (file may have changed; re-read it)", .{path});
    if (std.mem.indexOf(u8, before[first + 1 ..], old_string) != null)
        return errResult(ctx.arena, "edit: old_string appears multiple times in '{s}'; provide a larger unique context", .{path});

    const after = std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{
        before[0..first],
        new_string,
        before[first + old_string.len ..],
    }) catch return errResult(ctx.arena, "oom", .{});

    commitMutation(ctx, path, before, after) catch |err|
        return errResult(ctx.arena, "edit: failed to write '{s}': {s}", .{ path, @errorName(err) });
    return .{ .output = std.fmt.allocPrint(ctx.arena, "edited {s} ({d} -> {d} bytes)", .{ path, before.len, after.len }) catch "edited", .status = .ok };
}

fn toolWrite(path: []const u8, content: []const u8, ctx: *ToolContext) ToolResult {
    if (prepareWrite(ctx, path, content)) |r| return r;

    const existing = ctx.workspace.readFileAlloc(ctx.io, path, ctx.arena, .limited(max_file_size_bytes)) catch null;
    if (existing) |before| {
        commitMutation(ctx, path, before, content) catch |err|
            return errResult(ctx.arena, "write: failed '{s}': {s}", .{ path, @errorName(err) });
    } else {
        commitMutation(ctx, path, "", content) catch |err|
            return errResult(ctx.arena, "write: failed '{s}': {s}", .{ path, @errorName(err) });
    }
    return .{ .output = std.fmt.allocPrint(ctx.arena, "wrote {s} ({d} bytes)", .{ path, content.len }) catch "wrote", .status = .ok };
}

/// Journal-integrated file mutation: intent → write → commit.
fn commitMutation(ctx: *ToolContext, path: []const u8, before: []const u8, after: []const u8) !void {
    const j = ctx.journal orelse {
        // No journal (e.g. outside a session): write directly.
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try ctx.workspace.createDirPath(ctx.io, path[0..slash]);
        }
        try ctx.workspace.writeFile(ctx.io, .{ .sub_path = path, .data = after });
        return;
    };
    const exists = blk: {
        _ = ctx.workspace.statFile(ctx.io, path, .{}) catch break :blk false;
        break :blk true;
    };
    if (exists) {
        try j.apply("file-mutation", &.{.{ .write = .{ .path = path, .before = before, .after = after } }});
    } else {
        try j.apply("file-mutation", &.{.{ .create = .{ .path = path, .after = after } }});
    }
}

// ---------------------------------------------------------------- bash / git

fn runCaptured(ctx: *ToolContext, argv: []const []const u8, cwd: []const u8) ToolResult {
    const run = std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdout_limit = .limited(max_tool_output_bytes),
        .stderr_limit = .limited(32 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(120) } },
    }) catch |err| switch (err) {
        error.Timeout => return .{ .output = "error: command timed out after 120s", .status = .timeout },
        error.FileNotFound => return errResult(ctx.arena, "command not found: {s}", .{argv[0]}),
        else => return errResult(ctx.arena, "spawn failed: {s}", .{@errorName(err)}),
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (run.stdout.len > 0) {
        out.print(ctx.arena, "<stdout>\n{s}\n</stdout>\n", .{run.stdout}) catch {};
    }
    if (run.stderr.len > 0) {
        out.print(ctx.arena, "<stderr>\n{s}\n</stderr>\n", .{run.stderr}) catch {};
    }
    switch (run.term) {
        .exited => |code| {
            if (code != 0) out.print(ctx.arena, "exit code: {d}\n", .{code}) catch {};
        },
        .signal => |sig| out.print(ctx.arena, "terminated by signal {d}\n", .{sig}) catch {},
        .stopped => |sig| out.print(ctx.arena, "stopped by signal {d}\n", .{sig}) catch {},
        .unknown => |code| out.print(ctx.arena, "exit status: {d}\n", .{code}) catch {},
    }
    const body = truncateUtf8(ctx.arena, out.items, "command output") catch out.items;
    const failed = switch (run.term) {
        .exited => |code| code != 0,
        else => true,
    };
    return .{ .output = body, .status = if (failed) .failed else .ok };
}

fn toolBash(command: []const u8, ctx: *ToolContext) ToolResult {
    // Compound commands go through the user's shell; simple ones run directly
    // (DECISIONS I120). Compound detection is the classifier's job anyway.
    const effect = cmd_class.classify(command);
    const decision = ctx.engine.decideCommand(command);
    switch (decision) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "command '{s}'", .{command}),
        .ask => {
            const grant_prefix = commandPrefixOf(command);
            if (!ctx.requestApproval("run command", command, .{ .command_prefix = grant_prefix }))
                return deniedResult(ctx.arena, "command '{s}' (declined)", .{command});
        },
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.mem.indexOfAny(u8, command, "|;&<>()`") != null) {
        const shell = ctx.engine.alloc.dupe(u8, "/bin/sh") catch return errResult(ctx.arena, "oom", .{});
        const flag = ctx.engine.alloc.dupe(u8, "-c") catch return errResult(ctx.arena, "oom", .{});
        const cmd = ctx.engine.alloc.dupe(u8, command) catch return errResult(ctx.arena, "oom", .{});
        argv.append(ctx.arena, shell) catch {};
        argv.append(ctx.arena, flag) catch {};
        argv.append(ctx.arena, cmd) catch {};
    } else {
        var it = std.mem.tokenizeAny(u8, command, " \t");
        while (it.next()) |tok| {
            argv.append(ctx.arena, tok) catch {};
        }
    }
    if (argv.items.len == 0) return errResult(ctx.arena, "bash: empty command", .{});

    const result = runCaptured(ctx, argv.items, "");
    // Note: shell side effects are not journaled (M185); surfaced in audit log instead.
    _ = effect;
    return result;
}

/// "git commit -m x" -> "git commit"; "ls" -> "ls".
fn commandPrefixOf(command: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = it.next() orelse return command;
    const second = it.next() orelse return first;
    const start = second.ptr - command.ptr;
    return command[0 .. start + second.len];
}

fn toolGit(argv: []const []const u8, ctx: *ToolContext) ToolResult {
    // Reconstruct command line for classification/permission.
    const command = std.mem.join(ctx.arena, " ", argv) catch return errResult(ctx.arena, "oom", .{});
    switch (ctx.engine.decideCommand(command)) {
        .allow => {},
        .deny => return deniedResult(ctx.arena, "git command '{s}'", .{command}),
        .ask => {
            const grant_prefix = commandPrefixOf(command);
            if (!ctx.requestApproval("run git", command, .{ .command_prefix = grant_prefix }))
                return deniedResult(ctx.arena, "git command '{s}' (declined)", .{command});
        },
    }
    return runCaptured(ctx, argv, "");
}

// ---------------------------------------------------------------- tests

fn testCtx(arena: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, e: *engine_mod.Engine) ToolContext {
    return .{
        .io = io,
        .arena = arena,
        .workspace = ws,
        .engine = e,
        .journal = null,
        .max_file_read_bytes = 256 * 1024,
        .approval_ctx = undefined,
        .approval_fn = struct {
            fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
                return .approved_once;
            }
        }.approve,
    };
}

fn makeTmp() !std.testing.TmpDir {
    return std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
}

test "read tool with line numbers and paging" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\ngamma\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("read", "{\"path\":\"f.txt\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "1| alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "3| gamma") != null);

    const r2 = execute("read", "{\"path\":\"f.txt\",\"offset\":1,\"limit\":1}", &ctx);
    try std.testing.expectEqualStrings("     2| beta\n...[more lines; call read again with offset]", r2.output);

    const r3 = execute("read", "{\"path\":\"missing.txt\"}", &ctx);
    try std.testing.expectEqual(Status.failed, r3.status);
}

test "glob and grep tools" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const needle = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/b.zig", .data = "const needle = 2;\nconst other = 3;\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const g = execute("glob", "{\"pattern\":\"src/**/*.zig\"}", &ctx);
    try std.testing.expectEqual(Status.ok, g.status);
    try std.testing.expect(std.mem.indexOf(u8, g.output, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, g.output, "src/deep/b.zig") != null);

    const gr = execute("grep", "{\"pattern\":\"needle\"}", &ctx);
    try std.testing.expectEqual(Status.ok, gr.status);
    try std.testing.expect(std.mem.indexOf(u8, gr.output, "src/a.zig:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, gr.output, "src/deep/b.zig:1") != null);
}

test "edit and write with journal integration" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "code.zig", .data = "const x = 1;\n" });

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const w = execute("write", "{\"path\":\"new.txt\",\"content\":\"hello new\\n\"}", &ctx);
    try std.testing.expectEqual(Status.ok, w.status);

    const r = execute("edit", "{\"path\":\"code.zig\",\"old_string\":\"const x = 1;\",\"new_string\":\"const x = 2;\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    const data = try tmp.dir.readFileAlloc(io, "code.zig", arena_state.allocator(), .limited(1024));
    try std.testing.expectEqualStrings("const x = 2;\n", data);

    // Ambiguity refused.
    try tmp.dir.writeFile(io, .{ .sub_path = "dup.txt", .data = "aa aa" });
    const dup = execute("edit", "{\"path\":\"dup.txt\",\"old_string\":\"aa\",\"new_string\":\"bb\"}", &ctx);
    try std.testing.expectEqual(Status.failed, dup.status);
    try std.testing.expect(std.mem.indexOf(u8, dup.output, "multiple times") != null);

    // Staleness refused.
    const stale = execute("edit", "{\"path\":\"code.zig\",\"old_string\":\"const x = 1;\",\"new_string\":\"zz\"}", &ctx);
    try std.testing.expectEqual(Status.failed, stale.status);
    try std.testing.expect(std.mem.indexOf(u8, stale.output, "not found") != null);
}

test "write denied on protected path without approval escape" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"**"};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("write", "{\"path\":\".ifnh/config.json\",\"content\":\"{}\"}", &ctx);
    try std.testing.expectEqual(Status.denied, r.status);
}

test "bash tool runs read-only commands without approval" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    const r = execute("bash", "{\"command\":\"echo hello-ifnh\"}", &ctx);
    try std.testing.expectEqual(Status.ok, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hello-ifnh") != null);
}

test "bash tool asks for write commands and honors denial" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();

    const Denier = struct {
        fn approve(_: *anyopaque, _: ApprovalRequest) ApprovalResponse {
            return .denied;
        }
    };
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);
    ctx.approval_fn = Denier.approve;

    const r = execute("bash", "{\"command\":\"mkdir newdir\"}", &ctx);
    try std.testing.expectEqual(Status.denied, r.status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "newdir", .{}));
}

test "unknown tool and bad args" {
    const io = std.testing.io;
    var tmp = try makeTmp();
    defer tmp.cleanup();
    var e = engine_mod.Engine.init(std.testing.allocator, .ask);
    defer e.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = testCtx(arena_state.allocator(), io, tmp.dir, &e);

    try std.testing.expectEqual(Status.failed, execute("frobnicate", "{}", &ctx).status);
    try std.testing.expectEqual(Status.failed, execute("read", "not json", &ctx).status);
    try std.testing.expectEqual(Status.failed, execute("read", "{\"other\":1}", &ctx).status);
}
