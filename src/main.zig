//! IFNH — composition root (fx convention: thin entry, no leaf feature logic).
//!
//! Responsibilities here and only here:
//!   1. Parse the subcommand.
//!   2. Print help/version fast paths.
//!   3. Dispatch to command implementations (added as milestones land).

const std = @import("std");
const version = @import("version.zig");
const cli_args = @import("cli/args.zig");
const fsutil = @import("core/fsutil.zig");
const repl = @import("cli/repl.zig");
const session_mod = @import("core/session/store.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    // Collect argv (skip argv[0]).
    var argv: std.ArrayList([]const u8) = .empty;
    var iter = init.minimal.args.iterate();
    var first = true;
    while (iter.next()) |arg| {
        if (first) {
            first = false;
            continue;
        }
        try argv.append(arena, try arena.dupe(u8, arg));
    }

    const parsed = cli_args.parse(argv.items) catch |err| {
        try printOut(io, arena, "error: bad arguments: {s}\n(run `ifnh help` for usage)\n", .{@errorName(err)});
        std.process.exit(2);
    };

    if (parsed.flags.version or parsed.subcommand == .version) {
        try printOut(io, arena, "ifnh {s}\n", .{version.version});
        return;
    }
    if (parsed.flags.help or parsed.subcommand == .help) {
        try printOut(io, arena, help_text, .{version.version});
        return;
    }
    if (parsed.subcommand == .none) {
        try repl.run(io, arena, init.environ_map, .{});
        return;
    }

    switch (parsed.subcommand) {
        .init => try runInit(io, arena, parsed.args),
        .config => try runConfig(io, arena, init.environ_map, parsed.args),
        .sessions => try runSessions(io, arena, parsed.args),
        .@"resume" => blk: {
            if (parsed.args.len == 0) {
                try printOut(io, arena, "usage: ifnh resume <session-id> (see `ifnh sessions list`)\n", .{});
                std.process.exit(2);
            }
            break :blk try repl.run(io, arena, init.environ_map, .{ .resume_id = parsed.args[0] });
        },
        .doctor => try printOut(io, arena, "doctor: not yet implemented (tracker M1-T14)\n", .{}),
        .unknown => {
            try printOut(io, arena, "error: unknown subcommand '{s}'\n(run `ifnh help` for usage)\n", .{parsed.args[0]});
            std.process.exit(2);
        },
        else => unreachable,
    }
}

/// `ifnh config [validate|explain <key>|path]`
fn runConfig(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
    const config_mod = @import("core/config/config.zig");
    var cfg = try config_mod.load(arena, io, environ, std.Io.Dir.cwd());
    defer cfg.deinit();

    if (args.len == 0 or std.mem.eql(u8, args[0], "validate")) {
        if (cfg.errors.items.len == 0) {
            try printOut(io, arena, "config valid\n", .{});
        }
        for (cfg.errors.items) |e| try printOut(io, arena, "error [{s}]: {s}\n", .{ e.path, e.message });
        for (cfg.warnings.items) |w| try printOut(io, arena, "warning: {s}\n", .{w});
        if (cfg.errors.items.len > 0) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, args[0], "explain")) {
        if (args.len < 2) {
            try printOut(io, arena, "usage: ifnh config explain <dotted.key>\n", .{});
            std.process.exit(2);
        }
        const key = args[1];
        const v = cfg.get(key) orelse {
            try printOut(io, arena, "{s}: <unset> (no default)\n", .{key});
            return;
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(v, .{}, &aw.writer);
        const src_info = cfg.getSource(key);
        try printOut(io, arena, "{s} = {s}\n  layer: {s}\n  source: {s}\n", .{
            key,
            aw.written(),
            if (src_info) |s| s.layer.name() else "builtin",
            if (src_info) |s| s.origin else "defaults",
        });
        return;
    }
    try printOut(io, arena, "usage: ifnh config [validate|explain <key>]\n", .{});
}

/// `ifnh sessions list`
fn runSessions(io: std.Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const summaries = session_mod.list(std.Io.Dir.cwd(), io, arena, ".ifnh/sessions") catch &.{};
        if (summaries.len == 0) {
            try printOut(io, arena, "no sessions\n", .{});
            return;
        }
        for (summaries) |s| {
            try printOut(io, arena, "{s}  created={d}  cwd={s}\n", .{ s.id, s.created_ms, s.cwd });
        }
        return;
    }
    try printOut(io, arena, "usage: ifnh sessions [list]\n", .{});
}

/// `ifnh init` — create the .ifnh/ skeleton (tracker M0-T38; minimal now).
fn runInit(io: std.Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    const cwd = std.Io.Dir.cwd();

    if (fsutil.fileExists(cwd, io, ".ifnh")) {
        try printOut(io, arena, ".ifnh/ already exists; leaving it untouched\n", .{});
        return;
    }
    try fsutil.ensureDirPath(cwd, io, ".ifnh/skills");
    try fsutil.ensureDirPath(cwd, io, ".ifnh/commands");
    try fsutil.ensureDirPath(cwd, io, ".ifnh/instructions");
    try fsutil.ensureDirPath(cwd, io, ".ifnh/plans");

    const starter_config =
        \\
        \\{
        \\  "schema_version": 1,
        \\  "permissions": { "default_mode": "ask" }
        \\}
        \\
    ;
    try fsutil.atomicWriteFile(cwd, io, arena, ".ifnh/config.json", starter_config);

    const gitignore =
        \\sessions/
        \\cache/
        \\debug/
        \\reports/
        \\
    ;
    try fsutil.atomicWriteFile(cwd, io, arena, ".ifnh/.gitignore", gitignore);

    try printOut(io, arena,
        \\created .ifnh/ (config.json, skills/, commands/, instructions/, plans/)
        \\next: set a provider key (e.g. IFNH model config or ANTHROPIC_API_KEY) and run `ifnh`
        \\
    , .{});
}

fn printOut(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var stack_buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&stack_buf, fmt, args) catch
        try std.fmt.allocPrint(alloc, fmt, args); // arena-owned; freed at process exit
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

const help_text =
    \\ifnh {s} — a tiny, fast, developer-controlled agentic coding harness.
    \\
    \\usage: ifnh [global-flags] <subcommand> [args...]
    \\
    \\subcommands:
    \\  (none)      start an interactive session (M0)
    \\  init        create a .ifnh/ project skeleton
    \\  config      validate/explain configuration (M0)
    \\  sessions    list recorded sessions (M0)
    \\  resume      resume a previous session (M0)
    \\  doctor      check environment health (M1)
    \\  help        show this text
    \\  version     print version
    \\
    \\global flags:
    \\  --json                  machine-readable output
    \\  --no-color              disable color
    \\  --log-level <level>     err | info | debug | trace
    \\  -h, --help              show help
    \\  -V, --version           print version
    \\
;

test {
    _ = @import("version.zig");
    _ = @import("core/types.zig");
    _ = @import("core/fsutil.zig");
    _ = @import("cli/args.zig");
    _ = @import("core/config/config.zig");
    _ = @import("core/session/store.zig");
    _ = @import("core/journal.zig");
    _ = @import("core/permissions/glob.zig");
    _ = @import("core/permissions/command_class.zig");
    _ = @import("core/permissions/engine.zig");
    _ = @import("tools/tool.zig");
    _ = @import("providers/provider.zig");
    _ = @import("providers/sse.zig");
    _ = @import("providers/openai.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("core/instructions.zig");
    _ = @import("core/agent/engine.zig");
    _ = @import("core/agent/testing.zig");
    _ = @import("core/agent/subagent.zig");
    _ = @import("core/git.zig");
    _ = @import("core/mcp.zig");
    _ = @import("core/skills.zig");
    _ = @import("core/agent/system_prompt.zig");
    _ = @import("cli/repl.zig");
    _ = @import("core/redact.zig");
    _ = @import("providers/testing.zig");
}
