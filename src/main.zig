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
const config_mod = @import("core/config/config.zig");

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
        repl.run(io, arena, init.environ_map, .{ .no_color = parsed.flags.no_color }) catch |err| {
            if (err == error.AccessDenied) {
                try printOut(io, arena, "error: permission denied\n" ++
                    "ifnh needs to write .ifnh/ in the current directory.\n" ++
                    "Is '{s}' writable by you? (check ownership with 'ls -ld')\n" ++
                    "Run ifnh from a directory you own, or fix ownership:\n" ++
                    "  sudo chown -R $(whoami) <directory>\n", .{cwdPath(arena, init.environ_map)});
            } else {
                try printOut(io, arena, "error: {s}\n(run 'ifnh doctor' for diagnostics)\n", .{@errorName(err)});
            }
            std.process.exit(1);
        };
        return;
    }

    dispatch(io, arena, init.environ_map, parsed) catch |err| {
        if (err == error.AccessDenied) {
            try printOut(io, arena, "error: permission denied\n" ++
                "ifnh writes its state (.ifnh/) in the current directory.\n" ++
                "'{s}' is not writable by you — run ifnh from a directory\n" ++
                "you own, or fix ownership:\n" ++
                "  sudo chown -R $(whoami) <directory>\n" ++
                "(note: do not run ifnh itself under sudo)\n", .{cwdPath(arena, init.environ_map)});
        } else {
            try printOut(io, arena, "error: {s}\n(run 'ifnh doctor' for diagnostics)\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn dispatch(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    parsed: cli_args.Parsed,
) !void {
    const io_arg = io;
    _ = io_arg;
    switch (parsed.subcommand) {
        .none => {
            try repl.run(io, arena, environ, .{ .no_color = parsed.flags.no_color });
            return;
        },
        .init => try runInit(io, arena, parsed.args),
        .config => try runConfig(io, arena, environ, parsed.args),
        .sessions => try runSessions(io, arena, parsed.args),
        .fork => blk: {
            if (parsed.args.len >= 3 and std.mem.eql(u8, parsed.args[0], "diff")) {
                break :blk try runForkDiff(io, arena, parsed.args[1..]);
            }
            break :blk try runFork(io, arena, parsed.args);
        },
        .cleanup => try runCleanup(io, arena, environ, parsed.args),
        .@"resume" => blk: {
            if (parsed.args.len == 0) {
                try printOut(io, arena, "usage: ifnh resume <session-id> (see `ifnh sessions list`)\n", .{});
                std.process.exit(2);
            }
            break :blk try repl.run(io, arena, environ, .{
                .resume_id = parsed.args[0],
                .no_color = parsed.flags.no_color,
            });
        },
        .doctor => try runDoctor(io, arena, environ),
        .unknown => {
            try printOut(io, arena, "error: unknown subcommand '{s}'\n(run `ifnh help` for usage)\n", .{parsed.args[0]});
            std.process.exit(2);
        },
        else => unreachable,
    }
}

/// `ifnh config [validate|explain <key>|path]`
fn runConfig(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
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
        const json_mode = args.len > 1 and std.mem.eql(u8, args[1], "--json");
        const summaries = session_mod.list(std.Io.Dir.cwd(), io, arena, ".ifnh/sessions") catch &.{};
        if (json_mode) {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try aw.writer.writeByte('[');
            for (summaries, 0..) |s, i| {
                if (i > 0) try aw.writer.writeByte(',');
                try aw.writer.writeAll("{\"id\":\"");
                try aw.writer.writeAll(s.id);
                try aw.writer.print("\",\"created_ms\":{d},\"cwd\":", .{s.created_ms});
                try std.json.Stringify.value(s.cwd, .{}, &aw.writer);
                if (s.title) |t| {
                    try aw.writer.writeAll(",\"title\":");
                    try std.json.Stringify.value(t, .{}, &aw.writer);
                }
                try aw.writer.writeAll("}");
            }
            try aw.writer.writeByte(']');
            try printOut(io, arena, "{s}\n", .{aw.written()});
            return;
        }
        if (summaries.len == 0) {
            try printOut(io, arena, "no sessions\n", .{});
            return;
        }
        for (summaries) |s| {
            try printOut(io, arena, "{s}  created={d}  cwd={s}\n", .{ s.id, s.created_ms, s.cwd });
        }
        return;
    }
    try printOut(io, arena, "usage: ifnh sessions [list] [--json]\n", .{});
}

/// `ifnh fork <session-id>` — branch a session from its current state (M2-T05, A11).
fn runFork(io: std.Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printOut(io, arena, "usage: ifnh fork <session-id>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var parent = try session_mod.Session.open(cwd, io, arena, ".ifnh/sessions", args[0]);
    defer parent.close();
    var child = try parent.fork();
    defer child.close();
    try printOut(io, arena, "forked {s} -> {s} ({d} events inherited)\n", .{ parent.manifest.id, child.manifest.id, child.seq });
}

/// `ifnh fork diff <a> <b>` — side-by-side comparison (M2-T05, A12).
fn runForkDiff(io: std.Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try printOut(io, arena, "usage: ifnh fork diff <session-a> <session-b>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var a = try session_mod.Session.openReadOnly(cwd, io, arena, ".ifnh/sessions", args[0]);
    defer a.close();
    var b = try session_mod.Session.openReadOnly(cwd, io, arena, ".ifnh/sessions", args[1]);
    defer b.close();

    const events_a = try a.readEvents(arena, 10_000);
    const events_b = try b.readEvents(arena, 10_000);

    try printOut(io, arena, "session A: {s} ({d} events, fork_of {s})\n", .{ a.manifest.id, events_a.len, a.manifest.fork_of orelse "-" });
    try printOut(io, arena, "session B: {s} ({d} events, fork_of {s})\n", .{ b.manifest.id, events_b.len, b.manifest.fork_of orelse "-" });

    // Common prefix length.
    var common: usize = 0;
    while (common < events_a.len and common < events_b.len) {
        if (events_a[common].seq != events_b[common].seq) break;
        common += 1;
    }
    try printOut(io, arena, "common history: {d} events (diverge after seq {d})\n", .{ common, common });

    // Last assistant text per side.
    for ([_]struct { label: []const u8, evs: []session_mod.Record }{ .{ .label = "A", .evs = events_a }, .{ .label = "B", .evs = events_b } }) |side| {
        var i = side.evs.len;
        while (i > 0) {
            i -= 1;
            switch (side.evs[i].event) {
                .assistant => |v| {
                    const max: usize = 200;
                    try printOut(io, arena, "last assistant ({s}): {s}{s}\n", .{
                        side.label,
                        v.text[0..@min(v.text.len, max)],
                        if (v.text.len > max) "..." else "",
                    });
                    break;
                },
                else => {},
            }
        }
    }
    _ = args.len;
}

/// `ifnh cleanup [--yes]` — retention enforcement (M2-T06, A13).
/// Removes sessions beyond sessions.keep and orphaned IFNH-created
/// worktrees (with --yes; otherwise lists what it would do).
fn runCleanup(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
    var assume_yes = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) assume_yes = true;
    }
    const cwd = std.Io.Dir.cwd();
    var cfg = try config_mod.load(arena, io, null, cwd);
    defer cfg.deinit();
    const keep: usize = cfg.getU32("sessions.keep", 30);

    // Sessions past retention.
    const summaries = try session_mod.list(cwd, io, arena, ".ifnh/sessions");
    if (summaries.len > keep) {
        try printOut(io, arena, "sessions: {d} exist, retention {d}\n", .{ summaries.len, keep });
        for (summaries[keep..]) |s| {
            if (assume_yes) {
                // s.id is "s_xxx"; deleteTree the session dir.
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const rel = std.fmt.bufPrint(&path_buf, ".ifnh/sessions/{s}", .{s.id}) catch continue;
                cwd.deleteTree(io, rel) catch |err| {
                    try printOut(io, arena, "  failed to remove {s}: {s}\n", .{ s.id, @errorName(err) });
                    continue;
                };
                try printOut(io, arena, "  removed {s}\n", .{s.id});
            } else {
                try printOut(io, arena, "  would remove {s} (run with --yes)\n", .{s.id});
            }
        }
    } else {
        try printOut(io, arena, "sessions: {d} exist, within retention {d}\n", .{ summaries.len, keep });
    }

    // Orphaned IFNH worktrees (never auto-removed without --yes; A13).
    const home = environ.get("HOME") orelse "";
    if (home.len > 0) {
        const wt_root = try std.fmt.allocPrint(arena, "{s}/.local/state/ifnh/worktrees", .{home});
        var wt_dir = cwd.openDir(io, wt_root, .{ .iterate = true }) catch {
            try printOut(io, arena, "worktrees: none\n", .{});
            return;
        };
        defer wt_dir.close(io);
        var it = wt_dir.iterate();
        var found: usize = 0;
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.name, "ifnh-")) continue;
            found += 1;
            if (assume_yes) {
                var pbuf: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ wt_root, entry.name }) catch continue;
                cwd.deleteTree(io, full) catch continue;
                try printOut(io, arena, "  removed worktree {s}\n", .{entry.name});
            } else {
                try printOut(io, arena, "  worktree present: {s} (--yes to remove)\n", .{entry.name});
            }
        }
        if (found == 0) try printOut(io, arena, "worktrees: none\n", .{});
    }
}

/// `ifnh doctor` — environment health check (M1-T14, DECISIONS S259).
fn runDoctor(io: std.Io, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !void {
    const git_mod = @import("core/git.zig");
    const cwd = std.Io.Dir.cwd();
    var problems: usize = 0;

    try printOut(io, arena, "ifnh doctor\n", .{});

    // Config.
    var cfg = try config_mod.load(arena, io, environ, cwd);
    defer cfg.deinit();
    if (cfg.errors.items.len == 0) {
        try printOut(io, arena, "  config: ok\n", .{});
    } else {
        problems += cfg.errors.items.len;
        for (cfg.errors.items) |e| try printOut(io, arena, "  config: ERROR [{s}] {s}\n", .{ e.path, e.message });
    }
    for (cfg.warnings.items) |w| try printOut(io, arena, "  config: warning {s}\n", .{w});

    // Model/provider.
    const provider_name = cfg.getString("model.provider", "openai");
    const is_anthropic = std.mem.eql(u8, provider_name, "anthropic");
    const key_env = cfg.getOptionalString("model.api_key_env") orelse
        (if (is_anthropic) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
    const has_key = environ.get(key_env) != null;
    const has_model = cfg.getString("model.model", "").len > 0;
    if (has_key and has_model) {
        try printOut(io, arena, "  provider: ok ({s}/{s}, key from {s})\n", .{ provider_name, cfg.getString("model.model", ""), key_env });
    } else {
        problems += 1;
        if (!has_model) try printOut(io, arena, "  provider: model.model not set (IFNH_MODEL__MODEL or .ifnh/config.json)\n", .{});
        if (!has_key) try printOut(io, arena, "  provider: {s} not set in environment\n", .{key_env});
    }

    // Git.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.realPath(io, &path_buf) catch 0;
    if (n > 0) {
        const g = git_mod.Git.init(io, arena.dupe(u8, path_buf[0..n]) catch "");
        if (g.isRepo(arena)) {
            const dirty = g.dirtyCount(arena);
            try printOut(io, arena, "  git: repository, branch {s}, {d} uncommitted changes\n", .{ g.currentBranch(arena), dirty });
        } else {
            try printOut(io, arena, "  git: not a repository (worktree isolation unavailable)\n", .{});
        }
    }

    // MCP.
    const mcp_mod = @import("core/mcp.zig");
    var reg = try mcp_mod.Registry.init(io, arena, cfg.get("mcp_servers"));
    defer reg.deinit();
    try printOut(io, arena, "  mcp: {d} servers configured\n", .{reg.configs.len});

    // Session dir writability.
    cwd.createDirPath(io, ".ifnh/sessions") catch {
        problems += 1;
        try printOut(io, arena, "  state: cannot create .ifnh/sessions (read-only checkout?)\n", .{});
        return;
    };
    try printOut(io, arena, "  state: .ifnh/sessions writable\n", .{});

    if (problems > 0) {
        try printOut(io, arena, "{d} problem(s) found\n", .{problems});
        std.process.exit(1);
    }
    try printOut(io, arena, "all checks passed\n", .{});
}

/// `ifnh init` — create the .ifnh/ skeleton (tracker M0-T38; minimal now).
/// Current working directory for diagnostics (best effort; AT_FDCWD
/// cannot be realPath'd, so use $PWD like the session code).
fn cwdPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) []const u8 {
    _ = arena;
    return environ.get("PWD") orelse "<unknown>";
}

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
    \\  sessions    list recorded sessions (--json supported)
    \\  fork        branch a session (ifnh fork <id>); 'ifnh fork diff <a> <b>' compares
    \\  cleanup     enforce retention, list/remove worktrees
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
    _ = @import("core/hooks.zig");
    _ = @import("core/compaction.zig");
    _ = @import("core/lifecycle.zig");
    _ = @import("core/executions.zig");
    _ = @import("ui/style.zig");
    _ = @import("ui/secret.zig");
    _ = @import("providers/models.zig");
    _ = @import("core/config/keys.zig");
    _ = @import("core/agent/system_prompt.zig");
    _ = @import("cli/repl.zig");
    _ = @import("core/redact.zig");
    _ = @import("providers/testing.zig");
}
