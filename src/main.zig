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
const ask_mod = @import("cli/ask.zig");
const session_mod = @import("core/session/store.zig");
const config_mod = @import("core/config/config.zig");
const config_schema = @import("core/config/schema.zig");
const trace_mod = @import("core/trace.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    // The trace must start before argument parsing so startup.first_paint
    // measures from process start (B-01).
    var startup_trace = trace_mod.Trace.init(io, init.environ_map);

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
        try printErr(io, arena, "error: bad arguments: {s}\n(run `ifnh help` for usage)\n", .{@errorName(err)});
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
    // Headless one-shot: `ifnh ask "<prompt>"` or the `-p` shorthand
    // (`ifnh -p "<prompt>"`). Both land in the same driver, and the exit
    // code is the driver's own (0/1/2/3/4/130), not the generic failure path.
    if (parsed.subcommand == .ask or (parsed.subcommand == .none and parsed.flags.prompt != null)) {
        var ask = cli_args.parseAsk(parsed.args) catch |err| {
            try printErr(io, arena, "error: bad arguments: {s}\n(run `ifnh help` for usage)\n", .{@errorName(err)});
            std.process.exit(2);
        };
        // A `-p` before the subcommand is the prompt when `ask` did not give
        // one; an explicit `ask -` still means stdin.
        ask.prompt = cli_args.resolveAskPrompt(parsed.flags.prompt, ask);
        std.process.exit(ask_mod.run(io, arena, init.environ_map, parsed.flags, ask));
    }

    if (parsed.subcommand == .none) {
        repl.run(io, arena, init.environ_map, .{
            .no_color = parsed.flags.no_color,
            .trace = &startup_trace,
            .profile = parsed.flags.profile,
            .overrides = parsed.flags.overrideList(),
        }) catch |err| {
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
            try repl.run(io, arena, environ, .{
                .no_color = parsed.flags.no_color,
                .profile = parsed.flags.profile,
                .overrides = parsed.flags.overrideList(),
            });
            return;
        },
        .init => try runInit(io, arena, parsed.args),
        .config => try runConfig(io, arena, environ, parsed.flags, parsed.args),
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
                .profile = parsed.flags.profile,
                .overrides = parsed.flags.overrideList(),
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

/// `ifnh config <validate|explain|path|get|set|edit|schema>` (D-06).
///
/// `get` reads the merged tree (all layers); `set`/`edit` touch exactly one
/// file (`--project` by default, `--global` for the user config) and validate
/// before writing, so a typo can never poison startup.
fn runConfig(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    flags: cli_args.GlobalFlags,
    args: []const []const u8,
) !void {
    const sub = if (args.len == 0) "validate" else args[0];
    const tail = if (args.len == 0) args else args[1..];

    if (std.mem.eql(u8, sub, "schema")) {
        try printOut(io, arena, "{s}\n", .{config_schema.json_schema});
        return;
    }
    if (std.mem.eql(u8, sub, "path")) {
        const user_path = config_mod.userConfigPath(arena, environ) orelse "(no HOME)";
        if (wantsJson(&flags, tail)) {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try aw.writer.writeAll("{\"user\":");
            try std.json.Stringify.value(user_path, .{}, &aw.writer);
            try aw.writer.writeAll(",\"project\":\".ifnh/config.json\"}");
            try printOut(io, arena, "{s}\n", .{aw.written()});
            return;
        }
        try printOut(io, arena, "user: {s}\nproject: .ifnh/config.json\n", .{user_path});
        return;
    }
    if (std.mem.eql(u8, sub, "set")) return runConfigSet(io, arena, environ, flags, tail);
    if (std.mem.eql(u8, sub, "edit")) return runConfigEdit(io, arena, environ, tail);

    var cfg = try config_mod.load(arena, io, environ, std.Io.Dir.cwd());
    defer cfg.deinit();
    // Flags are config too: `ifnh --model m config get model.model` sees `m`.
    try applyStartupOverrides(io, arena, &cfg, flags);

    if (std.mem.eql(u8, sub, "validate")) {
        if (cfg.errors.items.len == 0) {
            try printOut(io, arena, "config valid\n", .{});
        }
        for (cfg.errors.items) |e| try printOut(io, arena, "error [{s}]: {s}\n", .{ e.path, e.message });
        for (cfg.warnings.items) |w| try printOut(io, arena, "warning: {s}\n", .{w});
        if (cfg.errors.items.len > 0) std.process.exit(1);
        return;
    }
    for (cfg.errors.items) |e| try printErr(io, arena, "config error [{s}]: {s}\n", .{ e.path, e.message });
    const is_get = std.mem.eql(u8, sub, "get");
    if (std.mem.eql(u8, sub, "explain") or is_get) {
        if (tail.len == 0) {
            try printOut(io, arena, "usage: ifnh config {s} <dotted.key>\n", .{sub});
            std.process.exit(2);
        }
        const key = tail[0];
        const value = cfg.get(key);
        const src_info = cfg.getSource(key);
        if (wantsJson(&flags, tail)) {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try aw.writer.writeAll("{\"key\":");
            try std.json.Stringify.value(key, .{}, &aw.writer);
            try aw.writer.writeAll(",\"value\":");
            if (value) |v| {
                try std.json.Stringify.value(v, .{}, &aw.writer);
            } else {
                try aw.writer.writeAll("null");
            }
            if (src_info) |src| {
                try aw.writer.writeAll(",\"layer\":");
                try std.json.Stringify.value(src.layer.name(), .{}, &aw.writer);
                try aw.writer.writeAll(",\"source\":");
                try std.json.Stringify.value(src.origin, .{}, &aw.writer);
            } else {
                try aw.writer.writeAll(",\"layer\":null,\"source\":null");
            }
            try aw.writer.writeAll("}");
            try printOut(io, arena, "{s}\n", .{aw.written()});
            return;
        }
        if (value == null) {
            try printOut(io, arena, "{s}: <unset> (no default)\n", .{key});
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(value.?, .{}, &aw.writer);
        if (is_get and !hasArg(tail, "--origin")) {
            try printOut(io, arena, "{s}\n", .{aw.written()});
            return;
        }
        try printOut(io, arena, "{s} = {s}\n  layer: {s}\n  source: {s}\n", .{
            key,
            aw.written(),
            if (src_info) |s| s.layer.name() else "builtin",
            if (src_info) |s| s.origin else "defaults",
        });
        return;
    }
    try printOut(io, arena, "usage: ifnh config [validate|explain <key>|get <key>|set <key> <value>|edit|path|schema]\n", .{});
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn wantsJson(flags: *const cli_args.GlobalFlags, args: []const []const u8) bool {
    return flags.json or hasArg(args, "--json");
}

/// Apply `--profile` then the per-key flags (D-06) and report config errors
/// the same way `validate` does.
fn applyStartupOverrides(
    io: std.Io,
    arena: std.mem.Allocator,
    cfg: *config_mod.Store,
    flags: cli_args.GlobalFlags,
) !void {
    if (flags.profile) |name| {
        cfg.applyProfile(name) catch |err| {
            if (err == error.UnknownProfile) {
                try printErr(io, arena, "error: {s}\n", .{cfg.unknownProfileMessage(arena, name)});
                std.process.exit(2);
            }
            return err;
        };
    }
    try cfg.applyCliOverrides(flags.overrideList());
}

/// Path `set`/`edit` write: `--global` is the user config, everything else
/// the project file.
fn configTargetPath(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    global: bool,
) ![]const u8 {
    if (global) {
        return config_mod.userConfigPath(arena, environ) orelse error.NoHome;
    }
    return ".ifnh/config.json";
}

/// `ifnh config set <key> <value> [--global|--project] [--json]`.
/// A value that parses as JSON is stored as that type; anything else is a
/// string, so `set model.model gpt-5` and `set ui.footer false` both work.
fn runConfigSet(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    flags: cli_args.GlobalFlags,
    args: []const []const u8,
) !void {
    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var global = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--global")) {
            global = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--origin")) continue;
        if (count >= 2) {
            try printErr(io, arena, "usage: ifnh config set <dotted.key> <value> [--global|--project]\n", .{});
            std.process.exit(2);
        }
        positional[count] = arg;
        count += 1;
    }
    if (count < 2) {
        try printErr(io, arena, "usage: ifnh config set <dotted.key> <value> [--global|--project]\n", .{});
        std.process.exit(2);
    }
    const key = positional[0];
    const raw = positional[1];

    const path = configTargetPath(arena, environ, global) catch |err| {
        try printErr(io, arena, "error: cannot resolve the user config path ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const cwd = std.Io.Dir.cwd();
    const existing: []const u8 = cwd.readFileAlloc(io, path, arena, .limited(config_mod.max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => "{}",
        else => {
            try printErr(io, arena, "error: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        },
    };
    var tree = std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{}) catch {
        try printErr(io, arena, "error: invalid JSON in {s}; fix it by hand first\n", .{path});
        std.process.exit(1);
    };
    if (tree != .object) {
        try printErr(io, arena, "error: {s} does not contain a JSON object\n", .{path});
        std.process.exit(1);
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch blk: {
        break :blk std.json.Value{ .string = try arena.dupe(u8, raw) };
    };
    try config_mod.setPathIn(arena, &tree, key, value);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(tree, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    const candidate = aw.written();

    // Validate before write: a typo must never break the next startup.
    const check = try config_mod.validateFileText(arena, candidate);
    for (check.warnings) |w| try printErr(io, arena, "warning: {s}\n", .{w});
    if (check.errors.len > 0) {
        for (check.errors) |e| try printErr(io, arena, "error [{s}]: {s}\n", .{ e.path, e.message });
        try printErr(io, arena, "not written\n", .{});
        std.process.exit(1);
    }
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try fsutil.ensureDirPath(cwd, io, if (slash == 0) "/" else path[0..slash]);
    }
    try fsutil.atomicWriteFile(cwd, io, arena, path, candidate);
    if (wantsJson(&flags, args)) {
        var out_aw: std.Io.Writer.Allocating = .init(arena);
        try out_aw.writer.writeAll("{\"path\":");
        try std.json.Stringify.value(path, .{}, &out_aw.writer);
        try out_aw.writer.writeAll(",\"key\":");
        try std.json.Stringify.value(key, .{}, &out_aw.writer);
        try out_aw.writer.writeAll(",\"value\":");
        try std.json.Stringify.value(value, .{}, &out_aw.writer);
        try out_aw.writer.writeByte('}');
        try printOut(io, arena, "{s}\n", .{out_aw.written()});
        return;
    }
    try printOut(io, arena, "{s} = {s}  ({s})\n", .{ key, raw, path });
}

/// `ifnh config edit [--global|--project]`: open the file in `$VISUAL` /
/// `$EDITOR` (default `vi`) and validate what came back.
fn runConfigEdit(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
) !void {
    const global = hasArg(args, "--global");
    const path = configTargetPath(arena, environ, global) catch |err| {
        try printErr(io, arena, "error: cannot resolve the user config path ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const cwd = std.Io.Dir.cwd();
    const exists = fsutil.fileExists(cwd, io, path);
    if (!exists) {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try fsutil.ensureDirPath(cwd, io, if (slash == 0) "/" else path[0..slash]);
        }
        try fsutil.atomicWriteFile(cwd, io, arena, path, "{}\n");
    }
    const editor = environ.get("VISUAL") orelse environ.get("EDITOR") orelse "vi";
    // `$EDITOR` may carry arguments ("code --wait"), so let a shell split it.
    const script = try std.fmt.allocPrint(arena, "{s} \"$1\"", .{editor});
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script, "ifnh-config-edit", path },
        .cwd = .{ .dir = cwd },
    });
    const term = try child.wait(io);
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        try printErr(io, arena, "editor exited with an error; {s} left unchanged\n", .{path});
        std.process.exit(1);
    }
    const text = cwd.readFileAlloc(io, path, arena, .limited(config_mod.max_config_bytes)) catch {
        try printErr(io, arena, "error: cannot read {s} after editing\n", .{path});
        std.process.exit(1);
    };
    const check = try config_mod.validateFileText(arena, text);
    for (check.warnings) |w| try printOut(io, arena, "warning: {s}\n", .{w});
    for (check.errors) |e| try printOut(io, arena, "error [{s}]: {s}\n", .{ e.path, e.message });
    if (check.errors.len > 0) {
        std.process.exit(1);
    }
    try printOut(io, arena, "config valid ({s})\n", .{path});
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
    const state_root = config_mod.userStateDir(arena, environ) orelse "";
    if (state_root.len > 0) {
        const wt_root = try std.fmt.allocPrint(arena, "{s}/worktrees", .{state_root});
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
    // Key lookup uses the same merged view as sessions: process env +
    // stored keys (~/.config/ifnh/env).
    const keys_mod = @import("core/config/keys.zig");
    var stored_keys = keys_mod.Keys.init(arena);
    stored_keys.load(io, arena, environ);
    const has_key = environ.get(key_env) != null or stored_keys.map.get(key_env) != null;
    const has_model = cfg.getString("model.model", "").len > 0;
    if (has_key and has_model) {
        const pd = cfg.getOptionalString("model.provider_label") orelse provider_name;
        const key_where: []const u8 = if (environ.get(key_env) != null)
            "environment"
        else
            keys_mod.Keys.path(arena, environ) orelse "the user env file";
        try printOut(io, arena, "  provider: ok ({s} · {s}, key from {s})\n", .{ pd, cfg.getString("model.model", ""), key_where });
    } else {
        problems += 1;
        if (!has_model) try printOut(io, arena, "  provider: model.model not set (run `ifnh` — first-run setup will ask)\n", .{});
        if (!has_key) try printOut(io, arena, "  provider: {s} not set (export it, or run `ifnh` -> /provider key {s})\n", .{ key_env, key_env });
    }

    // Git.
    if (git_mod.discover(io, arena, cwd)) |ws| {
        if (ws.git) |g| {
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
    // Custom tool definitions (D-02, ADR 0004); the loader tolerates absence.
    try fsutil.ensureDirPath(cwd, io, ".ifnh/tools");

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
        \\created .ifnh/ (config.json, skills/, commands/, instructions/, plans/, tools/)
        \\next: run `ifnh` — first-run setup will configure your provider, model, and key
        \\
    , .{});
}

fn printOut(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var stack_buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&stack_buf, fmt, args) catch
        try std.fmt.allocPrint(alloc, fmt, args); // arena-owned; freed at process exit
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

/// Usage/config errors must never pollute `--json` stdout.
fn printErr(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var stack_buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&stack_buf, fmt, args) catch
        try std.fmt.allocPrint(alloc, fmt, args); // arena-owned; freed at process exit
    try std.Io.File.stderr().writeStreamingAll(io, text);
}

const help_text =
    \\ifnh {s} — a tiny, fast, developer-controlled agentic coding harness.
    \\
    \\usage: ifnh [global-flags] <subcommand> [args...]
    \\
    \\subcommands:
    \\  (none)      start an interactive session (M0)
    \\  init        create a .ifnh/ project skeleton
    \\  config      validate/explain/get/set/edit/path/schema configuration
    \\  sessions    list recorded sessions (--json supported)
    \\  fork        branch a session (ifnh fork <id>); 'ifnh fork diff <a> <b>' compares
    \\  cleanup     enforce retention, list/remove worktrees
    \\  resume      resume a previous session (M0)
    \\  ask         run one headless turn (prompt arg or stdin; --json NDJSON)
    \\  doctor      check environment health (M1)
    \\  help        show this text
    \\  version     print version
    \\
    \\global flags:
    \\  --json                  machine-readable output
    \\  --no-color              disable color
    \\  --log-level <level>     err | info | debug | trace
    \\  --profile <name>        apply profiles.<name> from config (D-03)
    \\  --model <id>            per-key config flags, applied as the cli layer:
    \\  --provider <name>       --model --provider --base-url --temperature
    \\  --base-url <url>        --max-output-tokens --context-tokens
    \\  --temperature <n>       --permission-mode --no-footer  (D-06)
    \\  -p <prompt>             headless one-shot prompt (same as 'ask -p')
    \\  -h, --help              show help
    \\  -V, --version           print version
    \\
    \\ask flags:
    \\  --json                  NDJSON events on stdout, nothing else
    \\  --yes                   approve every permission ask (once)
    \\  --deny-all              deny every permission ask
    \\  --policy <ask|allow|deny>  default: ask (/dev/tty when stdin is a tty)
    \\  -p <prompt>             prompt text; '-' or omitted reads stdin
    \\  (exit: 0 ok, 1 failed, 2 usage, 3 denied, 4 budget spent, 130 interrupted)
    \\
;

test {
    _ = @import("version.zig");
    _ = @import("core/types.zig");
    _ = @import("core/fsutil.zig");
    _ = @import("cli/args.zig");
    _ = @import("core/config/config.zig");
    _ = @import("core/config/schema.zig");
    _ = @import("core/session/store.zig");
    _ = @import("core/journal.zig");
    _ = @import("core/permissions/glob.zig");
    _ = @import("core/permissions/command_class.zig");
    _ = @import("core/permissions/engine.zig");
    _ = @import("core/permissions/local_grants.zig");
    _ = @import("tools/tool.zig");
    _ = @import("tools/search.zig");
    _ = @import("tools/custom.zig");
    _ = @import("providers/provider.zig");
    _ = @import("providers/transport.zig");
    _ = @import("providers/sse.zig");
    _ = @import("providers/openai.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/limits.zig");
    _ = @import("providers/pricing.zig");
    _ = @import("core/budget.zig");
    _ = @import("core/diff.zig");
    _ = @import("core/instructions.zig");
    _ = @import("core/trace.zig");
    _ = @import("core/turn_cache.zig");
    _ = @import("core/agent/engine.zig");
    _ = @import("core/agent/testing.zig");
    _ = @import("core/agent/subagent.zig");
    _ = @import("core/agent/session_runtime.zig");
    _ = @import("core/git.zig");
    _ = @import("core/mcp.zig");
    _ = @import("core/skills.zig");
    _ = @import("core/hooks.zig");
    _ = @import("core/compaction.zig");
    _ = @import("core/lifecycle.zig");
    _ = @import("core/executions.zig");
    _ = @import("core/interrupt.zig");
    _ = @import("ui/style.zig");
    _ = @import("ui/secret.zig");
    _ = @import("ui/footer.zig");
    _ = @import("ui/render.zig");
    _ = @import("ui/line_editor.zig");
    _ = @import("providers/models.zig");
    _ = @import("providers/probe.zig");
    _ = @import("core/config/keys.zig");
    _ = @import("core/config/resolve.zig");
    _ = @import("providers/options.zig");
    _ = @import("core/agent/system_prompt.zig");
    _ = @import("cli/repl.zig");
    _ = @import("cli/ask.zig");
    _ = @import("core/redact.zig");
    _ = @import("providers/testing.zig");
}
