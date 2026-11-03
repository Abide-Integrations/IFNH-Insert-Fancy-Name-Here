//! Skills: SKILL.md catalog, discovery, and injection (M1-T06,
//! DECISIONS section K, D016/D018).
//!
//! Format: Agent Skills SKILL.md — YAML-ish frontmatter (name,
//! description) + Markdown body (K147). Missing frontmatter tolerates the
//! directory basename (fx skill_contract semantics). Discovery roots:
//! user ~/.config/ifnh/skills, project .ifnh/skills, plus read-only
//! compat roots .claude/skills and .agents/skills (K148). Project
//! overrides user on name collision (K149). Skills never grant
//! permissions (K153).

const std = @import("std");
const fsutil = @import("fsutil.zig");
const lock_mod = @import("skills_lock.zig");

pub const max_skill_bytes: usize = 256 * 1024;
pub const max_catalog_bytes: usize = 16 * 1024;

pub const Skill = struct {
    name: []const u8,
    description: []const u8 = "",
    path: []const u8, // repo-relative or absolute (user scope)
    scope: []const u8, // "project" | "user" | "compat"
};

pub const Catalog = struct {
    skills: []Skill,
    omitted: usize = 0,
};

pub const Parsed = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
};

/// Parse a SKILL.md: optional `---` frontmatter with name/description
/// keys, then the body. Malformed frontmatter falls back to basename.
pub fn parseSkillFile(arena: std.mem.Allocator, content: []const u8, fallback_name: []const u8) !Parsed {
    var body = content;
    var name: ?[]const u8 = null;
    var description: []const u8 = "";

    if (std.mem.startsWith(u8, body, "---")) {
        if (std.mem.indexOfPos(u8, body, 3, "\n---")) |end| {
            const fm = body[3..end];
            body = body[end + 4 ..];
            if (body.len > 0 and body[0] == '\n') body = body[1..];
            var it = std.mem.splitScalar(u8, fm, '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const key = std.mem.trim(u8, line[0..colon], " ");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \"'\t\r");
                if (std.mem.eql(u8, key, "name")) {
                    name = try arena.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    description = try arena.dupe(u8, value);
                }
                // Unknown frontmatter keys tolerated (forward-compat).
            }
        }
    }

    return .{
        .name = name orelse try arena.dupe(u8, fallback_name),
        .description = description,
        .body = body,
    };
}

const RootSpec = struct {
    rel: []const u8,
    scope: []const u8,
    /// Compat roots are read-only and lower precedence.
    compat: bool = false,
};

const project_roots = [_]RootSpec{
    .{ .rel = ".ifnh/skills", .scope = "project" },
    .{ .rel = ".claude/skills", .scope = "compat", .compat = true },
    .{ .rel = ".agents/skills", .scope = "compat", .compat = true },
};

/// Discover skills for `workspace`. Project scope overrides user on name
/// collision; entries are deduped by canonical name.
pub fn discover(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, user_skills_dir: ?[]const u8) !Catalog {
    var out: std.ArrayListUnmanaged(Skill) = .empty;

    // User scope first (lowest precedence).
    if (user_skills_dir) |ud| {
        collectRoot(workspace, io, arena, ud, "user", &out, true) catch {};
    }
    // Project scope (overrides user by name).
    for (project_roots) |root| {
        collectRoot(workspace, io, arena, root.rel, root.scope, &out, root.compat) catch {};
    }

    // Name-collision resolution: later entries (project) win.
    var deduped: std.ArrayListUnmanaged(Skill) = .empty;
    for (out.items) |s| {
        var replaced = false;
        for (deduped.items) |*d| {
            if (std.mem.eql(u8, d.name, s.name)) {
                if (!std.mem.eql(u8, d.scope, "project") and std.mem.eql(u8, s.scope, "project")) {
                    d.* = s;
                }
                replaced = true;
                break;
            }
        }
        if (!replaced) try deduped.append(arena, s);
    }

    return .{ .skills = deduped.items };
}

fn collectRoot(
    workspace: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    scope: []const u8,
    out: *std.ArrayListUnmanaged(Skill),
    compat: bool,
) !void {
    var dir = workspace.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const skill_md = std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ root, entry.name }) catch continue;
        const content = fsutil.readSmallFile(workspace, io, arena, skill_md, max_skill_bytes) catch continue;
        const parsed = parseSkillFile(arena, content, entry.name) catch continue;
        try out.append(arena, .{
            .name = parsed.name,
            .description = parsed.description,
            .path = skill_md,
            .scope = scope,
        });
    }
    _ = compat;
}

/// Budgeted catalog index for the system prompt (fx available_skills
/// pattern): name + description lines, bounded, omitted count reported.
pub fn renderCatalog(arena: std.mem.Allocator, catalog: Catalog) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var included: usize = 0;
    var size: usize = 0;
    for (catalog.skills) |s| {
        const line = std.fmt.allocPrint(arena, "- {s}: {s} ({s})\n", .{ s.name, s.description, s.path }) catch continue;
        if (size + line.len > max_catalog_bytes) {
            out.appendSlice(arena, "...[catalog truncated]\n") catch {};
            break;
        }
        out.appendSlice(arena, line) catch {};
        size += line.len;
        included += 1;
    }
    if (out.items.len == 0) return "";
    const omitted = catalog.skills.len - included;
    if (omitted > 0) {
        out.print(arena, "[{d} skills omitted]\n", .{omitted}) catch {};
    }
    return out.items;
}

/// Load a skill body by name (the `skill` tool). Returns the raw file.
pub fn loadSkill(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, catalog: Catalog, name: []const u8) ![]const u8 {
    for (catalog.skills) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            return fsutil.readSmallFile(workspace, io, arena, s.path, max_skill_bytes);
        }
    }
    return error.SkillNotFound;
}

// ---------------------------------------------------------------- /skills subcommands

pub const skills_dir = ".ifnh/skills";

pub const usage_text =
    "usage: /skills [list]\n" ++
    "       /skills install <git-url> [name] [--ref <ref>] [--force]\n" ++
    "       /skills remove <name>";

pub const InstallArgs = struct {
    url: []const u8,
    name: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    force: bool = false,
};

pub const Command = union(enum) {
    list,
    install: InstallArgs,
    remove: []const u8,
    /// Not a valid invocation; the payload is the one-line reason to print.
    usage: []const u8,
};

/// Parse what follows `/skills`. Pure; the REPL acts on the result.
pub fn parseCommand(rest: []const u8) Command {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const sub = it.next() orelse return .list;
    if (std.mem.eql(u8, sub, "list")) return .list;
    if (std.mem.eql(u8, sub, "remove")) {
        const name = it.next() orelse return .{ .usage = usage_text };
        if (it.next() != null) return .{ .usage = usage_text };
        return .{ .remove = name };
    }
    if (!std.mem.eql(u8, sub, "install")) return .{ .usage = usage_text };

    var args = InstallArgs{ .url = "" };
    var positional: usize = 0;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "--force")) {
            args.force = true;
        } else if (std.mem.eql(u8, tok, "--ref")) {
            args.ref = it.next() orelse return .{ .usage = "--ref needs a value" };
        } else if (tok[0] == '-') {
            return .{ .usage = "unknown option (see /skills install usage)" };
        } else switch (positional) {
            0 => {
                args.url = tok;
                positional += 1;
            },
            1 => {
                args.name = tok;
                positional += 1;
            },
            else => return .{ .usage = usage_text },
        }
    }
    if (args.url.len == 0) return .{ .usage = usage_text };
    return .{ .install = args };
}

/// `https://host/path`, `ssh://host/path` or `git@host:path`. Everything else
/// (`file://`, `git://`, bare paths, a leading `-`, whitespace or control
/// bytes) is refused so a source can never become a git option or reach the
/// local filesystem.
pub fn validSource(url: []const u8) bool {
    if (url.len == 0 or url[0] == '-') return false;
    for (url) |c| {
        if (c <= ' ' or c == 0x7f) return false;
    }
    inline for (.{ "https://", "ssh://" }) |scheme| {
        if (std.mem.startsWith(u8, url, scheme)) {
            const after = url[scheme.len..];
            const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            // A host like `-oProxyCommand=...` is an ssh option in disguise.
            return host_end > 0 and after[0] != '-' and host_end < after.len;
        }
    }
    if (std.mem.startsWith(u8, url, "git@")) {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
        return colon > "git@".len and colon + 1 < url.len;
    }
    return false;
}

/// `[A-Za-z0-9._-]+`, not `.`/`..`, and clear of the `.tmp-`/`.old-` prefixes
/// install uses for its scratch directories.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.startsWith(u8, name, ".tmp-") or std.mem.startsWith(u8, name, ".old-")) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// A branch or tag for `git clone --branch`: nothing git could read as an
/// option and no whitespace.
fn validRef(ref: []const u8) bool {
    if (ref.len == 0 or ref[0] == '-') return false;
    for (ref) |c| {
        if (c <= ' ' or c == 0x7f) return false;
    }
    return true;
}

/// `https://h/o/repo.git` -> `repo`; `git@h:o/repo` -> `repo`.
pub fn defaultName(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    const trimmed = url[0..end];
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, "/:")) |i| i + 1 else 0;
    const base = trimmed[start..];
    return if (std.mem.endsWith(u8, base, ".git")) base[0 .. base.len - ".git".len] else base;
}

pub const InstallError = error{ InstallFailed, OutOfMemory };

pub const Installed = struct {
    name: []const u8,
    commit: []const u8,
    /// A `SKILL.md` exists within two directory levels.
    has_skill_md: bool,
};

fn fail(msg: *[]const u8, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) InstallError {
    msg.* = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    return error.InstallFailed;
}

/// `/skills install`: clone `args.url` shallowly into a scratch directory,
/// pin its commit in the lockfile and move it to `.ifnh/skills/<name>`. On
/// `error.InstallFailed`, `msg` holds the one-line reason and the workspace is
/// unchanged. `environ` (when given) is copied for git with prompts disabled.
pub fn install(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    args: InstallArgs,
    msg: *[]const u8,
) InstallError!Installed {
    if (!validSource(args.url)) {
        return fail(msg, arena, "unsupported source '{s}': use https://, ssh:// or git@host:path", .{args.url});
    }
    return cloneAndRegister(arena, io, workspace, environ, args, msg);
}

/// `install` without the source-scheme guard, so tests can clone a local
/// fixture repository.
fn cloneAndRegister(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    args: InstallArgs,
    msg: *[]const u8,
) InstallError!Installed {
    const name = args.name orelse defaultName(args.url);
    if (!validName(name)) {
        return fail(msg, arena, "invalid skill name '{s}': use letters, digits, '.', '_' and '-'", .{name});
    }
    if (args.ref) |r| {
        if (!validRef(r)) return fail(msg, arena, "invalid --ref '{s}'", .{r});
    }

    // A broken lockfile stops the install: it must not be overwritten.
    var lock = lock_mod.read(workspace, io, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLock => {
            msg.* = lock_mod.invalid_message;
            return error.InstallFailed;
        },
    };

    const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ skills_dir, name });
    const tmp_rel = try std.fmt.allocPrint(arena, "{s}/.tmp-{s}", .{ skills_dir, name });
    const old_rel = try std.fmt.allocPrint(arena, "{s}/.old-{s}", .{ skills_dir, name });
    const target_exists = fsutil.fileExists(workspace, io, target);
    if (target_exists and !args.force) {
        return fail(msg, arena, "skill '{s}' is already installed (use --force)", .{name});
    }
    if (lock.get(name)) |existing| {
        if (!args.force and !std.mem.eql(u8, existing.source, args.url)) {
            return fail(msg, arena, "skill '{s}' is recorded in the lockfile from a different source (use --force)", .{name});
        }
    }

    workspace.createDirPath(io, skills_dir) catch |err| return fail(msg, arena, "cannot create {s}: {s}", .{ skills_dir, @errorName(err) });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = workspace.realPathFile(io, ".", &root_buf) catch |err| return fail(msg, arena, "cannot resolve the workspace: {s}", .{@errorName(err)});
    const root = try arena.dupe(u8, root_buf[0..root_len]);
    const tmp_abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, tmp_rel });

    // A leftover from an interrupted install is not worth keeping.
    workspace.deleteTree(io, tmp_rel) catch {};
    errdefer workspace.deleteTree(io, tmp_rel) catch {};

    var env_copy: ?std.process.Environ.Map = null;
    if (environ) |e| {
        var m = try e.clone(arena);
        try m.put("GIT_TERMINAL_PROMPT", "0");
        env_copy = m;
    }
    const env_ptr: ?*const std.process.Environ.Map = if (env_copy) |*m| m else null;

    // `--quiet` keeps git's "Cloning into ..." line out of stderr, so the
    // first line of a failure is the reason. `--` ends option parsing.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "clone", "--quiet", "--depth", "1" });
    if (args.ref) |r| try argv.appendSlice(arena, &.{ "--branch", r });
    try argv.appendSlice(arena, &.{ "--", args.url, tmp_abs });
    const clone = runGit(arena, io, root, env_ptr, argv.items) catch |err| {
        return fail(msg, arena, "git clone failed: could not run git ({s})", .{@errorName(err)});
    };
    if (!clone.ok) return fail(msg, arena, "git clone failed: {s}", .{clone.first_line});

    const head = runGit(arena, io, root, env_ptr, &.{ "git", "-C", tmp_abs, "rev-parse", "HEAD" }) catch |err| {
        return fail(msg, arena, "git rev-parse failed: could not run git ({s})", .{@errorName(err)});
    };
    const commit = std.mem.trim(u8, head.stdout, " \t\r\n");
    if (!head.ok or !isFullSha(commit)) {
        return fail(msg, arena, "git rev-parse failed: {s}", .{if (head.first_line.len > 0) head.first_line else "no commit"});
    }

    // The lockfile pins the commit; an embedded .git would make the project
    // repository see a nested repo.
    const tmp_git = try std.fmt.allocPrint(arena, "{s}/.git", .{tmp_rel});
    workspace.deleteTree(io, tmp_git) catch {};

    // Swap: the old copy is parked first so the target is never half-replaced.
    if (target_exists) {
        workspace.deleteTree(io, old_rel) catch {};
        workspace.rename(target, workspace, old_rel, io) catch |err| return fail(msg, arena, "cannot replace skill '{s}': {s}", .{ name, @errorName(err) });
    }
    workspace.rename(tmp_rel, workspace, target, io) catch |err| {
        if (target_exists) workspace.rename(old_rel, workspace, target, io) catch {};
        return fail(msg, arena, "cannot install skill '{s}': {s}", .{ name, @errorName(err) });
    };
    if (target_exists) workspace.deleteTree(io, old_rel) catch {};

    var ts_buf: [20]u8 = undefined;
    try lock.put(arena, name, .{
        .source = args.url,
        .ref = args.ref orelse "",
        .commit = commit,
        .installed_at = fsutil.isoUtc(&ts_buf, fsutil.nowSecs(io)),
    });
    lock.write(workspace, io, arena) catch |err| {
        return fail(msg, arena, "installed '{s}' but could not write {s}: {s}", .{ name, lock_mod.path, @errorName(err) });
    };

    return .{ .name = name, .commit = commit, .has_skill_md = hasSkillMd(workspace, io, target, 0) };
}

/// `/skills remove`: delete `.ifnh/skills/<name>` and its lock entry. The
/// caller confirms first (`isInstalled`). A broken lockfile stops the removal.
pub fn remove(
    arena: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    name: []const u8,
    msg: *[]const u8,
) InstallError!void {
    if (!validName(name) or !isInstalled(workspace, io, arena, name)) {
        return fail(msg, arena, "skill '{s}' is not installed", .{name});
    }
    var lock = lock_mod.read(workspace, io, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLock => {
            msg.* = lock_mod.invalid_message;
            return error.InstallFailed;
        },
    };
    const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ skills_dir, name });
    workspace.deleteTree(io, target) catch |err| return fail(msg, arena, "cannot remove {s}: {s}", .{ target, @errorName(err) });
    if (lock.remove(name)) {
        lock.write(workspace, io, arena) catch |err| {
            return fail(msg, arena, "removed '{s}' but could not update {s}: {s}", .{ name, lock_mod.path, @errorName(err) });
        };
    }
}

/// A project skill directory or a lock entry exists for `name`.
pub fn isInstalled(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, name: []const u8) bool {
    if (!validName(name)) return false;
    const target = std.fmt.allocPrint(arena, "{s}/{s}", .{ skills_dir, name }) catch return false;
    if (fsutil.fileExists(workspace, io, target)) return true;
    const lock = lock_mod.read(workspace, io, arena) catch return false;
    return lock.get(name) != null;
}

/// `<dir>` of `.ifnh/skills/<dir>/SKILL.md`, or null for other locations.
pub fn projectDirName(skill_path: []const u8) ?[]const u8 {
    const prefix = skills_dir ++ "/";
    if (!std.mem.startsWith(u8, skill_path, prefix)) return null;
    const rest = skill_path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

/// True when `SKILL.md` exists in `dir_rel` or up to two directory levels
/// below it.
fn hasSkillMd(workspace: std.Io.Dir, io: std.Io, dir_rel: []const u8, depth: u8) bool {
    var dir = workspace.openDir(io, dir_rel, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.name, "SKILL.md")) return true;
        if (entry.kind == .directory and depth < 2) {
            const sub = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_rel, entry.name }) catch continue;
            if (hasSkillMd(workspace, io, sub, depth + 1)) return true;
        }
    }
    return false;
}

fn isFullSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const GitRun = struct { ok: bool, stdout: []const u8, first_line: []const u8 };

fn runGit(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    argv: []const []const u8,
) !GitRun {
    const r = try std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environ,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(300) } },
    });
    const ok = r.term == .exited and r.term.exited == 0;
    var lines = std.mem.tokenizeAny(u8, r.stderr, "\r\n");
    const first = std.mem.trim(u8, lines.next() orelse "", " \t");
    return .{
        .ok = ok,
        .stdout = r.stdout,
        .first_line = if (first.len > 0) first else if (ok) "" else "git exited with an error",
    };
}

// ---------------------------------------------------------------- tests

test "parse skill with and without frontmatter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const with_fm = try parseSkillFile(a, "---\nname: pdf-review\ndescription: Review PDFs carefully\n---\nBody here.", "fallback");
    try std.testing.expectEqualStrings("pdf-review", with_fm.name);
    try std.testing.expectEqualStrings("Review PDFs carefully", with_fm.description);
    try std.testing.expectEqualStrings("Body here.", with_fm.body);

    const no_fm = try parseSkillFile(a, "just a body", "my-skill");
    try std.testing.expectEqualStrings("my-skill", no_fm.name);
    try std.testing.expectEqualStrings("just a body", no_fm.body);
}

test "discovery merges scopes; project overrides user" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Project skill + compat skill.
    try tmp.dir.createDirPath(io, ".ifnh/skills/testing");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/testing/SKILL.md", .data = "---\nname: testing\ndescription: project testing\n---\nbody" });
    try tmp.dir.createDirPath(io, ".claude/skills/review");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/skills/review/SKILL.md", .data = "---\nname: review\ndescription: review skill\n---\nbody" });

    // Fake user dir: same tmp root acts as absolute user path.
    try tmp.dir.createDirPath(io, "user-skills/testing");
    try tmp.dir.writeFile(io, .{ .sub_path = "user-skills/testing/SKILL.md", .data = "---\nname: testing\ndescription: user testing\n---\nbody" });
    const user_dir = try std.fmt.allocPrint(a, "{s}/user-skills", .{"."});

    const catalog = try discover(tmp.dir, io, a, user_dir);
    try std.testing.expectEqual(@as(usize, 2), catalog.skills.len);
    for (catalog.skills) |s| {
        if (std.mem.eql(u8, s.name, "testing")) {
            try std.testing.expectEqualStrings("project testing", s.description); // project wins
            try std.testing.expectEqualStrings("project", s.scope);
        }
    }
}

test "catalog rendering is budgeted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var skills: std.ArrayListUnmanaged(Skill) = .empty;
    for (0..64) |i| {
        try skills.append(a, .{
            .name = try std.fmt.allocPrint(a, "skill-{d}", .{i}),
            .description = &@as([300]u8, @splat('x')),
            .path = "p",
            .scope = "project",
        });
    }
    const rendered = try renderCatalog(a, .{ .skills = skills.items });
    try std.testing.expect(rendered.len < max_catalog_bytes + 128);
}

test "skills source guard: https, ssh and scp-style only" {
    for ([_][]const u8{
        "https://github.com/o/skill.git",
        "https://example.com/o/skill",
        "ssh://git@example.com/o/skill.git",
        "git@github.com:o/skill.git",
    }) |ok| try std.testing.expect(validSource(ok));
    for ([_][]const u8{
        "",
        "/tmp/skill",
        "./skill",
        "skill",
        "~/skill",
        "file:///tmp/skill",
        "git://example.com/o/skill.git",
        "http://example.com/o/skill.git",
        "-oProxyCommand=evil",
        "--upload-pack=evil",
        "https://",
        "https://host",
        "https:///path",
        "ssh://-oProxyCommand=evil/x",
        "git@:path",
        "git@host:",
        "https://example.com/a b",
        "https://example.com/a\nb",
    }) |bad| try std.testing.expect(!validSource(bad));
}

test "skills names: validation and defaults from the URL" {
    try std.testing.expect(validName("pdf-review"));
    try std.testing.expect(validName("a.b_c-1"));
    for ([_][]const u8{ "", ".", "..", "a/b", "a b", "../x", ".tmp-x", ".old-x", &@as([65]u8, @splat('x')), "naïve" }) |bad| {
        try std.testing.expect(!validName(bad));
    }
    try std.testing.expectEqualStrings("skill", defaultName("https://github.com/o/skill.git"));
    try std.testing.expectEqualStrings("skill", defaultName("https://github.com/o/skill/"));
    try std.testing.expectEqualStrings("skill", defaultName("git@github.com:o/skill.git"));
    try std.testing.expectEqualStrings("skill", defaultName("git@host:skill"));
    try std.testing.expectEqualStrings("repo.tar", defaultName("https://h/repo.tar"));
}

test "skills command parsing" {
    try std.testing.expect(parseCommand("") == .list);
    try std.testing.expect(parseCommand("  list ") == .list);
    try std.testing.expect(parseCommand("bogus") == .usage);
    try std.testing.expect(parseCommand("install") == .usage);

    const plain = parseCommand("install https://h/o/s.git").install;
    try std.testing.expectEqualStrings("https://h/o/s.git", plain.url);
    try std.testing.expect(plain.name == null and plain.ref == null and !plain.force);

    const full = parseCommand("install https://h/o/s.git mine --ref v1.2 --force").install;
    try std.testing.expectEqualStrings("mine", full.name.?);
    try std.testing.expectEqualStrings("v1.2", full.ref.?);
    try std.testing.expect(full.force);

    // Flags may come before the positionals.
    const flags_first = parseCommand("install --force --ref main https://h/o/s.git").install;
    try std.testing.expect(flags_first.force and std.mem.eql(u8, flags_first.ref.?, "main"));

    try std.testing.expectEqualStrings("--ref needs a value", parseCommand("install https://h/o/s.git --ref").usage);
    try std.testing.expect(parseCommand("install https://h/o/s.git --bogus") == .usage);
    try std.testing.expect(parseCommand("install -oProxyCommand=x") == .usage);
    try std.testing.expect(parseCommand("install https://h/o/s.git a b") == .usage);

    try std.testing.expectEqualStrings("mine", parseCommand("remove mine").remove);
    try std.testing.expect(parseCommand("remove") == .usage);
    try std.testing.expect(parseCommand("remove a b") == .usage);
}

test "skills install: a plain path is refused before git runs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msg: []const u8 = "";
    try std.testing.expectError(error.InstallFailed, install(arena, io, tmp.dir, null, .{ .url = "/tmp/some/repo" }, &msg));
    try std.testing.expectEqualStrings("unsupported source '/tmp/some/repo': use https://, ssh:// or git@host:path", msg);
    try std.testing.expectError(error.InstallFailed, install(arena, io, tmp.dir, null, .{ .url = "file:///tmp/some/repo" }, &msg));
    try std.testing.expectError(error.InstallFailed, install(arena, io, tmp.dir, null, .{ .url = "--upload-pack=x" }, &msg));
    try std.testing.expect(!fsutil.fileExists(tmp.dir, io, ".ifnh"));
}

// ---- git fixtures (skipped when `git` is not on PATH, like the rg/fd tests)

fn gitAvailable(io: std.Io) bool {
    const r = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

fn git(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "git", "-c", "init.defaultBranch=main", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" });
    try argv.appendSlice(arena, args);
    const r = try std.process.run(arena, io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], r.stderr });
        return error.GitFailed;
    }
    return std.mem.trim(u8, r.stdout, " \r\n");
}

const Fixture = struct { abs: []const u8, url: []const u8 };

/// A throwaway upstream repo `sub` under `tmp` with one commit of `files`.
fn makeRepo(arena: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir, sub: []const u8, files: []const [2][]const u8) !Fixture {
    try tmp.dir.createDirPath(io, sub);
    for (files) |f| {
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, f[0] });
        if (std.fs.path.dirname(rel)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = f[1] });
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, sub, &buf);
    const abs = try arena.dupe(u8, buf[0..n]);
    _ = try git(arena, io, abs, &.{ "init", "-q" });
    _ = try git(arena, io, abs, &.{ "add", "-A" });
    _ = try git(arena, io, abs, &.{ "commit", "-q", "-m", "init" });
    return .{ .abs = abs, .url = try std.fmt.allocPrint(arena, "file://{s}", .{abs}) };
}

const fixture_skill_md = "---\nname: fixture\ndescription: A fixture skill\n---\nBody.\n";

fn workspaceIn(arena: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !std.Io.Dir {
    _ = arena;
    try tmp.dir.createDirPath(io, "ws");
    return tmp.dir.openDir(io, "ws", .{ .iterate = true });
}

test "skills install: clone, lock the real commit, then refuse a second install and replace with --force" {
    const io = std.testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const upstream = try makeRepo(arena, io, &tmp, "up/fixture", &.{ .{ "SKILL.md", fixture_skill_md }, .{ "extra.txt", "v1" } });
    const first_commit = try git(arena, io, upstream.abs, &.{ "rev-parse", "HEAD" });
    var ws = try workspaceIn(arena, io, &tmp);
    defer ws.close(io);

    var msg: []const u8 = "";
    const done = try cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url }, &msg);
    try std.testing.expectEqualStrings("fixture", done.name);
    try std.testing.expectEqualStrings(first_commit, done.commit);
    try std.testing.expect(done.has_skill_md);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/fixture/SKILL.md"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/fixture/.git"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/.tmp-fixture"));

    const lock = try lock_mod.read(ws, io, arena);
    const entry = lock.get("fixture").?;
    try std.testing.expectEqualStrings(first_commit, entry.commit);
    try std.testing.expectEqualStrings(upstream.url, entry.source);
    try std.testing.expectEqualStrings("", entry.ref);
    try std.testing.expectEqual(@as(usize, 20), entry.installed_at.len);

    // The catalog sees it without a restart.
    const catalog = try discover(ws, io, arena, null);
    try std.testing.expectEqual(@as(usize, 1), catalog.skills.len);
    try std.testing.expectEqualStrings("fixture", projectDirName(catalog.skills[0].path).?);

    // Second install: refused, nothing touched.
    const lock_before = try ws.readFileAlloc(io, lock_mod.path, arena, .limited(1 << 16));
    try std.testing.expectError(error.InstallFailed, cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url }, &msg));
    try std.testing.expectEqualStrings("skill 'fixture' is already installed (use --force)", msg);
    try std.testing.expectEqualStrings(lock_before, try ws.readFileAlloc(io, lock_mod.path, arena, .limited(1 << 16)));

    // Upstream moves on; --force replaces the whole directory.
    try tmp.dir.deleteFile(io, "up/fixture/extra.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "up/fixture/new.txt", .data = "v2" });
    _ = try git(arena, io, upstream.abs, &.{ "add", "-A" });
    _ = try git(arena, io, upstream.abs, &.{ "commit", "-q", "-m", "second" });
    const second_commit = try git(arena, io, upstream.abs, &.{ "rev-parse", "HEAD" });
    const forced = try cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url, .force = true }, &msg);
    try std.testing.expectEqualStrings(second_commit, forced.commit);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/fixture/new.txt"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/fixture/extra.txt"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/.old-fixture"));
    try std.testing.expectEqualStrings(second_commit, (try lock_mod.read(ws, io, arena)).get("fixture").?.commit);
}

test "skills install: --ref picks the branch, and a different source needs --force" {
    const io = std.testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const upstream = try makeRepo(arena, io, &tmp, "up/branchy", &.{.{ "SKILL.md", fixture_skill_md }});
    const main_commit = try git(arena, io, upstream.abs, &.{ "rev-parse", "HEAD" });
    _ = try git(arena, io, upstream.abs, &.{ "checkout", "-q", "-b", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "up/branchy/feature.txt", .data = "f" });
    _ = try git(arena, io, upstream.abs, &.{ "add", "-A" });
    _ = try git(arena, io, upstream.abs, &.{ "commit", "-q", "-m", "feature work" });
    const feature_commit = try git(arena, io, upstream.abs, &.{ "rev-parse", "HEAD" });
    _ = try git(arena, io, upstream.abs, &.{ "checkout", "-q", "main" });
    try std.testing.expect(!std.mem.eql(u8, main_commit, feature_commit));

    var ws = try workspaceIn(arena, io, &tmp);
    defer ws.close(io);
    var msg: []const u8 = "";
    const done = try cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url, .ref = "feature", .name = "mine" }, &msg);
    try std.testing.expectEqualStrings(feature_commit, done.commit);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/mine/feature.txt"));
    const entry = (try lock_mod.read(ws, io, arena)).get("mine").?;
    try std.testing.expectEqualStrings("feature", entry.ref);

    // A lock entry from another source blocks a reinstall under that name
    // even when the directory is gone.
    try ws.deleteTree(io, ".ifnh/skills/mine");
    try std.testing.expectError(error.InstallFailed, cloneAndRegister(arena, io, ws, null, .{ .url = "file:///elsewhere", .name = "mine" }, &msg));
    try std.testing.expect(std.mem.indexOf(u8, msg, "different source") != null);

    // A bad ref is a clean git failure and leaves nothing behind.
    try std.testing.expectError(error.InstallFailed, cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url, .ref = "no-such-branch", .name = "other" }, &msg));
    try std.testing.expect(std.mem.startsWith(u8, msg, "git clone failed: "));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/other"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/.tmp-other"));
}

test "skills install: git failures surface the first stderr line and change nothing" {
    const io = std.testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ws = try workspaceIn(arena, io, &tmp);
    defer ws.close(io);
    var msg: []const u8 = "";
    try std.testing.expectError(error.InstallFailed, cloneAndRegister(arena, io, ws, null, .{ .url = "file:///definitely/not/a/repo" }, &msg));
    try std.testing.expect(std.mem.startsWith(u8, msg, "git clone failed: "));
    try std.testing.expect(std.mem.indexOfScalar(u8, msg, '\n') == null);
    try std.testing.expect(!fsutil.fileExists(ws, io, lock_mod.path));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/repo"));
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/.tmp-repo"));
}

test "skills install: a repo without SKILL.md installs but reports it; depth 2 counts" {
    const io = std.testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ws = try workspaceIn(arena, io, &tmp);
    defer ws.close(io);
    var msg: []const u8 = "";

    const plain = try makeRepo(arena, io, &tmp, "up/plain", &.{.{ "README.md", "hi" }});
    const none = try cloneAndRegister(arena, io, ws, null, .{ .url = plain.url }, &msg);
    try std.testing.expect(!none.has_skill_md);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/plain/README.md")); // kept anyway

    const nested = try makeRepo(arena, io, &tmp, "up/nested", &.{.{ "a/b/SKILL.md", fixture_skill_md }});
    try std.testing.expect((try cloneAndRegister(arena, io, ws, null, .{ .url = nested.url }, &msg)).has_skill_md);

    const too_deep = try makeRepo(arena, io, &tmp, "up/deep", &.{.{ "a/b/c/SKILL.md", fixture_skill_md }});
    try std.testing.expect(!(try cloneAndRegister(arena, io, ws, null, .{ .url = too_deep.url }, &msg)).has_skill_md);
}

test "skills remove: deletes the directory and the lock entry; unknown names are reported" {
    const io = std.testing.io;
    if (!gitAvailable(io)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const upstream = try makeRepo(arena, io, &tmp, "up/fixture", &.{.{ "SKILL.md", fixture_skill_md }});
    var ws = try workspaceIn(arena, io, &tmp);
    defer ws.close(io);
    var msg: []const u8 = "";
    _ = try cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url, .name = "one" }, &msg);
    _ = try cloneAndRegister(arena, io, ws, null, .{ .url = upstream.url, .name = "two" }, &msg);
    try std.testing.expect(isInstalled(ws, io, arena, "one"));

    try remove(arena, io, ws, "one", &msg);
    try std.testing.expect(!fsutil.fileExists(ws, io, ".ifnh/skills/one"));
    const lock = try lock_mod.read(ws, io, arena);
    try std.testing.expect(lock.get("one") == null and lock.get("two") != null);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/two/SKILL.md"));
    try std.testing.expect(!isInstalled(ws, io, arena, "one"));

    try std.testing.expectError(error.InstallFailed, remove(arena, io, ws, "one", &msg));
    try std.testing.expectEqualStrings("skill 'one' is not installed", msg);
    // A path-shaped name never reaches the filesystem.
    try std.testing.expectError(error.InstallFailed, remove(arena, io, ws, "../two", &msg));
    try std.testing.expectEqualStrings("skill '../two' is not installed", msg);
    try std.testing.expect(fsutil.fileExists(ws, io, ".ifnh/skills/two/SKILL.md"));
}

test "skills install and remove stop at a malformed lockfile without touching it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, ".ifnh/skills/keep");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/keep/SKILL.md", .data = fixture_skill_md });
    try tmp.dir.writeFile(io, .{ .sub_path = lock_mod.path, .data = "{ nope" });
    var msg: []const u8 = "";
    try std.testing.expectError(error.InstallFailed, cloneAndRegister(arena, io, tmp.dir, null, .{ .url = "file:///x", .name = "new" }, &msg));
    try std.testing.expectEqualStrings("skills lockfile is not valid JSON: .ifnh/skills.lock.json", msg);
    try std.testing.expectError(error.InstallFailed, remove(arena, io, tmp.dir, "keep", &msg));
    try std.testing.expectEqualStrings("skills lockfile is not valid JSON: .ifnh/skills.lock.json", msg);
    try std.testing.expect(fsutil.fileExists(tmp.dir, io, ".ifnh/skills/keep/SKILL.md"));
    try std.testing.expectEqualStrings("{ nope", try tmp.dir.readFileAlloc(io, lock_mod.path, arena, .limited(1024)));
}
