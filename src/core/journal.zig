//! Undo journal (DESIGN §3.6, DECISIONS A9-A14, M179-M188).
//!
//! Protocol: intent record → apply file operations → commit record.
//! Crash between intent and commit leaves an incomplete group; on open the
//! journal rolls it back using the before-images stored in the intent.
//!
//! Memory model: files are journaled as bounded before-images (default cap
//! 1 MiB); larger or non-UTF-8 mutations are refused with `NotJournalable`
//! and must go through the approval gate as irreversible (M184-186).
//! The caller's `alloc` must be an arena outliving the Journal; internal
//! scratch uses temporary arenas.

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const max_before_image_bytes: usize = 1024 * 1024;
pub const max_journal_bytes: usize = 256 * 1024 * 1024;

pub const Op = union(enum) {
    /// Overwrite an existing file. `before` restores it on undo.
    write: struct {
        path: []const u8,
        before: []const u8,
        after: []const u8,
    },
    /// Create a new file. Undo deletes it.
    create: struct {
        path: []const u8,
        after: []const u8,
    },
    /// Delete a file. Undo restores `before`.
    delete: struct {
        path: []const u8,
        before: []const u8,
    },
};

pub const ApplyError = error{
    NotJournalable,
    PathUnsafe,
    PathNotFound,
    PathExists,
} || anyerror;

pub const GroupState = enum { pending, committed, undone, abandoned };

pub const GroupInfo = struct {
    id: u64,
    state: GroupState,
    label: []const u8,
    op_count: usize,
};

fn sha256Hex(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = try arena.alloc(u8, 64);
    const digits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0xf];
    }
    return hex;
}

fn validateRelPath(path: []const u8) !void {
    if (path.len == 0) return error.PathUnsafe;
    if (path[0] == '/') return error.PathUnsafe;
    if (std.mem.indexOf(u8, path, "..") != null) return error.PathUnsafe;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.PathUnsafe;
}

fn checkJournable(data: []const u8) !void {
    if (data.len > max_before_image_bytes) return error.NotJournalable;
    if (!std.unicode.utf8ValidateSlice(data)) return error.NotJournalable;
}

pub const Journal = struct {
    io: std.Io,
    /// Journal-lifetime allocator (arena contract, like session/store.zig).
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    file: ?std.Io.File = null,
    next_gid: u64 = 1,
    /// gid -> state, rebuilt on open.
    groups: std.AutoHashMapUnmanaged(u64, GroupInfo) = .empty,
    /// Undo stack (gids in commit order) and redo stack, derived on open.
    undo_stack: std.ArrayListUnmanaged(u64) = .empty,
    redo_stack: std.ArrayListUnmanaged(u64) = .empty,

    /// Open (or create) the journal in `dir`. Rebuilds group state and rolls
    /// back any group that has an intent but no commit (crash recovery).
    pub fn open(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Journal {
        var self = Journal{ .io = io, .alloc = alloc, .dir = dir };

        const text = fsutil.readSmallFile(dir, io, alloc, "journal.jsonl", max_journal_bytes) catch |err| switch (err) {
            error.FileNotFound => {
                self.file = try dir.createFile(io, "journal.jsonl", .{ .truncate = true });
                return self;
            },
            else => return err,
        };

        // Rebuild state from records.
        var lines = std.mem.splitScalar(u8, text, '\n');
        var committed: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer committed.deinit(alloc);
        var intents: std.AutoHashMapUnmanaged(u64, []const u8) = .empty; // gid -> intent line (duped)
        defer intents.deinit(alloc);

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{}) catch continue;
            if (v != .object) continue;
            const t_v = v.object.get("t") orelse continue;
            if (t_v != .string) continue;
            const t = t_v.string;
            const gid_v = v.object.get("gid") orelse continue;
            if (gid_v != .integer) continue;
            const gid: u64 = @intCast(gid_v.integer);
            self.next_gid = @max(self.next_gid, gid + 1);

            if (std.mem.eql(u8, t, "intent")) {
                try intents.put(alloc, gid, try alloc.dupe(u8, line));
                try self.groups.put(alloc, gid, .{ .id = gid, .state = .pending, .label = labelOf(alloc, v) catch "", .op_count = opCountOf(v) });
            } else if (std.mem.eql(u8, t, "commit")) {
                try committed.put(alloc, gid, {});
                if (self.groups.getPtr(gid)) |g| g.state = .committed;
            } else if (std.mem.eql(u8, t, "undo")) {
                if (self.groups.getPtr(gid)) |g| g.state = .undone;
            } else if (std.mem.eql(u8, t, "redo")) {
                if (self.groups.getPtr(gid)) |g| g.state = .committed;
            } else if (std.mem.eql(u8, t, "abandon")) {
                if (v.object.get("gids")) |gids_v| {
                    if (gids_v == .array) {
                        for (gids_v.array.items) |gv| {
                            if (gv == .integer) {
                                if (self.groups.getPtr(@intCast(gv.integer))) |g| g.state = .abandoned;
                            }
                        }
                    }
                }
            }
        }

        // Open for append BEFORE recovery so rollback can append its record.
        self.file = try dir.openFile(io, "journal.jsonl", .{ .mode = .read_write });

        // Crash recovery: intents without commit → roll back.
        var it = intents.iterator();
        while (it.next()) |entry| {
            if (committed.contains(entry.key_ptr.*)) continue;
            try self.rollback(entry.value_ptr.*);
        }

        // Derive undo/redo stacks in gid order.
        var gids: std.ArrayListUnmanaged(u64) = .empty;
        defer gids.deinit(alloc);
        var git = self.groups.iterator();
        while (git.next()) |entry| {
            if (entry.value_ptr.state == .committed or entry.value_ptr.state == .undone) {
                try gids.append(alloc, entry.key_ptr.*);
            }
        }
        std.mem.sort(u64, gids.items, {}, std.sort.asc(u64));
        for (gids.items) |gid| {
            const st = self.groups.get(gid).?.state;
            if (st == .committed) try self.undo_stack.append(alloc, gid);
        }
        // Redo = most recent undone run at the top of the stack.
        var idx: usize = self.undo_stack.items.len;
        while (idx > 0) {
            const gid = self.undo_stack.items[idx - 1];
            if (self.groups.get(gid).?.state != .undone) break;
            try self.redo_stack.append(alloc, gid);
            idx -= 1;
        }

        return self;
    }

    fn labelOf(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
        if (v.object.get("label")) |l| {
            if (l == .string) return try alloc.dupe(u8, l.string);
        }
        return "";
    }

    fn opCountOf(v: std.json.Value) usize {
        if (v.object.get("ops")) |ops| {
            if (ops == .array) return ops.array.items.len;
        }
        return 0;
    }

    fn appendRecord(self: *Journal, comptime fmt: []const u8, args: anytype) !void {
        const f = self.file orelse return error.JournalClosed;
        const line = try std.fmt.allocPrint(self.alloc, fmt ++ "\n", args);
        defer self.alloc.free(line);
        try f.writePositionalAll(self.io, line, try self.endOffset());
    }

    fn endOffset(self: *Journal) !u64 {
        const f = self.file orelse return error.JournalClosed;
        const stat = try f.stat(self.io);
        return stat.size;
    }

    fn rollback(self: *Journal, intent_line: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, intent_line, .{}) catch return;
        const gid_v = v.object.get("gid") orelse return;
        if (gid_v != .integer) return;
        const gid: u64 = @intCast(gid_v.integer);
        const ops_v = v.object.get("ops") orelse return;
        if (ops_v != .array) return;

        // Apply inverse in reverse order (best effort).
        var i: usize = ops_v.array.items.len;
        while (i > 0) {
            i -= 1;
            self.applyInverseParsed(ops_v.array.items[i]) catch {};
        }
        try self.appendRecord("{{\"t\":\"rollback\",\"gid\":{d},\"ts_ms\":{d}}}\n", .{ gid, nowMs(self.io) });
        if (self.groups.getPtr(gid)) |g| g.state = .abandoned;
    }

    fn applyInverseParsed(self: *Journal, op_v: std.json.Value) !void {
        if (op_v != .object) return error.BadOp;
        const kind_v = op_v.object.get("op") orelse return error.BadOp;
        if (kind_v != .string) return error.BadOp;
        const path_v = op_v.object.get("path") orelse return error.BadOp;
        if (path_v != .string) return error.BadOp;
        const path = path_v.string;

        if (std.mem.eql(u8, kind_v.string, "write")) {
            const before_v = op_v.object.get("before") orelse return error.BadOp;
            if (before_v != .string) return error.BadOp;
            try self.writeFile(path, before_v.string);
        } else if (std.mem.eql(u8, kind_v.string, "create")) {
            self.dir.deleteFile(self.io, path) catch {};
        } else if (std.mem.eql(u8, kind_v.string, "delete")) {
            const before_v = op_v.object.get("before") orelse return error.BadOp;
            if (before_v != .string) return error.BadOp;
            try self.writeFile(path, before_v.string);
        } else return error.BadOp;
    }

    fn writeFile(self: *Journal, path: []const u8, data: []const u8) !void {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            try self.dir.createDirPath(self.io, path[0..slash]);
        }
        try fsutil.atomicWriteFile(self.dir, self.io, self.alloc, path, data);
    }

    /// Apply a group of operations atomically-with-recovery:
    /// intent record → apply → commit record.
    pub fn apply(self: *Journal, label: []const u8, ops: []const Op) ApplyError!void {
        if (ops.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Validate everything BEFORE writing intent (fail fast, no side effects).
        for (ops) |op| {
            switch (op) {
                .write => |w| {
                    try validateRelPath(w.path);
                    try checkJournable(w.before);
                    try checkJournable(w.after);
                },
                .create => |c| {
                    try validateRelPath(c.path);
                    try checkJournable(c.after);
                },
                .delete => |d| {
                    try validateRelPath(d.path);
                    try checkJournable(d.before);
                },
            }
        }

        const gid = self.next_gid;
        // Serialize intent.
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.writeAll("{\"t\":\"intent\",\"gid\":");
        try aw.writer.print("{d}", .{gid});
        try aw.writer.print(",\"ts_ms\":{d},\"label\":", .{nowMs(self.io)});
        try std.json.Stringify.value(label, .{}, &aw.writer);
        try aw.writer.writeAll(",\"ops\":[");
        for (ops, 0..) |op, idx| {
            if (idx > 0) try aw.writer.writeByte(',');
            switch (op) {
                .write => |w| {
                    try aw.writer.writeAll("{\"op\":\"write\",\"path\":");
                    try std.json.Stringify.value(w.path, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"before\":");
                    try std.json.Stringify.value(w.before, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"after\":");
                    try std.json.Stringify.value(w.after, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"before_sha256\":");
                    try std.json.Stringify.value(try sha256Hex(arena, w.before), .{}, &aw.writer);
                    try aw.writer.writeAll(",\"after_sha256\":");
                    try std.json.Stringify.value(try sha256Hex(arena, w.after), .{}, &aw.writer);
                    try aw.writer.writeByte('}');
                },
                .create => |c| {
                    try aw.writer.writeAll("{\"op\":\"create\",\"path\":");
                    try std.json.Stringify.value(c.path, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"after\":");
                    try std.json.Stringify.value(c.after, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"after_sha256\":");
                    try std.json.Stringify.value(try sha256Hex(arena, c.after), .{}, &aw.writer);
                    try aw.writer.writeByte('}');
                },
                .delete => |d| {
                    try aw.writer.writeAll("{\"op\":\"delete\",\"path\":");
                    try std.json.Stringify.value(d.path, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"before\":");
                    try std.json.Stringify.value(d.before, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"before_sha256\":");
                    try std.json.Stringify.value(try sha256Hex(arena, d.before), .{}, &aw.writer);
                    try aw.writer.writeByte('}');
                },
            }
        }
        try aw.writer.writeAll("]}\n");
        const intent_line = aw.written();

        const f = self.file orelse return error.JournalClosed;
        const off = try self.endOffset();
        try f.writePositionalAll(self.io, intent_line, off);

        // Apply.
        for (ops) |op| {
            switch (op) {
                .write => |w| {
                    const cur = self.dir.readFileAlloc(self.io, w.path, arena, .limited(max_before_image_bytes + 1)) catch
                        return error.PathNotFound;
                    if (!std.mem.eql(u8, cur, w.before)) return error.StaleBefore;
                    try self.writeFile(w.path, w.after);
                },
                .create => |c| {
                    const cur = self.dir.readFileAlloc(self.io, c.path, arena, .limited(1)) catch null;
                    if (cur != null) return error.PathExists;
                    try self.writeFile(c.path, c.after);
                },
                .delete => |d| {
                    const cur = self.dir.readFileAlloc(self.io, d.path, arena, .limited(max_before_image_bytes + 1)) catch
                        return error.PathNotFound;
                    if (!std.mem.eql(u8, cur, d.before)) return error.StaleBefore;
                    try self.dir.deleteFile(self.io, d.path);
                },
            }
        }

        // Commit record.
        const commit_line = try std.fmt.allocPrint(arena, "{{\"t\":\"commit\",\"gid\":{d},\"ts_ms\":{d}}}\n", .{ gid, nowMs(self.io) });
        try f.writePositionalAll(self.io, commit_line, off + intent_line.len);

        self.next_gid += 1;
        try self.groups.put(self.alloc, gid, .{
            .id = gid,
            .state = .committed,
            .label = try self.alloc.dupe(u8, label),
            .op_count = ops.len,
        });
        try self.undo_stack.append(self.alloc, gid);
        // New work invalidates redo.
        if (self.redo_stack.items.len > 0) {
            var abandoned: std.ArrayListUnmanaged(u64) = .empty;
            defer abandoned.deinit(self.alloc);
            for (self.redo_stack.items) |rgid| {
                if (self.groups.getPtr(rgid)) |g| g.state = .abandoned;
                try abandoned.append(self.alloc, rgid);
            }
            try self.appendRecord("{{\"t\":\"abandon\",\"gids\":[{s}]}}\n", .{try joinGids(arena, abandoned.items)});
            self.redo_stack.clearRetainingCapacity();
        }
    }

    /// Undo the most recent committed group. Returns its gid.
    pub fn undo(self: *Journal) !?u64 {
        const gid = self.undo_stack.pop() orelse return null;
        if (self.groups.get(gid).?.state != .committed) return null;
        try self.applyInverseFor(gid);
        try self.appendRecord("{{\"t\":\"undo\",\"gid\":{d},\"ts_ms\":{d}}}\n", .{ gid, nowMs(self.io) });
        if (self.groups.getPtr(gid)) |g| g.state = .undone;
        try self.redo_stack.append(self.alloc, gid);
        return gid;
    }

    /// Redo the most recently undone group. Returns its gid.
    pub fn redo(self: *Journal) !?u64 {
        const gid = self.redo_stack.pop() orelse return null;
        if (self.groups.get(gid).?.state != .undone) return null;
        try self.applyForwardFor(gid);
        try self.appendRecord("{{\"t\":\"redo\",\"gid\":{d},\"ts_ms\":{d}}}\n", .{ gid, nowMs(self.io) });
        if (self.groups.getPtr(gid)) |g| g.state = .committed;
        try self.undo_stack.append(self.alloc, gid);
        return gid;
    }

    fn opsFor(self: *Journal, gid: u64, arena: std.mem.Allocator) ![]std.json.Value {
        // Scan journal for the intent line of gid.
        const text = try fsutil.readSmallFile(self.dir, self.io, arena, "journal.jsonl", max_journal_bytes);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
            if (v != .object) continue;
            const gid_v = v.object.get("gid") orelse continue;
            if (gid_v != .integer or @as(u64, @intCast(gid_v.integer)) != gid) continue;
            const t_v = v.object.get("t") orelse continue;
            if (t_v != .string or !std.mem.eql(u8, t_v.string, "intent")) continue;
            const ops_v = v.object.get("ops") orelse return error.BadRecord;
            if (ops_v != .array) return error.BadRecord;
            return ops_v.array.items;
        }
        return error.BadRecord;
    }

    fn applyInverseFor(self: *Journal, gid: u64) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const ops = try self.opsFor(gid, arena);
        var i: usize = ops.len;
        while (i > 0) {
            i -= 1;
            try self.applyInverseParsed(ops[i]);
        }
    }

    fn applyForwardFor(self: *Journal, gid: u64) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const ops = try self.opsFor(gid, arena);
        for (ops) |op_v| {
            if (op_v != .object) return error.BadOp;
            const kind_v = op_v.object.get("op") orelse return error.BadOp;
            const path_v = op_v.object.get("path") orelse return error.BadOp;
            if (std.mem.eql(u8, kind_v.string, "write")) {
                const after_v = op_v.object.get("after") orelse return error.BadOp;
                if (after_v != .string) return error.BadOp;
                try self.writeFile(path_v.string, after_v.string);
            } else if (std.mem.eql(u8, kind_v.string, "create")) {
                try self.writeFile(path_v.string, op_v.object.get("after").?.string);
            } else if (std.mem.eql(u8, kind_v.string, "delete")) {
                try self.dir.deleteFile(self.io, path_v.string);
            }
        }
    }

    pub fn canUndo(self: *const Journal) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Journal) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn close(self: *Journal) void {
        if (self.file) |f| {
            f.close(self.io);
            self.file = null;
        }
    }
};

fn joinGids(arena: std.mem.Allocator, gids: []const u64) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (gids, 0..) |g, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.print("{d}", .{g});
    }
    return aw.written();
}

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// ---------------------------------------------------------------- tests

fn tmpJournal() !struct { tmp: std.testing.TmpDir, dir: std.Io.Dir } {
    const tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    errdefer tmp.cleanup();
    return .{ .tmp = tmp, .dir = tmp.dir };
}

test "journal write, undo, redo" {
    const io = std.testing.io;
    var ts = try tmpJournal();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try ts.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });

    var j = try Journal.open(io, arena, ts.dir);
    defer j.close();

    try j.apply("edit", &.{.{ .write = .{
        .path = "a.txt",
        .before = "hello",
        .after = "world",
    } }});
    const after = try ts.dir.readFileAlloc(io, "a.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("world", after);

    try std.testing.expect(j.canUndo());
    const gid = try j.undo();
    try std.testing.expect(gid != null);
    const restored = try ts.dir.readFileAlloc(io, "a.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("hello", restored);
    try std.testing.expect(!j.canUndo());
    try std.testing.expect(j.canRedo());

    _ = try j.redo();
    const redone = try ts.dir.readFileAlloc(io, "a.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("world", redone);
}

test "journal create and delete ops" {
    const io = std.testing.io;
    var ts = try tmpJournal();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try ts.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "old data" });

    var j = try Journal.open(io, arena, ts.dir);
    defer j.close();

    try j.apply("scaffold", &.{
        .{ .create = .{ .path = "new.txt", .after = "created" } },
        .{ .delete = .{ .path = "gone.txt", .before = "old data" } },
    });
    try std.testing.expect((try ts.dir.statFile(io, "new.txt", .{})).size > 0);
    try std.testing.expectError(error.FileNotFound, ts.dir.statFile(io, "gone.txt", .{}));

    _ = try j.undo(); // delete restored, create removed
    const restored = try ts.dir.readFileAlloc(io, "gone.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("old data", restored);
    try std.testing.expectError(error.FileNotFound, ts.dir.statFile(io, "new.txt", .{}));
}

test "journal stale before refused" {
    const io = std.testing.io;
    var ts = try tmpJournal();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try ts.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "actual" });
    var j = try Journal.open(io, arena, ts.dir);
    defer j.close();

    try std.testing.expectError(error.StaleBefore, j.apply("edit", &.{.{ .write = .{
        .path = "a.txt",
        .before = "stale",
        .after = "new",
    } }}));
    // File untouched.
    const cur = try ts.dir.readFileAlloc(io, "a.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("actual", cur);
}

test "journal crash recovery rolls back uncommitted group" {
    const io = std.testing.io;
    var ts = try tmpJournal();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try ts.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "before" });

    // Simulate crash: write an intent line + apply the change manually, no commit.
    const intent = "{\"t\":\"intent\",\"gid\":99,\"ts_ms\":1,\"label\":\"crash\",\"ops\":[{\"op\":\"write\",\"path\":\"a.txt\",\"before\":\"before\",\"after\":\"after\",\"before_sha256\":\"x\",\"after_sha256\":\"y\"}]}\n";
    try ts.dir.writeFile(io, .{ .sub_path = "journal.jsonl", .data = intent });
    try ts.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "after" });

    var j = try Journal.open(io, arena, ts.dir); // recovery happens here
    defer j.close();
    const cur = try ts.dir.readFileAlloc(io, "a.txt", arena, .limited(1024));
    try std.testing.expectEqualStrings("before", cur); // rolled back
}

test "journal refuses unsafe paths and oversized images" {
    const io = std.testing.io;
    var ts = try tmpJournal();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var j = try Journal.open(io, arena, ts.dir);
    defer j.close();

    try std.testing.expectError(error.PathUnsafe, j.apply("x", &.{.{ .create = .{ .path = "../evil.txt", .after = "pwn" } }}));
    try std.testing.expectError(error.PathUnsafe, j.apply("x", &.{.{ .create = .{ .path = "/abs/path.txt", .after = "pwn" } }}));
    const big = "x" ** (max_before_image_bytes + 1);
    try std.testing.expectError(error.NotJournalable, j.apply("x", &.{.{ .create = .{ .path = "big.txt", .after = big } }}));
}
