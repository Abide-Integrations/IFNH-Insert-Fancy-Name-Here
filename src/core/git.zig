//! Git integration via the git binary (DECISIONS U280, L162-178).
//!
//! Porcelain commands only. All functions are best-effort: a missing or
//! broken git degrades features (worktrees) rather than failing the app
//! (L162: git is optional, unlocking worktrees/branches).

const std = @import("std");

pub const max_output: usize = 1024 * 1024;

pub const Git = struct {
    io: std.Io,
    /// Absolute path of the directory git commands run in (repo root or any
    /// repo dir). Path-based cwd: Dir-handle cwd is unreliable for children.
    dir_path: []const u8,
    /// Optional extra environment (e.g. GIT_CEILING_DIRECTORIES in tests).
    env: ?*const std.process.Environ.Map = null,

    pub fn init(io: std.Io, dir_path: []const u8) Git {
        return .{ .io = io, .dir_path = dir_path };
    }

    fn run(self: Git, arena: std.mem.Allocator, argv: []const []const u8) ?std.process.RunResult {
        return std.process.run(arena, self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.dir_path },
            .environ_map = self.env,
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
        }) catch return null;
    }

    /// True when `dir` is inside a git work tree.
    pub fn isRepo(self: Git, arena: std.mem.Allocator) bool {
        const r = self.run(arena, &.{ "git", "rev-parse", "--is-inside-work-tree" }) orelse return false;
        return r.term == .exited and r.term.exited == 0 and
            std.mem.startsWith(u8, std.mem.trim(u8, r.stdout, " \n\r\t"), "true");
    }

    pub fn dirtyCount(self: Git, arena: std.mem.Allocator) usize {
        const r = self.run(arena, &.{ "git", "status", "--porcelain" }) orelse return 0;
        if (r.term != .exited or r.term.exited != 0) return 0;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |line| {
            if (line.len > 0) n += 1;
        }
        return n;
    }

    pub const WorktreeError = error{
        NotARepo,
        GitFailed,
        BranchExists,
        OutOfMemory,
    };

    /// `git worktree add -b <branch> <path>` — creates the branch and a
    /// working tree checked out at it.
    pub fn addWorktree(self: Git, arena: std.mem.Allocator, path: []const u8, branch: []const u8) WorktreeError!void {
        if (!self.isRepo(arena)) return error.NotARepo;
        // Caller ensures the parent directory of `path` exists.
        const r = self.run(arena, &.{ "git", "worktree", "add", "-b", branch, path }) orelse return error.GitFailed;
        if (r.term != .exited or r.term.exited != 0) {
            if (std.mem.indexOf(u8, r.stderr, "already exists") != null) return error.BranchExists;
            return error.GitFailed;
        }
    }

    /// `git worktree remove --force <path>` (agent-created trees only).
    pub fn removeWorktree(self: Git, arena: std.mem.Allocator, path: []const u8) WorktreeError!void {
        const r = self.run(arena, &.{ "git", "worktree", "remove", "--force", path }) orelse return error.GitFailed;
        if (r.term != .exited or r.term.exited != 0) return error.GitFailed;
    }

    /// Diff between the worktree and its base (working tree diff inside it).
    pub fn diffWorktree(self: Git, arena: std.mem.Allocator, worktree_path: []const u8) []const u8 {
        const r = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "diff", "HEAD" },
            .cwd = .{ .path = worktree_path },
            .stdout_limit = .limited(max_output),
            .stderr_limit = .limited(64 * 1024),
        }) catch return "";
        if (r.term != .exited or r.term.exited != 0) return "";
        return r.stdout;
    }

    /// Current branch name (empty when detached/unknown).
    pub fn currentBranch(self: Git, arena: std.mem.Allocator) []const u8 {
        const r = self.run(arena, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse return "";
        if (r.term != .exited or r.term.exited != 0) return "";
        return std.mem.trim(u8, r.stdout, " \n\r\t");
    }
};

// ---------------------------------------------------------------- tests

fn gitAvailable() bool {
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "git", "--version" },
    }) catch return false;
    const ok = r.term == .exited and r.term.exited == 0;
    std.testing.allocator.free(r.stdout);
    std.testing.allocator.free(r.stderr);
    return ok;
}

test "worktree add/remove round trip in a real temp repo" {
    if (!gitAvailable()) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Resolve the tmp dir to an absolute path.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const repo_path = try arena.dupe(u8, path_buf[0..n]);

    // Init a repo with a commit.
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "init", "-q", "-b", "main" }, .cwd = .{ .path = repo_path } }) catch return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "seed.txt", .data = "seed\n" });
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "add", "." }, .cwd = .{ .path = repo_path } }) catch {};
    _ = std.process.run(arena, io, .{ .argv = &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "seed" }, .cwd = .{ .path = repo_path } }) catch {};

    var g = Git.init(io, repo_path);
    try std.testing.expect(g.isRepo(arena));

    const wt_path = try std.fmt.allocPrint(arena, "{s}/worktrees/wt-test", .{repo_path});
    try g.addWorktree(arena, wt_path, "ifnh/test-1");
    try std.testing.expectError(error.BranchExists, g.addWorktree(arena, wt_path, "ifnh/test-1b"));

    // The worktree contains the seed file.
    const seed_file = try std.fmt.allocPrint(arena, "{s}/seed.txt", .{wt_path});
    const seed = try std.Io.Dir.cwd().readFileAlloc(io, seed_file, arena, .limited(1024));
    try std.testing.expectEqualStrings("seed\n", seed);

    try g.removeWorktree(arena, wt_path);
}

test "non-git dir is not a repo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir_path = try arena_state.allocator().dupe(u8, path_buf[0..n]);
    // Stop repo discovery from walking above the tmp dir (the test CWD may
    // itself be inside a repository).
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const parent = std.fs.path.dirname(dir_path) orelse "/";
    try env.put("GIT_CEILING_DIRECTORIES", parent);
    var g = Git.init(io, dir_path);
    g.env = &env;
    try std.testing.expect(!g.isRepo(arena_state.allocator()));
}
