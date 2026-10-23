//! Per-turn prologue memoisation (ACTIVE_PLAN B-04).
//!
//! The turn prologue re-reads config, re-assembles instructions, re-renders
//! the skills catalog and probes git every turn, even when nothing on disk
//! changed. Here each of those inputs is keyed on a stat-only signature:
//! path, kind, size, mtime and ctime are hashed, contents are never read.
//! An unchanged signature returns the memoised result, a changed one redoes
//! the work. `ctime` is included on purpose: it is not settable by
//! unprivileged code, so rewriting a file and restoring its mtime still
//! invalidates the entry (the policy fingerprint relies on this).
//!
//! Counters in `Cache.work` record what was actually rebuilt; the B-01 spans
//! and trace notes show the saving. State lives in the REPL `Session`, never
//! in globals.

const std = @import("std");
const instructions_mod = @import("instructions.zig");
const skills_mod = @import("skills.zig");
const git_mod = @import("git.zig");

/// Hash of "path missing"; distinguishable from a present, empty file.
pub const absent: u64 = 0xcbf29ce484222325;

/// FNV-1a 64 over a stat-only view of `paths` relative to `dir`.
/// Directories are recursed `max_depth` levels so a changed child file (an
/// `.ifnh/instructions/*.md`, a `SKILL.md`) is noticed; file contents are
/// never read.
pub fn signature(
    dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    paths: []const []const u8,
    max_depth: u8,
) u64 {
    var h: u64 = absent;
    for (paths) |p| {
        if (p.len == 0) continue;
        hashPath(&h, dir, io, arena, p, max_depth);
    }
    return h;
}

fn hashPath(h: *u64, dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8, depth: u8) void {
    const stat = dir.statFile(io, path, .{}) catch {
        mix(h, absent);
        mixString(h, path);
        return;
    };
    mixString(h, path);
    mix(h, @as(u64, @intFromEnum(stat.kind)));
    mix(h, stat.size);
    // Truncated to nanoseconds in a u64: enough to tell writes apart.
    mix(h, @truncate(@as(u96, @bitCast(stat.mtime.nanoseconds))));
    mix(h, @truncate(@as(u96, @bitCast(stat.ctime.nanoseconds))));

    if (stat.kind != .directory or depth == 0) return;
    var d = dir.openDir(io, path, .{ .iterate = true }) catch return;
    defer d.close(io);

    // Sorted so the hash does not depend on directory order.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |name| {
        const child = std.fs.path.join(arena, &.{ path, name }) catch continue;
        hashPath(h, dir, io, arena, child, depth - 1);
    }
}

fn mix(h: *u64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    for (bytes) |b| {
        h.* ^= b;
        h.* *%= 0x100000001b3;
    }
}

fn mixString(h: *u64, s: []const u8) void {
    for (s) |b| {
        h.* ^= b;
        h.* *%= 0x100000001b3;
    }
}

/// What was actually rebuilt (observable by tests and traces).
pub const Work = struct {
    assemblies: usize = 0,
    skill_renders: usize = 0,
    git_probes: usize = 0,
};

pub const Prompt = struct {
    text: []const u8,
    /// Stable prefix length for provider prompt caching (B-03).
    stable_len: usize,
};

pub const Inputs = struct {
    workspace: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    builtin: []const u8,
    focus_dirs: []const []const u8,
    catalog: ?skills_mod.Catalog = null,
    skills_roots: []const []const u8 = &.{},
};

pub const Cache = struct {
    instr_sig: u64 = 0,
    instr_ready: bool = false,
    assembled: ?instructions_mod.Assembled = null,

    skills_sig: u64 = 0,
    skills_ready: bool = false,
    skills: ?[]const u8 = null,

    git_sig: u64 = 0,
    git_ready: bool = false,
    git: ?git_mod.Git = null,

    /// Last accepted prologue signature (config reload).
    prologue_sig: u64 = 0,
    prologue_ready: bool = false,

    work: Work = .{},

    /// Cheap "did anything change?" check for a caller-owned signature.
    pub fn stale(self: *const Cache, sig: u64) bool {
        return !self.prologue_ready or self.prologue_sig != sig;
    }

    pub fn accept(self: *Cache, sig: u64) void {
        self.prologue_sig = sig;
        self.prologue_ready = true;
    }

    /// Assemble the turn system prompt (instructions plus the skills catalog
    /// appendix), reusing the last result when the stat signatures are
    /// unchanged. The concatenation itself is per-turn; the file reads and
    /// rendering are not.
    pub fn systemPrompt(self: *Cache, in: Inputs) !Prompt {
        const instr_sig = try self.instrSignature(in);
        if (!self.instr_ready or self.instr_sig != instr_sig or self.assembled == null) {
            self.assembled = try instructions_mod.assemble(in.workspace, in.io, in.arena, in.builtin, in.focus_dirs);
            self.instr_sig = instr_sig;
            self.instr_ready = true;
            self.work.assemblies += 1;
        }
        const assembled = self.assembled.?;

        const skills_sig = self.skillsSignature(in);
        if (skills_sig != 0 and (!self.skills_ready or self.skills_sig != skills_sig or self.skills == null)) {
            const catalog = in.catalog orelse skills_mod.Catalog{ .skills = &.{} };
            self.skills = skills_mod.renderCatalog(in.arena, catalog) catch "";
            self.skills_sig = skills_sig;
            self.skills_ready = true;
            self.work.skill_renders += 1;
        }

        const rendered = self.skills orelse "";
        if (rendered.len == 0) {
            return .{ .text = assembled.text, .stable_len = assembled.stable_len };
        }
        return .{
            .text = try std.fmt.allocPrint(in.arena, "{s}\n\nAvailable skills (load with the skill tool):\n{s}", .{ assembled.text, rendered }),
            .stable_len = assembled.stable_len,
        };
    }

    fn instrSignature(self: *Cache, in: Inputs) !u64 {
        _ = self;
        var paths: std.ArrayListUnmanaged([]const u8) = .empty;
        try paths.appendSlice(in.arena, &.{ "AGENTS.md", "CLAUDE.md", ".ifnh/instructions" });
        var h: u64 = 0;
        for (in.focus_dirs) |dir| {
            if (dir.len == 0 or std.mem.eql(u8, dir, ".")) continue;
            mixString(&h, dir);
            try paths.append(in.arena, try std.fmt.allocPrint(in.arena, "{s}/AGENTS.md", .{dir}));
        }
        mix(&h, signature(in.workspace, in.io, in.arena, paths.items, 1));
        return h;
    }

    fn skillsSignature(self: *Cache, in: Inputs) u64 {
        _ = self;
        if (in.skills_roots.len == 0) return 0;
        return signature(in.workspace, in.io, in.arena, in.skills_roots, 2);
    }

    /// `git rev-parse` costs a subprocess, so the probe result is memoised on
    /// the repository's `HEAD` and `.git` (branch switch, checkout, commit).
    pub fn gitRepo(self: *Cache, workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, repo_path: []const u8) ?git_mod.Git {
        const paths = [_][]const u8{ ".git/HEAD", ".git" };
        const sig = signature(workspace, io, arena, &paths, 0);
        if (self.git_ready and self.git_sig == sig) return self.git;

        var g = git_mod.Git.init(io, repo_path);
        const found: ?git_mod.Git = if (g.isRepo(arena)) g else null;
        self.git = found;
        self.git_sig = sig;
        self.git_ready = true;
        self.work.git_probes += 1;
        return found;
    }
};

// ---------------------------------------------------------------- tests

test "signature is stable and notices content, size and nested changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = [_][]const u8{ "AGENTS.md", ".ifnh/instructions" };

    const before = signature(tmp.dir, io, arena, &paths, 1);
    try std.testing.expectEqual(before, signature(tmp.dir, io, arena, &paths, 1));

    // Missing files are part of the signature: creating one changes it.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "a" });
    const created = signature(tmp.dir, io, arena, &paths, 1);
    try std.testing.expect(before != created);

    // Same size, new content: mtime (and ctime) move.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "b" });
    const edited = signature(tmp.dir, io, arena, &paths, 1);
    try std.testing.expect(created != edited);

    // A file nested inside a watched directory is noticed too, without
    // reading anything.
    try tmp.dir.createDirPath(io, ".ifnh/instructions");
    const empty_dir = signature(tmp.dir, io, arena, &paths, 1);
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/x.md", .data = "rules" });
    try std.testing.expect(empty_dir != signature(tmp.dir, io, arena, &paths, 1));
}

test "systemPrompt memoises assembly and skills rendering" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = "src rules" });
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/AGENTS.md", .data = "docs rules" });
    try tmp.dir.createDirPath(io, ".ifnh/skills/demo");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".ifnh/skills/demo/SKILL.md",
        .data = "---\nname: demo\ndescription: demo skill\n---\nbody\n",
    });

    var catalog = try skills_mod.discover(tmp.dir, io, arena, null);
    var cache: Cache = .{};

    const focus_src = [_][]const u8{"src"};
    const focus_docs = [_][]const u8{"docs"};
    const roots = [_][]const u8{".ifnh/skills"};

    const first = try cache.systemPrompt(.{
        .workspace = tmp.dir,
        .io = io,
        .arena = arena,
        .builtin = "builtin",
        .focus_dirs = &focus_src,
        .catalog = catalog,
        .skills_roots = &roots,
    });
    try std.testing.expectEqual(@as(usize, 1), cache.work.assemblies);
    try std.testing.expectEqual(@as(usize, 1), cache.work.skill_renders);
    try std.testing.expect(std.mem.indexOf(u8, first.text, "demo skill") != null);

    // Second turn, nothing changed: same bytes, no work.
    const second = try cache.systemPrompt(.{
        .workspace = tmp.dir,
        .io = io,
        .arena = arena,
        .builtin = "builtin",
        .focus_dirs = &focus_src,
        .catalog = catalog,
        .skills_roots = &roots,
    });
    try std.testing.expectEqualStrings(first.text, second.text);
    try std.testing.expectEqual(@as(usize, 1), cache.work.assemblies);
    try std.testing.expectEqual(@as(usize, 1), cache.work.skill_renders);

    // A different focus dir re-assembles (the tail changes, the stable
    // prefix does not) but keeps the cached skills render.
    const third = try cache.systemPrompt(.{
        .workspace = tmp.dir,
        .io = io,
        .arena = arena,
        .builtin = "builtin",
        .focus_dirs = &focus_docs,
        .catalog = catalog,
        .skills_roots = &roots,
    });
    try std.testing.expectEqual(@as(usize, 2), cache.work.assemblies);
    try std.testing.expectEqual(@as(usize, 1), cache.work.skill_renders);
    try std.testing.expectEqualStrings(first.text[0..first.stable_len], third.text[0..third.stable_len]);
    try std.testing.expect(!std.mem.eql(u8, first.text, third.text));

    // Touching an instruction file invalidates the prompt.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules v2" });
    const fourth = try cache.systemPrompt(.{
        .workspace = tmp.dir,
        .io = io,
        .arena = arena,
        .builtin = "builtin",
        .focus_dirs = &focus_src,
        .catalog = catalog,
        .skills_roots = &roots,
    });
    try std.testing.expectEqual(@as(usize, 3), cache.work.assemblies);
    try std.testing.expect(std.mem.indexOf(u8, fourth.text, "repo rules v2") != null);

    // A new skill file invalidates the catalog render.
    try tmp.dir.createDirPath(io, ".ifnh/skills/other");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".ifnh/skills/other/SKILL.md",
        .data = "---\nname: other\ndescription: other skill\n---\nbody\n",
    });
    catalog = try skills_mod.discover(tmp.dir, io, arena, null);
    _ = try cache.systemPrompt(.{
        .workspace = tmp.dir,
        .io = io,
        .arena = arena,
        .builtin = "builtin",
        .focus_dirs = &focus_src,
        .catalog = catalog,
        .skills_roots = &roots,
    });
    try std.testing.expectEqual(@as(usize, 2), cache.work.skill_renders);
}

test "gitRepo memoises the probe until HEAD changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `git` runs with an absolute cwd, as the REPL does it.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    // A real repository, so the probe result is true and HEAD invalidates it.
    const init = std.process.run(arena, io, .{
        .argv = &.{ "git", "init", "-q" },
        .cwd = .{ .path = path },
    }) catch return error.SkipZigTest;
    if (init.term != .exited or init.term.exited != 0) return error.SkipZigTest;

    var cache: Cache = .{};
    try std.testing.expect(cache.gitRepo(tmp.dir, io, arena, path) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.work.git_probes);
    // Unchanged repo: memo hit, no second subprocess.
    try std.testing.expect(cache.gitRepo(tmp.dir, io, arena, path) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.work.git_probes);

    // A branch switch rewrites HEAD and must re-probe.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/other\n" });
    try std.testing.expect(cache.gitRepo(tmp.dir, io, arena, path) != null);
    try std.testing.expectEqual(@as(usize, 2), cache.work.git_probes);
}
