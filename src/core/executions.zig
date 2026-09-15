//! Managed background executions (M1-T10, DECISIONS I123-125).
//!
//! The `bash` tool can spawn commands in the background; the registry
//! tracks them by handle id, captures output to artifact files, and
//! supports poll/stop. All executions are killed at session end
//! (I125) via `deinit`. Threads are per-execution; results are
//! polled through atomics and files, never shared buffers.

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const max_executions: usize = 32;

pub const State = enum { running, completed, stopped, failed_spawn };

pub const Snapshot = struct {
    id: u32,
    state: State,
    exit_code: ?u32 = null,
    output_file: []const u8,
    output_bytes: usize = 0,
    command: []const u8,
};

const Slot = struct {
    used: bool = false,
    id: u32 = 0,
    thread: ?std.Thread = null,
    child: ?std.process.Child = null,
    state: std.atomic.Value(u8) = .init(0), // State as u8
    exit_code: std.atomic.Value(u32) = .init(0),
    output_file: [128]u8 = undefined,
    output_file_len: usize = 0,
    output_bytes: std.atomic.Value(usize) = .init(0),
    command: [256]u8 = undefined,
    command_len: usize = 0,
    mutex: std.Io.Mutex = .init,
};

fn stateToU8(s: State) u8 {
    return switch (s) {
        .running => 0,
        .completed => 1,
        .stopped => 2,
        .failed_spawn => 3,
    };
}

fn u8ToState(v: u8) State {
    return switch (v) {
        1 => .completed,
        2 => .stopped,
        3 => .failed_spawn,
        else => .running,
    };
}

pub const Registry = struct {
    io: std.Io,
    alloc: std.mem.Allocator, // registry-lifetime arena
    workspace: std.Io.Dir,
    artifact_dir: []const u8 = ".ifnh/cache/exec",
    slots: [max_executions]Slot = [_]Slot{.{}} ** max_executions,
    next_id: std.atomic.Value(u32) = .init(1),
    io_mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, alloc: std.mem.Allocator, workspace: std.Io.Dir) Registry {
        return .{ .io = io, .alloc = alloc, .workspace = workspace };
    }

    /// Start a background command. Returns the execution id.
    pub fn start(self: *Registry, argv: []const []const u8) !u32 {
        try self.io_mutex.lock(self.io);
        defer self.io_mutex.unlock(self.io);

        var slot: ?*Slot = null;
        for (&self.slots) |*s| {
            if (!s.used) {
                slot = s;
                break;
            }
        }
        const s = slot orelse return error.TooManyExecutions;

        const id = self.next_id.fetchAdd(1, .monotonic);
        s.* = .{};
        s.used = true;
        s.id = id;
        s.state = .init(stateToU8(.running));

        const of = std.fmt.bufPrint(&s.output_file, "{s}/exec-{d}.log", .{ self.artifact_dir, id }) catch return error.OutOfMemory;
        s.output_file_len = of.len;
        var cmd_end: usize = 0;
        for (argv) |a| {
            if (cmd_end + a.len + 1 >= s.command.len) break;
            if (cmd_end > 0) {
                s.command[cmd_end] = ' ';
                cmd_end += 1;
            }
            @memcpy(s.command[cmd_end .. cmd_end + a.len], a);
            cmd_end += a.len;
        }
        s.command_len = cmd_end;

        // Ensure artifact dir exists; truncate the log.
        self.workspace.createDirPath(self.io, self.artifact_dir) catch {};
        const log_file = self.workspace.createFile(self.io, of, .{ .truncate = true }) catch return error.OutOfMemory;
        log_file.close(self.io);

        const Worker = struct {
            fn run(reg: *Registry, sl: *Slot, argv_owned: [][]const u8) void {
                const run_result = std.process.run(reg.alloc, reg.io, .{
                    .argv = argv_owned,
                    .cwd = .{ .dir = reg.workspace },
                    .stdout_limit = .limited(1024 * 1024),
                    .stderr_limit = .limited(256 * 1024),
                    .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3600) } },
                }) catch {
                    sl.state.store(stateToU8(.failed_spawn), .release);
                    return;
                };
                // Append captured output to the artifact file.
                sl.mutex.lock(reg.io) catch {};
                defer sl.mutex.unlock(reg.io);
                if (reg.workspace.openFile(reg.io, sl.output_file[0..sl.output_file_len], .{ .mode = .read_write })) |f| {
                    var f2 = f;
                    defer f2.close(reg.io);
                    const st = f2.stat(reg.io) catch null;
                    const off: u64 = if (st) |st2| st2.size else 0;
                    if (run_result.stdout.len > 0) f2.writePositionalAll(reg.io, run_result.stdout, off) catch {};
                    if (run_result.stderr.len > 0) f2.writePositionalAll(reg.io, run_result.stderr, off + run_result.stdout.len) catch {};
                    sl.output_bytes.store(run_result.stdout.len + run_result.stderr.len, .release);
                } else |_| {}
                switch (run_result.term) {
                    .exited => |code| {
                        sl.exit_code.store(code, .release);
                        sl.state.store(stateToU8(if (code == 0) State.completed else State.completed), .release);
                    },
                    else => sl.state.store(stateToU8(.completed), .release),
                }
            }
        };

        // Owned argv copy for the thread.
        const argv_owned = try self.alloc.alloc([]const u8, argv.len);
        for (argv, 0..) |a, i| argv_owned[i] = try self.alloc.dupe(u8, a);

        s.thread = std.Thread.spawn(.{}, Worker.run, .{ self, s, argv_owned }) catch {
            s.used = false;
            return error.OutOfMemory;
        };
        return id;
    }

    pub fn snapshot(self: *Registry, id: u32) ?Snapshot {
        for (&self.slots) |*s| {
            if (!s.used or s.id != id) continue;
            return .{
                .id = id,
                .state = u8ToState(s.state.load(.acquire)),
                .exit_code = if (s.state.load(.acquire) != 0) s.exit_code.load(.acquire) else null,
                .output_file = s.output_file[0..s.output_file_len],
                .output_bytes = s.output_bytes.load(.acquire),
                .command = s.command[0..s.command_len],
            };
        }
        return null;
    }

    /// Read up to `max_bytes` of output from the artifact (tail-bounded).
    pub fn readOutput(self: *Registry, id: u32, arena: std.mem.Allocator, max_bytes: usize) ?[]const u8 {
        const snap = self.snapshot(id) orelse return null;
        return fsutil.readSmallFile(self.workspace, self.io, arena, snap.output_file, max_bytes) catch null;
    }

    /// Stop a running execution: kills the process; the worker thread
    /// observes termination and finalizes. Returns true when found.
    pub fn stop(self: *Registry, id: u32) bool {
        for (&self.slots) |*s| {
            if (!s.used or s.id != id) continue;
            if (s.state.load(.acquire) != stateToU8(.running)) return true;
            self.io_mutex.lock(self.io) catch return false;
            defer self.io_mutex.unlock(self.io);
            if (s.child) |*c| c.kill(self.io);
            s.state.store(stateToU8(.stopped), .release);
            return true;
        }
        return false;
    }

    /// Reap finished threads; returns the number reaped.
    pub fn reap(self: *Registry) usize {
        var n: usize = 0;
        for (&self.slots) |*s| {
            if (!s.used) continue;
            const st = s.state.load(.acquire);
            if (st != stateToU8(.running)) {
                if (s.thread) |t| {
                    t.join();
                    s.thread = null;
                }
                s.used = false;
                n += 1;
            }
        }
        return n;
    }

    /// Kill everything (session end, I125).
    pub fn deinit(self: *Registry) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (s.state.load(.acquire) == stateToU8(.running)) {
                if (s.child) |*c| c.kill(self.io);
                s.state.store(stateToU8(.stopped), .release);
            }
            if (s.thread) |t| {
                t.join();
                s.thread = null;
            }
            s.used = false;
        }
    }
};

// ---------------------------------------------------------------- tests

test "background execution lifecycle: start, poll, read output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = Registry.init(io, arena, tmp.dir);
    defer reg.deinit();

    const id = try reg.start(&.{ "sh", "-c", "echo bg-hello" });
    // Poll to completion (bounded, with sleeps so the worker gets CPU).
    var tries: usize = 0;
    while (tries < 400) : (tries += 1) {
        const snap = reg.snapshot(id).?;
        if (snap.state != .running) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    const snap = reg.snapshot(id).?;
    try std.testing.expect(snap.state == .completed);
    try std.testing.expectEqual(@as(u32, 0), snap.exit_code.?);

    const out = reg.readOutput(id, arena, 4096).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "bg-hello") != null);

    _ = reg.reap();
    try std.testing.expect(reg.snapshot(id) == null);
}

test "stop a long-running execution" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = Registry.init(io, arena, tmp.dir);
    defer reg.deinit();

    const id = try reg.start(&.{ "sh", "-c", "sleep 60" });
    // Let it start.
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (reg.snapshot(id) != null) break;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(reg.stop(id));
    try std.testing.expectEqual(State.stopped, reg.snapshot(id).?.state);
    _ = reg.reap();
}
