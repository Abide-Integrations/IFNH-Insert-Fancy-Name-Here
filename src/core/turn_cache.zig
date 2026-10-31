//! Session-owned memoisation of the per-turn prologue (B-04).
//!
//! The REPL rebuilds the config, the instruction set, the skills catalog,
//! the git repo state and the policy hash on every turn, all of them from a
//! small set of files. Each piece lives behind its own stat fingerprint
//! (path, presence, size, mtime; directory listings for tree-shaped
//! sources) and is reused until that fingerprint changes, so editing one
//! source invalidates only the piece that reads it. The policy hash, whose
//! answer a stat cannot prove, keeps a content hash that is recomputed only
//! when its stat fingerprint moves.
//!
//! There are no globals: the cache is owned by the REPL session and passed
//! by pointer. Cached payloads are allocated in the session arena, so an
//! invalidation costs memory only when a source actually changed.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const instructions_mod = @import("instructions.zig");
const skills_mod = @import("skills.zig");
const git_mod = @import("git.zig");

pub const Fingerprint = [32]u8;

/// A cached value plus whether this lookup reused it.
pub fn Lookup(comptime T: type) type {
    return struct { value: T, hit: bool };
}

fn Entry(comptime T: type) type {
    return struct { fp: Fingerprint, value: T };
}

const sha = std.crypto.hash.sha2;

/// Stat fingerprint builder. Every source contributes its path, its
/// presence, its size and its mtime.
const Hasher = struct {
    hash: sha.Sha256,

    fn init() Hasher {
        return .{ .hash = sha.Sha256.init(.{}) };
    }

    fn addStat(self: *Hasher, st: std.Io.File.Stat) void {
        var buf: [20]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], st.size, .little);
        std.mem.writeInt(i96, buf[8..20], st.mtime.nanoseconds, .little);
        self.hash.update(&buf);
    }

    /// Hash a single path. A missing path is part of the fingerprint, so a
    /// file appearing (or disappearing) invalidates the piece.
    fn addPath(self: *Hasher, dir: std.Io.Dir, io: std.Io, path: []const u8) void {
        self.hash.update(path);
        const st = dir.statFile(io, path, .{}) catch {
            self.hash.update("\x00absent");
            return;
        };
        self.addStat(st);
    }

    /// Hash a directory's sorted entries. Each entry contributes its name
    /// and own stat; a subdirectory also contributes its `SKILL.md`, whose
    /// rewrite does not change the parent directory's mtime.
    fn addDir(self: *Hasher, io: std.Io, dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) void {
        self.hash.update(path);
        var handle = dir.openDir(io, path, .{ .iterate = true }) catch {
            self.hash.update("\x00absent");
            return;
        };
        defer handle.close(io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = handle.iterate();
        while (it.next(io) catch null) |entry| {
            const name = std.fmt.allocPrint(alloc, "{s}", .{entry.name}) catch continue;
            names.append(alloc, name) catch continue;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            self.hash.update(name);
            const st = handle.statFile(io, name, .{}) catch {
                self.hash.update("\x00absent");
                continue;
            };
            self.addStat(st);
            if (st.kind == .directory) {
                const child = std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{name}) catch continue;
                self.addPath(handle, io, child);
            }
        }
    }

    fn final(self: *Hasher) Fingerprint {
        var out: Fingerprint = undefined;
        self.hash.final(&out);
        return out;
    }
};

pub const TurnCache = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    config_fp: ?Fingerprint = null,
    instr: ?Entry(instructions_mod.Assembled) = null,
    skills: ?Entry([]const u8) = null,
    git: ?Entry(?git_mod.Git) = null,
    policy: ?Entry([32]u8) = null,

    pub fn init(io: std.Io, arena: std.mem.Allocator) TurnCache {
        return .{ .io = io, .arena = arena };
    }

    /// True when the config files changed since the last call (also true on
    /// the first call). The caller reloads only then (B-04).
    pub fn configChanged(self: *TurnCache, cwd: std.Io.Dir, user_config: ?[]const u8) bool {
        var h = Hasher.init();
        if (user_config) |path| h.addPath(std.Io.Dir.cwd(), self.io, path);
        h.addPath(cwd, self.io, ".ifnh/config.json");
        h.addDir(self.io, cwd, ".ifnh/config.d", self.arena);
        const fp = h.final();
        if (self.config_fp) |prev| {
            if (std.mem.eql(u8, &prev, &fp)) return false;
        }
        self.config_fp = fp;
        return true;
    }

    /// Forget the config fingerprint so the next turn reloads even though
    /// the files did not change (used when a reload failed).
    pub fn configInvalidate(self: *TurnCache) void {
        self.config_fp = null;
    }

    /// Instructions assembled for `focus_dirs`, reusing the previous result
    /// while the repository instruction files are untouched.
    pub fn instructions(
        self: *TurnCache,
        cwd: std.Io.Dir,
        builtin: []const u8,
        focus_dirs: []const []const u8,
    ) !Lookup(instructions_mod.Assembled) {
        var h = Hasher.init();
        h.addPath(cwd, self.io, "AGENTS.md");
        h.addPath(cwd, self.io, "CLAUDE.md");
        h.addDir(self.io, cwd, ".ifnh/instructions", self.arena);
        for (focus_dirs) |dir| {
            if (dir.len == 0 or std.mem.eql(u8, dir, ".")) continue;
            const path = try std.fmt.allocPrint(self.arena, "{s}/AGENTS.md", .{dir});
            h.addPath(cwd, self.io, path);
        }
        const fp = h.final();
        if (self.instr) |entry| {
            if (std.mem.eql(u8, &entry.fp, &fp)) return .{ .value = entry.value, .hit = true };
        }
        const value = try instructions_mod.assemble(cwd, self.io, self.arena, builtin, focus_dirs);
        self.instr = .{ .fp = fp, .value = value };
        return .{ .value = value, .hit = false };
    }

    /// Rendered skills catalog, re-rendered only when a skill file changes.
    pub fn skillsText(
        self: *TurnCache,
        cwd: std.Io.Dir,
        user_skills_dir: ?[]const u8,
        catalog: skills_mod.Catalog,
    ) !Lookup([]const u8) {
        var h = Hasher.init();
        if (user_skills_dir) |root| h.addDir(self.io, std.Io.Dir.cwd(), root, self.arena);
        for ([_][]const u8{ ".ifnh/skills", ".claude/skills", ".agents/skills" }) |root| {
            h.addDir(self.io, cwd, root, self.arena);
        }
        const fp = h.final();
        if (self.skills) |entry| {
            if (std.mem.eql(u8, &entry.fp, &fp)) return .{ .value = entry.value, .hit = true };
        }
        const value = try skills_mod.renderCatalog(self.arena, catalog);
        self.skills = .{ .fp = fp, .value = value };
        return .{ .value = value, .hit = false };
    }

    /// Git repo handle for `cwd`, re-probed only when HEAD, the index or the
    /// packed refs change.
    pub fn gitRepo(self: *TurnCache, cwd: std.Io.Dir) !Lookup(?git_mod.Git) {
        // Resolves via `realPathFile` and trusts a found `.git` (no git spawn); see B-11.
        const ws = git_mod.discover(self.io, self.arena, cwd) orelse return .{ .value = null, .hit = false };
        const repo_path = ws.repo_path;
        const git_dir = ws.git_dir;

        var h = Hasher.init();
        h.hash.update(repo_path);
        if (git_dir) |dir| {
            for ([_][]const u8{ "HEAD", "index", "packed-refs" }) |name| {
                const path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, name });
                h.addPath(std.Io.Dir.cwd(), self.io, path);
            }
        } else {
            h.hash.update("\x00no-git");
        }
        const fp = h.final();
        if (self.git) |entry| {
            if (std.mem.eql(u8, &entry.fp, &fp)) return .{ .value = entry.value, .hit = true };
        }
        self.git = .{ .fp = fp, .value = ws.git };
        return .{ .value = ws.git, .hit = false };
    }

    /// SHA-256 over the content of the policy-relevant files (G99/M0-T30),
    /// memoised on their stat fingerprint: unchanged stats reuse the hash,
    /// a touched file re-reads the content. Null when no policy file exists.
    /// `.ifnh/permissions.local.json` is deliberately absent from the files
    /// hashed here and in `contentHash`: it is a grants store written by the
    /// user's own `p` answer, not policy (C-05).
    pub fn policyHash(self: *TurnCache, cwd: std.Io.Dir) ?[32]u8 {
        var h = Hasher.init();
        for ([_][]const u8{ ".ifnh/config.json", "AGENTS.md", "CLAUDE.md" }) |path| {
            h.addPath(cwd, self.io, path);
        }
        for ([_][]const u8{ ".ifnh/config.d", ".ifnh/lifecycle", ".ifnh/instructions", ".ifnh/commands", ".ifnh/skills" }) |path| {
            h.addDir(self.io, cwd, path, self.arena);
        }
        const fp = h.final();
        if (self.policy) |entry| {
            if (std.mem.eql(u8, &entry.fp, &fp)) return entry.value;
        }
        const digest = contentHash(self.io, self.arena, cwd) orelse {
            self.policy = null;
            return null;
        };
        self.policy = .{ .fp = fp, .value = digest };
        return digest;
    }
};

/// Content hash of the policy-relevant files (same set the approval gate
/// checks in `cli/repl.zig`). Null when none of them exist.
fn contentHash(io: std.Io, arena: std.mem.Allocator, cwd: std.Io.Dir) ?[32]u8 {
    var hasher = sha.Sha256.init(.{});
    const files = [_][]const u8{
        ".ifnh/config.json",
        ".ifnh/config.d",
        ".ifnh/lifecycle",
        ".ifnh/instructions",
        ".ifnh/commands",
        ".ifnh/skills",
        "AGENTS.md",
        "CLAUDE.md",
    };
    var any = false;
    for (files) |path| {
        const st = cwd.statFile(io, path, .{}) catch continue;
        any = true;
        hasher.update(path);
        if (st.kind == .directory) {
            var handle = cwd.openDir(io, path, .{ .iterate = true }) catch continue;
            defer handle.close(io);
            var it = handle.iterate();
            while (it.next(io) catch null) |entry| {
                hasher.update(entry.name);
                const child = std.fmt.allocPrint(arena, "{s}/{s}", .{ path, entry.name }) catch continue;
                if (fsutil.readSmallFile(cwd, io, arena, child, 1024 * 1024)) |content| {
                    hasher.update(content);
                } else |_| {}
            }
        } else if (fsutil.readSmallFile(cwd, io, arena, path, 1024 * 1024)) |content| {
            hasher.update(content);
        } else |_| {}
    }
    if (!any) return null;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

// ---------------------------------------------------------------- tests

/// Force an mtime-only change (same size, same bytes except when `data` is
/// given) so invalidation cannot be explained by a size change.
fn touch(io: std.Io, dir: std.Io.Dir, path: []const u8, ns: i96) !void {
    try dir.setTimestamps(io, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = ns } } });
}

test "turn cache config hits and misses on its own files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = TurnCache.init(io, arena_state.allocator());

    // No config files: the first call is a miss, the second a hit.
    try std.testing.expect(cache.configChanged(tmp.dir, null));
    try std.testing.expect(!cache.configChanged(tmp.dir, null));

    // A new project config file invalidates.
    try tmp.dir.createDirPath(io, ".ifnh");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = "{}" });
    try std.testing.expect(cache.configChanged(tmp.dir, null));
    try std.testing.expect(!cache.configChanged(tmp.dir, null));

    // An mtime-only touch invalidates too.
    try touch(io, tmp.dir, ".ifnh/config.json", 2_000_000_000);
    try std.testing.expect(cache.configChanged(tmp.dir, null));

    // Invalidating after a failed reload forces a retry.
    cache.configInvalidate();
    try std.testing.expect(cache.configChanged(tmp.dir, null));
}

test "turn cache instructions reuse until a source changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "repo rules" });
    try tmp.dir.createDirPath(io, "src/core");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/AGENTS.md", .data = "core rules" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = TurnCache.init(io, arena_state.allocator());
    const focus = [_][]const u8{"src/core"};

    const first = try cache.instructions(tmp.dir, "builtin", &focus);
    try std.testing.expect(!first.hit);
    try std.testing.expect(std.mem.indexOf(u8, first.value.text, "core rules") != null);

    const second = try cache.instructions(tmp.dir, "builtin", &focus);
    try std.testing.expect(second.hit);
    try std.testing.expectEqualStrings(first.value.text, second.value.text);
    try std.testing.expectEqual(first.value.stable_len, second.value.stable_len);

    // A skills change does not invalidate instructions.
    try tmp.dir.createDirPath(io, ".ifnh/skills/a");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/a/SKILL.md", .data = "---\nname: a\n---\nbody" });
    try std.testing.expect((try cache.instructions(tmp.dir, "builtin", &focus)).hit);

    // A focus-dir instruction file invalidates (the volatile tail changes).
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/AGENTS.md", .data = "core rules v2" });
    const third = try cache.instructions(tmp.dir, "builtin", &focus);
    try std.testing.expect(!third.hit);
    try std.testing.expect(std.mem.indexOf(u8, third.value.text, "core rules v2") != null);

    // ...and the stable prefix offset is unchanged by it (B-03).
    try std.testing.expectEqual(first.value.stable_len, third.value.stable_len);

    // A repo-level instruction file invalidates after a hit.
    try std.testing.expect((try cache.instructions(tmp.dir, "builtin", &focus)).hit);
    try touch(io, tmp.dir, "AGENTS.md", 3_000_000_000);
    try std.testing.expect(!(try cache.instructions(tmp.dir, "builtin", &focus)).hit);
}

test "turn cache skills invalidate only on skill changes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".ifnh/skills/pdf");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/pdf/SKILL.md", .data = "---\nname: pdf\ndescription: Review PDFs\n---\nbody" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache = TurnCache.init(io, arena);

    const catalog = try skills_mod.discover(tmp.dir, io, arena, null);
    const first = try cache.skillsText(tmp.dir, null, catalog);
    try std.testing.expect(!first.hit);
    try std.testing.expect(std.mem.indexOf(u8, first.value, "pdf: Review PDFs") != null);

    try std.testing.expect((try cache.skillsText(tmp.dir, null, catalog)).hit);

    // Touching the skill file invalidates the catalog; instructions do not
    // depend on it.
    try touch(io, tmp.dir, ".ifnh/skills/pdf/SKILL.md", 4_000_000_000);
    try std.testing.expect(!(try cache.skillsText(tmp.dir, null, catalog)).hit);

    // A new skill directory invalidates as well.
    try tmp.dir.createDirPath(io, ".ifnh/skills/zip");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/zip/SKILL.md", .data = "---\nname: zip\n---\nbody" });
    try std.testing.expect(!(try cache.skillsText(tmp.dir, null, catalog)).hit);
}

test "turn cache git signature tracks head and index" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/index", .data = "idx" });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = TurnCache.init(io, arena_state.allocator());

    const first = try cache.gitRepo(tmp.dir);
    try std.testing.expect(!first.hit);
    try std.testing.expect(first.value != null);
    try std.testing.expect((try cache.gitRepo(tmp.dir)).hit);

    // Moving HEAD (same size) invalidates.
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/dev \n" });
    try std.testing.expect(!(try cache.gitRepo(tmp.dir)).hit);
    try std.testing.expect((try cache.gitRepo(tmp.dir)).hit);

    // Staging a change touches the index (mtime-only here).
    try touch(io, tmp.dir, ".git/index", 5_000_000_000);
    try std.testing.expect(!(try cache.gitRepo(tmp.dir)).hit);
}

test "turn cache policy hash follows content and memoises on stats" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = TurnCache.init(io, arena_state.allocator());

    // No policy files at all: no hash.
    try std.testing.expect(cache.policyHash(tmp.dir) == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "rules" });
    const a = cache.policyHash(tmp.dir).?;
    const b = cache.policyHash(tmp.dir).?;
    try std.testing.expectEqualSlices(u8, &a, &b);

    // New content, same stat shape class: the hash must follow it.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "other" });
    try touch(io, tmp.dir, "AGENTS.md", 6_000_000_000);
    const c = cache.policyHash(tmp.dir).?;
    try std.testing.expect(!std.mem.eql(u8, &a, &c));

    // Back to the original content: the hash returns to the original value.
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "rules" });
    try touch(io, tmp.dir, "AGENTS.md", 7_000_000_000);
    const d = cache.policyHash(tmp.dir).?;
    try std.testing.expectEqualSlices(u8, &a, &d);
}

test "policy hash ignores the grants file but follows config and instructions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cache = TurnCache.init(io, arena_state.allocator());

    try tmp.dir.createDirPath(io, ".ifnh/instructions");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/a.md", .data = "be kind" });
    const base = cache.policyHash(tmp.dir).?;

    // (i) Answering `p` writes this file mid-session; it is grants, not policy.
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/permissions.local.json", .data = "{\"version\":1,\"path_write\":[\"src/a.zig\"]}\n" });
    try touch(io, tmp.dir, ".ifnh/permissions.local.json", 8_000_000_000);
    try std.testing.expectEqualSlices(u8, &base, &cache.policyHash(tmp.dir).?);

    // (ii) Real policy still moves the hash.
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = "{\"git\":{}}" });
    try touch(io, tmp.dir, ".ifnh/config.json", 9_000_000_000);
    const edited_config = cache.policyHash(tmp.dir).?;
    try std.testing.expect(!std.mem.eql(u8, &base, &edited_config));

    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/instructions/a.md", .data = "be unkind" });
    try touch(io, tmp.dir, ".ifnh/instructions/a.md", 10_000_000_000);
    try std.testing.expect(!std.mem.eql(u8, &edited_config, &cache.policyHash(tmp.dir).?));
}

test "stat fingerprint distinguishes size, mtime and presence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "one" });
    var h = Hasher.init();
    h.addPath(tmp.dir, io, "a");
    const before = h.final();

    var h2 = Hasher.init();
    h2.addPath(tmp.dir, io, "a");
    try std.testing.expectEqualSlices(u8, &before, &h2.final());

    try touch(io, tmp.dir, "a", 8_000_000_000);
    var h3 = Hasher.init();
    h3.addPath(tmp.dir, io, "a");
    try std.testing.expect(!std.mem.eql(u8, &before, &h3.final()));

    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "one more" });
    var h4 = Hasher.init();
    h4.addPath(tmp.dir, io, "a");
    try std.testing.expect(!std.mem.eql(u8, &before, &h4.final()));

    var h5 = Hasher.init();
    h5.addPath(tmp.dir, io, "missing");
    var h6 = Hasher.init();
    h6.addPath(tmp.dir, io, "missing");
    try std.testing.expectEqualSlices(u8, &h5.final(), &h6.final());
    try std.testing.expect(!std.mem.eql(u8, &before, &h5.final()));
}
