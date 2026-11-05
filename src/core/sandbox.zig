//! OS sandbox for model-issued shell commands (E-04, DECISIONS N189-N200).
//!
//! Best effort, per platform: bubblewrap or Landlock on Linux, Seatbelt on
//! macOS. A sandbox wraps the command's `argv`; this module never runs
//! anything itself except the detection probes and the hidden `__sandbox-exec`
//! helper that applies a Landlock ruleset to its own process before `exec`.
//!
//! Scope is decided by the caller: `bash`, data-defined custom tools and
//! background executions use it; the human's `!cmd` and the `git` tool never
//! do. The backend is resolved once per session (`Session.resolve`) and
//! handed down; nothing here is cached globally.
//!
//! Filesystem policy: the whole disk is readable, writes are allowed only in
//! the workspace, the temp dir, `sandbox.write_extra` and `/dev/null`. The
//! network is denied unless `sandbox.network` is true. Limits worth knowing:
//! Landlock denies TCP connect/bind only (ABI 4+, Linux 6.7+); UDP and unix
//! sockets stay open there. bwrap does not unshare the user namespace
//! (`--unshare-user` breaks setups where the unprivileged user namespace is
//! already owned by a setuid bwrap or a container runtime).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Mode = enum {
    off,
    auto,
    required,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

pub const Backend = enum { none, bwrap, landlock, seatbelt };

/// `sandbox.*` config values.
pub const Settings = struct {
    mode: Mode = .off,
    network: bool = false,
    write_extra: []const []const u8 = &.{},
};

/// All paths must be absolute and normalized.
pub const Policy = struct {
    workspace: []const u8,
    write_extra: []const []const u8 = &.{},
    network: bool = false,
    tmp: []const u8,
    /// Absolute path of the running `ifnh`, re-executed as the Landlock
    /// helper. Empty when the host is not `ifnh` (embedding): Landlock is then
    /// unsupported.
    exe: []const u8 = "",
};

/// `argv` runs the command; `unsupported` carries the reason it cannot be
/// sandboxed (the caller refuses the call).
pub const Wrapped = union(enum) {
    argv: []const []const u8,
    unsupported: []const u8,
};

/// Host hook: build the argv for one model-issued command. Null on the tool
/// context disables sandboxing.
pub const WrapFn = *const fn (ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) Wrapped;

pub const unavailable_notice = "sandbox backend unavailable; running unsandboxed";

/// Environment variable the parent sets so `__sandbox-exec` cannot be run by
/// accident from a user's shell.
pub const exec_env = "IFNH_SANDBOX_EXEC";
pub const exec_subcommand = "__sandbox-exec";

pub fn unavailableReason() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "neither bwrap nor Landlock is usable on this system",
        .macos => "/usr/bin/sandbox-exec not found",
        else => "no sandbox backend exists for this platform",
    };
}

// ---------------------------------------------------------------- detection

/// First usable backend. Linux: a bwrap that can actually build its
/// namespaces (probed by running it), else Landlock when the kernel reports
/// an ABI; macOS: `/usr/bin/sandbox-exec`.
pub fn detect(io: std.Io, environ: *const std.process.Environ.Map) Backend {
    switch (builtin.os.tag) {
        .linux => {
            if (bwrapWorks(io, environ)) return .bwrap;
            if (landlockAbi() != null) return .landlock;
            return .none;
        },
        .macos => {
            std.Io.Dir.accessAbsolute(io, "/usr/bin/sandbox-exec", .{}) catch return .none;
            return .seatbelt;
        },
        else => return .none,
    }
}

fn bwrapWorks(io: std.Io, environ: *const std.process.Environ.Map) bool {
    const argv = [_][]const u8{
        "bwrap",     "--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
        "--ro-bind", "/",                 "/",             "--dev",         "/dev",
        "--proc",    "/proc",             "--",            "/bin/true",
    };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Landlock ABI version, or null when the syscall is missing or Landlock is
/// disabled (ENOSYS / EOPNOTSUPP). Linux only.
pub fn landlockAbi() ?u32 {
    if (builtin.os.tag != .linux) return null;
    const r = linux.syscall3(.landlock_create_ruleset, 0, 0, ll.create_ruleset_version);
    if (linux.errno(r) != .SUCCESS or r == 0) return null;
    return @intCast(r);
}

// ---------------------------------------------------------------- wrapping

/// Build the sandboxed argv for `command`. The command is always exactly one
/// argv element after `/bin/sh -c`, so it is never re-parsed by this layer.
pub fn wrap(arena: std.mem.Allocator, backend: Backend, policy: Policy, command: []const u8) std.mem.Allocator.Error!Wrapped {
    if (backend == .none) return .{ .unsupported = unavailableReason() };
    if (checkPolicy(policy)) |why| return .{ .unsupported = why };
    return switch (backend) {
        .none => unreachable,
        .bwrap => .{ .argv = try bwrapArgv(arena, policy, command) },
        .seatbelt => seatbeltWrap(arena, policy, command),
        .landlock => landlockWrap(arena, policy, command),
    };
}

/// A path that cannot be handed to a backend safely, as a reason; null if fine.
fn checkPolicy(policy: Policy) ?[]const u8 {
    if (!isAbsolute(policy.workspace)) return "workspace path must be absolute";
    if (!isAbsolute(policy.tmp)) return "temp dir path must be absolute";
    for (policy.write_extra) |p| {
        if (!isAbsolute(p)) return "sandbox.write_extra paths must be absolute";
    }
    return null;
}

fn isAbsolute(p: []const u8) bool {
    return p.len > 0 and p[0] == '/';
}

fn bwrapArgv(arena: std.mem.Allocator, policy: Policy, command: []const u8) ![]const []const u8 {
    var a: std.ArrayListUnmanaged([]const u8) = .empty;
    try a.appendSlice(arena, &.{
        "/usr/bin/env",  "bwrap",         "--die-with-parent", "--new-session",
        "--unshare-pid", "--unshare-ipc", "--unshare-uts",
    });
    if (!policy.network) try a.append(arena, "--unshare-net");
    try a.appendSlice(arena, &.{ "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" });
    try a.appendSlice(arena, &.{ "--bind", policy.workspace, policy.workspace });
    try a.appendSlice(arena, &.{ "--bind", policy.tmp, policy.tmp });
    for (policy.write_extra) |p| try a.appendSlice(arena, &.{ "--bind", p, p });
    try a.appendSlice(arena, &.{ "--chdir", policy.workspace, "--", "/bin/sh", "-c", command });
    return a.items;
}

/// Seatbelt profile (see `profileText`) behind `sandbox-exec -p`.
fn seatbeltWrap(arena: std.mem.Allocator, policy: Policy, command: []const u8) !Wrapped {
    const profile = profileText(arena, policy) catch |err| switch (err) {
        error.BadPath => return .{ .unsupported = "a sandbox path contains a newline or ')' and cannot be placed in a Seatbelt profile" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .argv = try arena.dupe([]const u8, &.{ "/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", command }) };
}

/// Landlock cannot be applied to a child from the parent, so the child is
/// `ifnh __sandbox-exec ...`, which restricts itself and then execs the shell.
/// `env` sets the guard variable without touching the parent's environment.
fn landlockWrap(arena: std.mem.Allocator, policy: Policy, command: []const u8) !Wrapped {
    if (!isAbsolute(policy.exe)) return .{ .unsupported = "Landlock needs the ifnh executable path (not available when embedded)" };
    var a: std.ArrayListUnmanaged([]const u8) = .empty;
    try a.appendSlice(arena, &.{
        "/usr/bin/env",  exec_env ++ "=1", policy.exe,
        exec_subcommand, policy.workspace, if (policy.network) "1" else "0",
        policy.tmp,
    });
    try a.appendSlice(arena, policy.write_extra);
    try a.appendSlice(arena, &.{ "--", "/bin/sh", "-c", command });
    return .{ .argv = a.items };
}

/// The Seatbelt profile for `policy`. Strings are escaped (`"` and `\`);
/// paths with a newline or `)` are rejected outright so a hostile path cannot
/// reshape the s-expression. `/dev/null` is writable because shell commands
/// redirect to it constantly.
pub fn profileText(arena: std.mem.Allocator, policy: Policy) error{ OutOfMemory, BadPath }![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("(version 1) (deny default) (allow process-exec*) (allow process-fork) " ++
        "(allow signal (target self)) (allow file-read*) (allow sysctl-read) (allow mach-lookup) " ++
        "(allow file-write* (literal \"/dev/null\")") catch return error.OutOfMemory;
    const fixed = [_][]const u8{ policy.workspace, policy.tmp, "/private/tmp", "/private/var/tmp" };
    for (fixed) |p| try writeSubpath(w, p);
    for (policy.write_extra) |p| try writeSubpath(w, p);
    w.writeAll(")") catch return error.OutOfMemory;
    if (policy.network) w.writeAll(" (allow network*)") catch return error.OutOfMemory;
    return aw.written();
}

fn writeSubpath(w: *std.Io.Writer, path: []const u8) error{ OutOfMemory, BadPath }!void {
    for (path) |c| if (c == '\n' or c == '\r' or c == ')') return error.BadPath;
    w.writeAll(" (subpath \"") catch return error.OutOfMemory;
    for (path) |c| {
        if (c == '"' or c == '\\') w.writeByte('\\') catch return error.OutOfMemory;
        w.writeByte(c) catch return error.OutOfMemory;
    }
    w.writeAll("\")") catch return error.OutOfMemory;
}

// ---------------------------------------------------------------- session

/// The sandbox of one session: resolved once, read-only afterwards (child
/// agents on other threads share it). `wrapFn` is the `WrapFn` hook.
pub const Session = struct {
    mode: Mode = .off,
    backend: Backend = .none,
    policy: Policy = .{ .workspace = "/", .tmp = "/tmp" },
    /// One-time notice for the host to emit (auto mode without a backend).
    notice: ?[]const u8 = null,

    /// `workspace` is the real path of the project root. `write_extra`
    /// entries relative to it are resolved here. `exe` is the running ifnh
    /// ("" when embedded).
    pub fn resolve(
        arena: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        settings: Settings,
        workspace: []const u8,
        exe: []const u8,
    ) std.mem.Allocator.Error!Session {
        if (settings.mode == .off) return .{ .mode = .off };
        const tmp_raw = environ.get("TMPDIR") orelse "/tmp";
        // /var/folders -> /private/var/folders on macOS: profiles match real paths.
        const tmp = if (std.Io.Dir.realPathFileAbsoluteAlloc(io, tmp_raw, arena)) |real| real else |_| tmp_raw;
        var extra: std.ArrayListUnmanaged([]const u8) = .empty;
        for (settings.write_extra) |p| try extra.append(arena, try std.fs.path.resolve(arena, &.{ workspace, p }));
        const backend = detect(io, environ);
        return .{
            .mode = settings.mode,
            .backend = backend,
            .policy = .{
                .workspace = workspace,
                .write_extra = extra.items,
                .network = settings.network,
                .tmp = std.mem.trimEnd(u8, tmp, "/"),
                .exe = exe,
            },
            .notice = if (settings.mode == .auto and backend == .none) unavailable_notice else null,
        };
    }

    /// The pending notice, once.
    pub fn takeNotice(self: *Session) ?[]const u8 {
        defer self.notice = null;
        return self.notice;
    }

    /// True when commands must go through `wrapFn`.
    pub fn active(self: *const Session) bool {
        return self.mode != .off;
    }

    /// `WrapFn` implementation; `ctx` is a `*const Session`.
    pub fn wrapFn(ctx: *anyopaque, arena: std.mem.Allocator, command: []const u8) Wrapped {
        const self: *const Session = @ptrCast(@alignCast(ctx));
        return self.argvFor(arena, command);
    }

    pub fn argvFor(self: *const Session, arena: std.mem.Allocator, command: []const u8) Wrapped {
        const plain = struct {
            fn argv(a: std.mem.Allocator, cmd: []const u8) Wrapped {
                const v = a.dupe([]const u8, &.{ "/bin/sh", "-c", cmd }) catch return .{ .unsupported = "out of memory" };
                return .{ .argv = v };
            }
        }.argv;
        if (self.mode == .off) return plain(arena, command);
        // `auto` runs unsandboxed only when no backend exists at all; a
        // backend that rejects the policy still refuses the call.
        if (self.mode == .auto and self.backend == .none) return plain(arena, command);
        return wrap(arena, self.backend, self.policy, command) catch .{ .unsupported = "out of memory" };
    }
};

/// The `ifnh doctor` line.
pub fn doctorLine(arena: std.mem.Allocator, settings: Settings, backend: Backend) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "sandbox: {s} (mode={s}, network={s})", .{
        @tagName(backend), @tagName(settings.mode), if (settings.network) "on" else "off",
    });
}

// ---------------------------------------------------------------- landlock

/// Landlock UAPI (linux/landlock.h). Kept local: std has no wrappers.
const ll = struct {
    const create_ruleset_version: usize = 1 << 0;
    const rule_path_beneath: usize = 1;

    const write_file: u64 = 1 << 1;
    const remove_dir: u64 = 1 << 4;
    const remove_file: u64 = 1 << 5;
    const make_char: u64 = 1 << 6;
    const make_dir: u64 = 1 << 7;
    const make_reg: u64 = 1 << 8;
    const make_sock: u64 = 1 << 9;
    const make_fifo: u64 = 1 << 10;
    const make_block: u64 = 1 << 11;
    const make_sym: u64 = 1 << 12;
    const refer: u64 = 1 << 13; // ABI 2
    const truncate: u64 = 1 << 14; // ABI 3
    const net_bind_tcp: u64 = 1 << 0; // ABI 4
    const net_connect_tcp: u64 = 1 << 1; // ABI 4

    const RulesetAttr = extern struct { handled_access_fs: u64, handled_access_net: u64 };
    const PathBeneathAttr = extern struct { allowed_access: u64, parent_fd: i32 }; // the kernel struct is packed (12 bytes); the leading 12 bytes match
};

/// Every write-class filesystem access the kernel at `abi` can handle.
pub fn landlockHandledFs(abi: u32) u64 {
    var m: u64 = ll.write_file | ll.remove_dir | ll.remove_file | ll.make_char | ll.make_dir |
        ll.make_reg | ll.make_sock | ll.make_fifo | ll.make_block | ll.make_sym;
    if (abi >= 2) m |= ll.refer;
    if (abi >= 3) m |= ll.truncate;
    return m;
}

/// TCP bind/connect bits to handle (nothing is allowed back), ABI 4+ only.
pub fn landlockHandledNet(abi: u32, network: bool) u64 {
    if (network or abi < 4) return 0;
    return ll.net_bind_tcp | ll.net_connect_tcp;
}

/// What the helper needs, parsed from its argv.
pub const ExecPlan = struct {
    workspace: []const u8,
    network: bool,
    tmp: []const u8,
    write_extra: []const []const u8,
    /// Command to exec (`/bin/sh -c ...`).
    argv: []const []const u8,
};

/// `<workspace> <0|1> <tmp> <extra...> -- <argv...>` (what follows `__sandbox-exec`).
pub fn parseExecArgs(args: []const []const u8) error{BadArgs}!ExecPlan {
    if (args.len < 5) return error.BadArgs;
    if (!std.mem.eql(u8, args[1], "0") and !std.mem.eql(u8, args[1], "1")) return error.BadArgs;
    const sep = for (args[3..], 3..) |a, i| {
        if (std.mem.eql(u8, a, "--")) break i;
    } else return error.BadArgs;
    if (sep + 1 >= args.len) return error.BadArgs;
    return .{
        .workspace = args[0],
        .network = args[1][0] == '1',
        .tmp = args[2],
        .write_extra = args[3..sep],
        .argv = args[sep + 1 ..],
    };
}

/// Restrict the calling thread (and what it spawns or execs) with Landlock:
/// writes only under the plan's paths, TCP denied unless `network`. Returns
/// the failing errno; on any failure nothing may be run. No allocation, so it
/// is usable right before `exec`.
pub fn applyLandlock(plan: ExecPlan) ?linux.E {
    if (builtin.os.tag != .linux) return .NOSYS;
    const abi = landlockAbi() orelse return .NOSYS;
    const fs_mask = landlockHandledFs(abi);
    const attr = ll.RulesetAttr{ .handled_access_fs = fs_mask, .handled_access_net = landlockHandledNet(abi, plan.network) };
    const attr_size: usize = if (abi >= 4) @sizeOf(ll.RulesetAttr) else @sizeOf(u64);
    const created = linux.syscall3(.landlock_create_ruleset, @intFromPtr(&attr), attr_size, 0);
    if (linux.errno(created) != .SUCCESS) return linux.errno(created);
    const ruleset: usize = created;
    defer _ = linux.close(@intCast(ruleset));

    const file_mask = fs_mask & (ll.write_file | ll.truncate);
    if (allowBeneath(ruleset, plan.workspace, fs_mask, file_mask)) |e| return e;
    if (allowBeneath(ruleset, plan.tmp, fs_mask, file_mask)) |e| return e;
    for (plan.write_extra) |p| if (allowBeneath(ruleset, p, fs_mask, file_mask)) |e| return e;
    // Shell redirections to /dev/null; a host without it simply lacks the rule.
    if (allowBeneath(ruleset, "/dev/null", file_mask, file_mask)) |e| {
        if (e != .NOENT) return e;
    }

    const nnp = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (linux.errno(nnp) != .SUCCESS) return linux.errno(nnp);
    const restricted = linux.syscall3(.landlock_restrict_self, ruleset, 0, 0);
    if (linux.errno(restricted) != .SUCCESS) return linux.errno(restricted);
    return null;
}

/// Add a PATH_BENEATH rule for `path`. A non-directory only accepts
/// file-class bits, so EINVAL on the full mask retries with `file_mask`.
fn allowBeneath(ruleset: usize, path: []const u8, mask: u64, file_mask: u64) ?linux.E {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return .NAMETOOLONG;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    const opened = linux.open(path_z, .{ .PATH = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return linux.errno(opened);
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);

    var rule = ll.PathBeneathAttr{ .allowed_access = mask, .parent_fd = fd };
    var r = linux.syscall4(.landlock_add_rule, ruleset, ll.rule_path_beneath, @intFromPtr(&rule), 0);
    if (linux.errno(r) == .INVAL and mask != file_mask) {
        rule.allowed_access = file_mask;
        r = linux.syscall4(.landlock_add_rule, ruleset, ll.rule_path_beneath, @intFromPtr(&rule), 0);
    }
    const e = linux.errno(r);
    return if (e == .SUCCESS) null else e;
}

/// Entry point of `ifnh __sandbox-exec`. Returns an exit code only on
/// failure (126: refused or could not sandbox; 2: misuse); on success the
/// process image is replaced by the command. Never runs the command
/// unsandboxed.
pub fn runExec(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) u8 {
    const guard = environ.get(exec_env) orelse "";
    if (!std.mem.eql(u8, guard, "1")) {
        stderr.print("sandbox: {s} is internal and is started by ifnh only\n", .{exec_subcommand}) catch {};
        stderr.flush() catch {};
        return 126;
    }
    const plan = parseExecArgs(args) catch {
        stderr.writeAll("sandbox: bad arguments\n") catch {};
        stderr.flush() catch {};
        return 2;
    };
    if (applyLandlock(plan)) |e| {
        stderr.print("sandbox: {s}\n", .{@tagName(e)}) catch {};
        stderr.flush() catch {};
        return 126;
    }
    // The guard stays out of the sandboxed shell's environment.
    var clean = environ.clone(arena) catch return 126;
    _ = clean.orderedRemove(exec_env);
    const err = std.process.replace(io, .{ .argv = plan.argv, .environ_map = &clean });
    stderr.print("sandbox: exec failed: {s}\n", .{@errorName(err)}) catch {};
    stderr.flush() catch {};
    return 126;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testPolicy(network: bool, extra: []const []const u8) Policy {
    return .{ .workspace = "/work/proj", .write_extra = extra, .network = network, .tmp = "/tmp", .exe = "/usr/local/bin/ifnh" };
}

fn expectArgv(w: Wrapped, want: []const []const u8) !void {
    try testing.expect(w == .argv);
    try testing.expectEqual(want.len, w.argv.len);
    for (want, w.argv) |a, b| try testing.expectEqualStrings(a, b);
}

test "sandbox bwrap argv: no network, one extra path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), .bwrap, testPolicy(false, &.{"/srv/cache"}), "echo hi");
    try expectArgv(w, &.{
        "/usr/bin/env",  "bwrap",     "--die-with-parent", "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
        "--unshare-net", "--ro-bind", "/",                 "/",             "--dev",         "/dev",          "--proc",
        "/proc",         "--tmpfs",   "/tmp",              "--bind",        "/work/proj",    "/work/proj",    "--bind",
        "/tmp",          "/tmp",      "--bind",            "/srv/cache",    "/srv/cache",    "--chdir",       "/work/proj",
        "--",            "/bin/sh",   "-c",                "echo hi",
    });
}

test "sandbox bwrap argv: network on drops --unshare-net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), .bwrap, testPolicy(true, &.{}), "true");
    for (w.argv) |a| try testing.expect(!std.mem.eql(u8, a, "--unshare-net"));
    try testing.expectEqualStrings("--unshare-pid", w.argv[4]);
}

test "sandbox: hostile commands stay one argv element, never re-parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = [_][]const u8{
        "true; touch /etc/x",
        "echo $(cat /etc/passwd)",
        "echo a\ntouch /etc/y",
        "cd ../.. && touch escape",
        "ln -s /etc/passwd link; cat link",
        "-- --bind / /",
    };
    for ([_]Backend{ .bwrap, .seatbelt, .landlock }) |backend| {
        for (commands) |cmd| {
            const w = try wrap(arena, backend, testPolicy(false, &.{}), cmd);
            try testing.expect(w == .argv);
            const argv = w.argv;
            try testing.expectEqualStrings(cmd, argv[argv.len - 1]);
            try testing.expectEqualStrings("-c", argv[argv.len - 2]);
            try testing.expectEqualStrings("/bin/sh", argv[argv.len - 3]);
        }
    }
}

test "sandbox seatbelt: argv shape and profile text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const w = try wrap(arena, .seatbelt, testPolicy(false, &.{"/srv/cache"}), "ls");
    try testing.expectEqual(@as(usize, 6), w.argv.len);
    try testing.expectEqualStrings("/usr/bin/sandbox-exec", w.argv[0]);
    try testing.expectEqualStrings("-p", w.argv[1]);
    try testing.expectEqualStrings(
        "(version 1) (deny default) (allow process-exec*) (allow process-fork) (allow signal (target self)) " ++
            "(allow file-read*) (allow sysctl-read) (allow mach-lookup) (allow file-write* (literal \"/dev/null\") " ++
            "(subpath \"/work/proj\") (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\") " ++
            "(subpath \"/srv/cache\"))",
        w.argv[2],
    );
    const on = try profileText(arena, testPolicy(true, &.{}));
    try testing.expect(std.mem.endsWith(u8, on, " (allow network*)"));
    try testing.expect(std.mem.indexOf(u8, w.argv[2], "network") == null);
}

test "sandbox seatbelt: quotes and backslashes are escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = testPolicy(false, &.{"/srv/a\"b\\c"});
    const text = try profileText(arena_state.allocator(), p);
    try testing.expect(std.mem.indexOf(u8, text, "(subpath \"/srv/a\\\"b\\\\c\")") != null);
}

test "sandbox seatbelt: paths with ')' or a newline are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "/srv/x\") (allow file-write* (subpath \"/", "/srv/a)b", "/srv/a\nb" }) |bad| {
        try testing.expectError(error.BadPath, profileText(arena, testPolicy(false, &.{bad})));
        const w = try wrap(arena, .seatbelt, testPolicy(false, &.{bad}), "true");
        try testing.expect(w == .unsupported);
    }
    // The workspace is checked too.
    var p = testPolicy(false, &.{});
    p.workspace = "/work/pro)j";
    try testing.expectError(error.BadPath, profileText(arena, p));
}

test "sandbox landlock argv: helper re-exec with guard env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), .landlock, testPolicy(false, &.{ "/srv/a", "/srv/b" }), "echo hi");
    try expectArgv(w, &.{
        "/usr/bin/env", "IFNH_SANDBOX_EXEC=1", "/usr/local/bin/ifnh", "__sandbox-exec", "/work/proj", "0",
        "/tmp",         "/srv/a",              "/srv/b",              "--",             "/bin/sh",    "-c",
        "echo hi",
    });
    var p = testPolicy(true, &.{});
    p.exe = "";
    const none = try wrap(arena_state.allocator(), .landlock, p, "true");
    try testing.expect(none == .unsupported);
}

test "sandbox exec args parse and reject malformed input" {
    const ok = try parseExecArgs(&.{ "/w", "1", "/t", "/x", "--", "/bin/sh", "-c", "c" });
    try testing.expectEqualStrings("/w", ok.workspace);
    try testing.expect(ok.network);
    try testing.expectEqual(@as(usize, 1), ok.write_extra.len);
    try testing.expectEqual(@as(usize, 3), ok.argv.len);
    try testing.expectError(error.BadArgs, parseExecArgs(&.{ "/w", "2", "/t", "--", "x" }));
    try testing.expectError(error.BadArgs, parseExecArgs(&.{ "/w", "0", "/t", "x", "y" }));
    try testing.expectError(error.BadArgs, parseExecArgs(&.{ "/w", "0", "/t", "/x", "--" }));
    try testing.expectError(error.BadArgs, parseExecArgs(&.{}));
}

test "sandbox landlock mask covers every write access bit" {
    const all_write: u64 = (1 << 1) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) |
        (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13) | (1 << 14);
    try testing.expectEqual(all_write, landlockHandledFs(3));
    try testing.expectEqual(all_write & ~@as(u64, 1 << 14), landlockHandledFs(2));
    try testing.expectEqual(all_write & ~@as(u64, (1 << 14) | (1 << 13)), landlockHandledFs(1));
    // Read and execute are never handled: they stay allowed everywhere.
    try testing.expectEqual(@as(u64, 0), landlockHandledFs(5) & ((1 << 0) | (1 << 2) | (1 << 3)));
    try testing.expectEqual(@as(u64, 3), landlockHandledNet(4, false));
    try testing.expectEqual(@as(u64, 0), landlockHandledNet(4, true));
    try testing.expectEqual(@as(u64, 0), landlockHandledNet(3, false));
}

test "sandbox: no backend is unsupported with a reason; relative paths are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = try wrap(arena, .none, testPolicy(false, &.{}), "true");
    try testing.expect(none == .unsupported);
    try testing.expect(none.unsupported.len > 0);
    const rel = try wrap(arena, .bwrap, testPolicy(false, &.{"rel/dir"}), "true");
    try testing.expect(rel == .unsupported);
}

test "sandbox mode off: argv is exactly /bin/sh -c command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Session{};
    try expectArgv(s.argvFor(arena_state.allocator(), "echo a; b"), &.{ "/bin/sh", "-c", "echo a; b" });
    try testing.expect(!s.active());
}

test "sandbox modes: auto falls back with one notice, required refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var auto = Session{ .mode = .auto, .backend = .none, .notice = unavailable_notice };
    try expectArgv(auto.argvFor(arena, "ls"), &.{ "/bin/sh", "-c", "ls" });
    try testing.expectEqualStrings(unavailable_notice, auto.takeNotice().?);
    try testing.expect(auto.takeNotice() == null);

    const req = Session{ .mode = .required, .backend = .none };
    const refused = req.argvFor(arena, "ls");
    try testing.expect(refused == .unsupported);

    // A backend that rejects the policy refuses even in auto mode.
    const bad = Session{ .mode = .auto, .backend = .bwrap, .policy = .{ .workspace = "rel", .tmp = "/tmp" } };
    try testing.expect(bad.argvFor(arena, "ls") == .unsupported);

    const live = Session{ .mode = .required, .backend = .bwrap, .policy = testPolicy(false, &.{}) };
    try testing.expect(live.argvFor(arena, "ls") == .argv);
}

test "sandbox: resolve is inert when off and resolves extras when on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(arena);
    try env.put("TMPDIR", "/tmp/");
    const off = try Session.resolve(arena, testing.io, &env, .{}, "/work/proj", "");
    try testing.expectEqual(Mode.off, off.mode);
    try testing.expectEqual(Backend.none, off.backend);

    const on = try Session.resolve(arena, testing.io, &env, .{ .mode = .required, .write_extra = &.{ "build", "/srv/../srv/cache" } }, "/work/proj", "/bin/ifnh");
    try testing.expectEqualStrings("/work/proj/build", on.policy.write_extra[0]);
    try testing.expectEqualStrings("/srv/cache", on.policy.write_extra[1]);
    try testing.expectEqualStrings("/tmp", on.policy.tmp);
    try testing.expect(!on.policy.network);
}

test "sandbox doctor line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = try doctorLine(arena_state.allocator(), .{ .mode = .auto, .network = true }, .landlock);
    try testing.expectEqualStrings("sandbox: landlock (mode=auto, network=on)", line);
}

test "sandbox exec refuses to run without the guard variable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(arena);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectEqual(@as(u8, 126), runExec(testing.io, arena, &env, &.{ "/w", "0", "/t", "--", "/bin/true" }, &w));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "internal") != null);
    try env.put(exec_env, "1");
    w = std.Io.Writer.fixed(&buf);
    try testing.expectEqual(@as(u8, 2), runExec(testing.io, arena, &env, &.{"/w"}, &w));
}

// ---- Landlock enforcement (Linux, kernel support required) ----
//
// `landlock_restrict_self` restricts only the calling thread, so the checks
// run on a throwaway thread and the test process itself stays unrestricted.

const LandlockProbe = struct {
    plan: ExecPlan,
    inside: [*:0]const u8,
    outside: [*:0]const u8,
    dev_null: [*:0]const u8 = "/dev/null",
    read_outside: [*:0]const u8 = "/etc/hostname",
    applied: ?linux.E = null,
    inside_ok: bool = false,
    outside_denied: bool = false,
    dev_null_ok: bool = false,
    read_ok: bool = false,
    inside_err: linux.E = .SUCCESS,

    fn createFile(path: [*:0]const u8) linux.E {
        const r = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
        const e = linux.errno(r);
        if (e == .SUCCESS) _ = linux.close(@intCast(r));
        return e;
    }

    fn run(self: *LandlockProbe) void {
        self.applied = applyLandlock(self.plan);
        if (self.applied != null) return;
        self.inside_err = createFile(self.inside);
        self.inside_ok = self.inside_err == .SUCCESS;
        self.outside_denied = createFile(self.outside) == .ACCES;
        const n = linux.open(self.dev_null, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        self.dev_null_ok = linux.errno(n) == .SUCCESS;
        if (self.dev_null_ok) _ = linux.close(@intCast(n));
        const r = linux.open(self.read_outside, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        self.read_ok = linux.errno(r) == .SUCCESS or linux.errno(r) == .NOENT;
        if (linux.errno(r) == .SUCCESS) _ = linux.close(@intCast(r));
    }
};

test "sandbox landlock enforcement: writes only in the allowed dirs" {
    if (landlockAbi() == null) return error.SkipZigTest;
    var ws = testing.tmpDir(.{});
    defer ws.cleanup();
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    var other_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_buf[0..try ws.dir.realPath(testing.io, &ws_buf)];
    const other_path = other_buf[0..try other.dir.realPath(testing.io, &other_buf)];
    var inside_buf: [std.fs.max_path_bytes]u8 = undefined;
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inside = try std.fmt.bufPrintSentinel(&inside_buf, "{s}/inside.txt", .{ws_path}, 0);
    const outside = try std.fmt.bufPrintSentinel(&outside_buf, "{s}/outside.txt", .{other_path}, 0);

    var probe = LandlockProbe{
        .plan = .{ .workspace = ws_path, .network = false, .tmp = ws_path, .write_extra = &.{}, .argv = &.{} },
        .inside = inside.ptr,
        .outside = outside.ptr,
    };
    const t = try std.Thread.spawn(.{}, LandlockProbe.run, .{&probe});
    t.join();
    if (probe.applied) |e| {
        // A kernel with Landlock compiled in but no permission: not our failure.
        std.debug.print("SKIP landlock enforcement: apply failed with {s}\n", .{@tagName(e)});
        return error.SkipZigTest;
    }
    try testing.expect(probe.inside_ok);
    try testing.expect(probe.outside_denied);
    try testing.expect(probe.dev_null_ok);
    try testing.expect(probe.read_ok);
    // The denied file does not exist; the allowed one does.
    try testing.expectError(error.FileNotFound, other.dir.access(testing.io, "outside.txt", .{}));
    try ws.dir.access(testing.io, "inside.txt", .{});
}

test "sandbox landlock: a missing write_extra path fails closed" {
    if (landlockAbi() == null) return error.SkipZigTest;
    var probe = LandlockProbe{
        .plan = .{ .workspace = "/tmp", .network = false, .tmp = "/tmp", .write_extra = &.{"/nonexistent-ifnh-sandbox-dir"}, .argv = &.{} },
        .inside = "/tmp/x",
        .outside = "/tmp/y",
    };
    const t = try std.Thread.spawn(.{}, LandlockProbe.run, .{&probe});
    t.join();
    try testing.expectEqual(@as(?linux.E, .NOENT), probe.applied);
}
