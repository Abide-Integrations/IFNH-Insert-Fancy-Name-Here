//! Session persistence: one directory per session with an append-only
//! JSONL event log, a manifest, and an advisory lock (DESIGN §3.4, DECISIONS A4-A14).
//!
//! Durability model: events are appended with `writePositionalAll` at the
//! tracked byte offset (O_APPEND-equivalent semantics); the manifest
//! watermark is refreshed atomically at turn boundaries and close. On open,
//! the event log is rescanned as the source of truth; a torn tail (final
//! line without newline, from a crash mid-write) is ignored.

const std = @import("std");
const fsutil = @import("../fsutil.zig");

pub const manifest_schema_version: u32 = 1;
pub const max_event_bytes: usize = 4 * 1024 * 1024;

// ---------------------------------------------------------------- ids

pub const id_len: usize = 12;

pub const SessionId = struct {
    buf: [id_len]u8,
    valid_len: u8 = id_len,

    /// `s_` + 12 URL-safe base64 characters (DECISIONS A6).
    pub fn generate(io: std.Io) SessionId {
        var raw: [9]u8 = undefined;
        io.random(&raw);
        var out: [id_len]u8 = undefined;
        const enc = std.base64.url_safe.Encoder;
        // 9 bytes -> 12 chars exactly.
        _ = enc.encode(&out, &raw);
        return .{ .buf = out, .valid_len = id_len };
    }

    pub fn text(self: *const SessionId) []const u8 {
        return self.buf[0..self.valid_len];
    }

    pub fn parse(s: []const u8) ?SessionId {
        if (s.len != id_len) return null;
        for (s) |c| {
            const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '-' or c == '_';
            if (!ok) return null;
        }
        var out: SessionId = .{ .buf = undefined };
        @memcpy(&out.buf, s);
        return out;
    }
};

pub fn sessionIdPrefix(full: []const u8) []const u8 {
    // Full ids on disk are `s_<12>`; tolerate bare ids too.
    if (std.mem.startsWith(u8, full, "s_") and full.len == 1 + 1 + id_len) {
        return full[2..];
    }
    return full;
}

// ---------------------------------------------------------------- events

pub const Event = union(enum) {
    user: struct { text: []const u8 },
    assistant: struct { text: []const u8, tool_calls_json: ?[]const u8 = null },
    tool_call: struct { id: []const u8, name: []const u8, arguments_json: []const u8 },
    tool_result: struct { call_id: []const u8, status: []const u8, output: []const u8 },
    note: struct { text: []const u8 },
    interrupted: struct {},
};

pub const Record = struct {
    seq: u64,
    ts_ms: i64,
    event: Event,
};

fn eventName(e: Event) []const u8 {
    return switch (e) {
        .user => "user",
        .assistant => "assistant",
        .tool_call => "tool_call",
        .tool_result => "tool_result",
        .note => "note",
        .interrupted => "interrupted",
    };
}

fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

fn eventToJson(arena: std.mem.Allocator, seq: u64, ts_ms: i64, event: Event) ![]u8 {
    const Value = std.json.Value;
    var ev_obj = try std.json.ObjectMap.init(arena, &.{}, &.{});
    const kind = eventName(event);
    try ev_obj.put(arena, "kind", .{ .string = kind });
    switch (event) {
        .user => |v| try ev_obj.put(arena, "text", .{ .string = v.text }),
        .assistant => |v| {
            try ev_obj.put(arena, "text", .{ .string = v.text });
            if (v.tool_calls_json) |tcj| {
                // Embed the JSON array as a raw value.
                if (std.json.parseFromSliceLeaky(std.json.Value, arena, tcj, .{})) |parsed| {
                    try ev_obj.put(arena, "tool_calls", parsed);
                } else |_| {}
            }
        },
        .tool_call => |v| {
            try ev_obj.put(arena, "id", .{ .string = v.id });
            try ev_obj.put(arena, "name", .{ .string = v.name });
            try ev_obj.put(arena, "arguments_json", .{ .string = v.arguments_json });
        },
        .tool_result => |v| {
            try ev_obj.put(arena, "call_id", .{ .string = v.call_id });
            try ev_obj.put(arena, "status", .{ .string = v.status });
            try ev_obj.put(arena, "output", .{ .string = v.output });
        },
        .note => |v| try ev_obj.put(arena, "text", .{ .string = v.text }),
        .interrupted => {},
    }
    var top = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try top.put(arena, "seq", .{ .integer = @intCast(seq) });
    try top.put(arena, "ts_ms", .{ .integer = ts_ms });
    try top.put(arena, "event", .{ .object = ev_obj });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(Value{ .object = top }, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

// ---------------------------------------------------------------- manifest

pub const Manifest = struct {
    schema_version: u32 = manifest_schema_version,
    id: []const u8,
    created_ms: i64,
    cwd: []const u8,
    title: ?[]const u8 = null,
    seq_watermark: u64 = 0,
    byte_watermark: u64 = 0,
    /// Parent session id when this session is a fork (A11).
    fork_of: ?[]const u8 = null,
};

fn manifestToJson(arena: std.mem.Allocator, m: Manifest) ![]u8 {
    const Value = std.json.Value;
    var obj = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try obj.put(arena, "schema_version", .{ .integer = m.schema_version });
    try obj.put(arena, "id", .{ .string = m.id });
    try obj.put(arena, "created_ms", .{ .integer = m.created_ms });
    try obj.put(arena, "cwd", .{ .string = m.cwd });
    try obj.put(arena, "title", if (m.title) |t| Value{ .string = t } else .null);
    try obj.put(arena, "seq_watermark", .{ .integer = @intCast(m.seq_watermark) });
    try obj.put(arena, "byte_watermark", .{ .integer = @intCast(m.byte_watermark) });
    try obj.put(arena, "fork_of", if (m.fork_of) |f| std.json.Value{ .string = f } else .null);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(Value{ .object = obj }, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
}

fn manifestFromJson(arena: std.mem.Allocator, v: std.json.Value) !Manifest {
    if (v != .object) return error.CorruptManifest;
    const o = v.object;
    const id_v = o.get("id") orelse return error.CorruptManifest;
    if (id_v != .string) return error.CorruptManifest;
    const created = o.get("created_ms") orelse return error.CorruptManifest;
    if (created != .integer) return error.CorruptManifest;
    const cwd_v = o.get("cwd") orelse return error.CorruptManifest;
    if (cwd_v != .string) return error.CorruptManifest;
    var m = Manifest{
        .id = try arena.dupe(u8, id_v.string),
        .created_ms = created.integer,
        .cwd = try arena.dupe(u8, cwd_v.string),
    };
    if (o.get("title")) |t| {
        if (t == .string) m.title = try arena.dupe(u8, t.string);
    }
    if (o.get("seq_watermark")) |s| {
        if (s == .integer) m.seq_watermark = @intCast(s.integer);
    }
    if (o.get("byte_watermark")) |b| {
        if (b == .integer) m.byte_watermark = @intCast(b.integer);
    }
    if (o.get("fork_of")) |f| {
        if (f == .string) m.fork_of = try arena.dupe(u8, f.string);
    }
    return m;
}

// ---------------------------------------------------------------- session

pub const OpenError = error{SessionBusy} || anyerror;

pub const Session = struct {
    io: std.Io,
    /// Session-lifetime allocator. Must be an arena owned by the caller that
    /// outlives the Session (manifest/id/path strings are retained in it).
    /// Per-operation scratch is handled with internal temporary arenas.
    alloc: std.mem.Allocator,
    dir: std.Io.Dir, // session directory
    parent: std.Io.Dir, // directory containing `sessions/`
    sessions_rel_path: []const u8,
    id: SessionId,
    manifest: Manifest,
    events_file: ?std.Io.File = null,
    lock_file: ?std.Io.File = null,
    seq: u64 = 0,
    byte_offset: u64 = 0,
    dirty: bool = false,

    pub fn dirName(id: SessionId) [2 + id_len]u8 {
        var name: [2 + id_len]u8 = undefined;
        name[0] = 's';
        name[1] = '_';
        @memcpy(name[2..], id.text());
        return name;
    }

    /// Create a brand-new session under `<parent>/<sessions_rel_path>/s_<id>/`.
    pub fn create(
        parent: std.Io.Dir,
        io: std.Io,
        alloc: std.mem.Allocator,
        sessions_rel_path: []const u8,
        cwd: []const u8,
    ) !Session {
        const id = SessionId.generate(io);
        var self = Session{
            .io = io,
            .alloc = alloc,
            .dir = undefined, // opened below
            .parent = parent,
            .sessions_rel_path = try alloc.dupe(u8, sessions_rel_path),
            .id = id,
            .manifest = .{
                .id = try std.fmt.allocPrint(alloc, "s_{s}", .{id.text()}),
                .created_ms = nowMs(io),
                .cwd = try alloc.dupe(u8, cwd),
            },
        };

        var name_buf: [2 + id_len]u8 = dirName(id);
        const rel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sessions_rel_path, name_buf[0..] });
        try parent.createDirPath(io, rel);
        self.dir = try parent.openDir(io, rel, .{ .access_sub_paths = true });
        errdefer self.dir.close(io);

        try self.acquireLock();
        errdefer self.releaseLock();

        // Truncate-fresh event log.
        self.events_file = try self.dir.createFile(io, "events.jsonl", .{ .truncate = true });
        try self.writeManifest();
        return self;
    }

    /// Open an existing session by id (with or without `s_` prefix).
    pub fn open(
        parent: std.Io.Dir,
        io: std.Io,
        alloc: std.mem.Allocator,
        sessions_rel_path: []const u8,
        full_id: []const u8,
    ) OpenError!Session {
        const bare = SessionId.parse(sessionIdPrefix(full_id)) orelse return error.InvalidSessionId;
        var name_buf: [2 + id_len]u8 = undefined;
        name_buf[0] = 's';
        name_buf[1] = '_';
        @memcpy(name_buf[2..], bare.text());

        const rel = std.fmt.allocPrint(alloc, "{s}/{s}", .{ sessions_rel_path, name_buf[0..] }) catch
            return error.OutOfMemory;
        var dir = parent.openDir(io, rel, .{ .access_sub_paths = true }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        errdefer dir.close(io);

        var self = Session{
            .io = io,
            .alloc = alloc,
            .dir = dir,
            .parent = parent,
            .sessions_rel_path = try alloc.dupe(u8, sessions_rel_path),
            .id = bare,
            .manifest = undefined,
        };

        try self.acquireLock(); // error.SessionBusy on contention
        errdefer self.releaseLock();

        const manifest_text = fsutil.readSmallFile(self.dir, io, alloc, "manifest.json", 64 * 1024) catch
            return error.CorruptManifest;
        const mv = std.json.parseFromSliceLeaky(std.json.Value, alloc, manifest_text, .{}) catch
            return error.CorruptManifest;
        self.manifest = manifestFromJson(alloc, mv) catch return error.CorruptManifest;

        // Rescan event log as source of truth; ignore torn tail.
        try self.rescanEvents();
        return self;
    }

    fn acquireLock(self: *Session) !void {
        const f = try self.dir.createFile(self.io, "session.lock", .{ .truncate = false });
        self.lock_file = f;
        const got = f.tryLock(self.io, .exclusive) catch |err| {
            f.close(self.io);
            self.lock_file = null;
            return err;
        };
        if (!got) {
            f.close(self.io);
            self.lock_file = null;
            return error.SessionBusy;
        }
    }

    fn releaseLock(self: *Session) void {
        if (self.lock_file) |f| {
            f.unlock(self.io);
            f.close(self.io);
            self.lock_file = null;
        }
    }

    /// Rescan the event log to recover seq/byte position. A torn tail
    /// (final line lacking a newline) is ignored. Opens the log read-write
    /// for future appends.
    fn rescanEvents(self: *Session) !void {
        const f = try self.dir.openFile(self.io, "events.jsonl", .{});
        defer f.close(self.io);
        const stat = try f.stat(self.io);
        const size: usize = @intCast(stat.size);
        self.seq = 0;
        self.byte_offset = 0;
        if (size == 0) {
            self.events_file = try self.dir.openFile(self.io, "events.jsonl", .{ .mode = .read_write });
            return;
        }

        const buf = try self.alloc.alloc(u8, size);
        defer self.alloc.free(buf);
        _ = try f.readPositionalAll(self.io, buf, 0);

        // Walk complete lines; last complete line sets seq + offset.
        // Parsing runs in a scratch arena (nothing retained).
        var scratch_state = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        var line_start: usize = 0;
        var last_seq: u64 = 0;
        while (std.mem.indexOfScalarPos(u8, buf[0..size], line_start, '\n')) |nl| {
            const line = buf[line_start..nl];
            if (parseSeq(scratch, line) catch null) |s| last_seq = s;
            line_start = nl + 1;
        }
        self.seq = last_seq;
        self.byte_offset = line_start;
        self.events_file = try self.dir.openFile(self.io, "events.jsonl", .{ .mode = .read_write });
    }

    /// Extract the `seq` field from one JSONL line, if well-formed.
    fn parseSeq(alloc: std.mem.Allocator, line: []const u8) !u64 {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        if (v != .object) return error.BadRecord;
        const seq_v = v.object.get("seq") orelse return error.BadRecord;
        if (seq_v != .integer) return error.BadRecord;
        return @intCast(seq_v.integer);
    }

    /// Append one event; returns its record. Linear seq, newline-terminated.
    pub fn append(self: *Session, event: Event) !Record {
        const f = self.events_file orelse return error.SessionClosed;
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        self.seq += 1;
        const ts_ms = nowMs(self.io);
        const line = try eventToJson(arena, self.seq, ts_ms, event);
        try f.writePositionalAll(self.io, line, self.byte_offset);
        self.byte_offset += line.len;
        self.dirty = true;
        return .{ .seq = self.seq, .ts_ms = ts_ms, .event = event };
    }

    /// Atomically rewrite the manifest with the current watermark.
    pub fn writeManifest(self: *Session) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        self.manifest.seq_watermark = self.seq;
        self.manifest.byte_watermark = self.byte_offset;
        const text = try manifestToJson(arena_state.allocator(), self.manifest);
        try fsutil.atomicWriteFile(self.dir, self.io, self.alloc, "manifest.json", text);
        self.dirty = false;
    }

    /// Refresh the manifest watermark (idempotent, cheap when clean).
    pub fn syncWatermark(self: *Session) !void {
        if (!self.dirty) return;
        try self.writeManifest();
    }

    /// Read all complete events (bounded by max_events). Records and their
    /// strings are allocated in `arena`; the caller frees the arena, not
    /// the returned slice.
    pub fn readEvents(self: *Session, arena: std.mem.Allocator, max_events: usize) ![]Record {
        const f = try self.dir.openFile(self.io, "events.jsonl", .{});
        defer f.close(self.io);
        const stat = try f.stat(self.io);
        const size: usize = @intCast(stat.size);
        if (size == 0) return &.{};
        if (size > max_log_bytes) return error.LogTooLarge;

        const buf = try arena.alloc(u8, size);
        _ = try f.readPositionalAll(self.io, buf, 0);

        var out: std.ArrayListUnmanaged(Record) = .empty;
        var line_start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buf[0..size], line_start, '\n')) |nl| {
            const line = buf[line_start..nl];
            line_start = nl + 1;
            if (out.items.len >= max_events) break;
            if (line.len == 0 or line.len > max_event_bytes) continue;
            const rec = parseRecord(arena, line) catch continue;
            try out.append(arena, rec);
        }
        return out.items;
    }

    fn parseRecord(arena: std.mem.Allocator, line: []const u8) !Record {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        if (v != .object) return error.BadRecord;
        const o = v.object;
        const seq_v = o.get("seq") orelse return error.BadRecord;
        const ts_v = o.get("ts_ms") orelse return error.BadRecord;
        const ev_v = o.get("event") orelse return error.BadRecord;
        if (seq_v != .integer or ts_v != .integer or ev_v != .object) return error.BadRecord;
        const eo = ev_v.object;
        const kind_v = eo.get("kind") orelse return error.BadRecord;
        if (kind_v != .string) return error.BadRecord;
        const kind = kind_v.string;

        const getStr = struct {
            fn f(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
                const x = obj.get(key) orelse return error.BadRecord;
                if (x != .string) return error.BadRecord;
                return x.string;
            }
        }.f;

        const event: Event = if (std.mem.eql(u8, kind, "user"))
            .{ .user = .{ .text = try arena.dupe(u8, try getStr(eo, "text")) } }
        else if (std.mem.eql(u8, kind, "assistant")) blk: {
            var tcj: ?[]const u8 = null;
            if (eo.get("tool_calls")) |tcv| {
                if (tcv == .array) {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(tcv, .{}, &aw.writer);
                    tcj = aw.written();
                }
            }
            break :blk .{ .assistant = .{ .text = try arena.dupe(u8, try getStr(eo, "text")), .tool_calls_json = tcj } };
        } else if (std.mem.eql(u8, kind, "tool_call"))
            .{ .tool_call = .{
                .id = try arena.dupe(u8, try getStr(eo, "id")),
                .name = try arena.dupe(u8, try getStr(eo, "name")),
                .arguments_json = try arena.dupe(u8, try getStr(eo, "arguments_json")),
            } }
        else if (std.mem.eql(u8, kind, "tool_result"))
            .{ .tool_result = .{
                .call_id = try arena.dupe(u8, try getStr(eo, "call_id")),
                .status = try arena.dupe(u8, try getStr(eo, "status")),
                .output = try arena.dupe(u8, try getStr(eo, "output")),
            } }
        else if (std.mem.eql(u8, kind, "note"))
            .{ .note = .{ .text = try arena.dupe(u8, try getStr(eo, "text")) } }
        else if (std.mem.eql(u8, kind, "interrupted"))
            .interrupted
        else
            return error.BadRecord;

        return .{ .seq = @intCast(seq_v.integer), .ts_ms = ts_v.integer, .event = event };
    }

    pub fn close(self: *Session) void {
        self.syncWatermark() catch {};
        if (self.events_file) |f| {
            f.close(self.io);
            self.events_file = null;
        }
        self.dir.close(self.io);
        self.releaseLock();
    }

    /// Fork this session: create a new session dir inheriting the event
    /// log up to the current watermark (A11). Returns the new Session.
    pub fn fork(self: *Session) !Session {
        var fresh = try Session.create(self.parent, self.io, self.alloc, self.sessions_rel_path, self.manifest.cwd);
        errdefer fresh.close();
        // Copy committed events.
        if (self.byte_offset > 0) {
            const f = try self.dir.openFile(self.io, "events.jsonl", .{});
            defer f.close(self.io);
            const buf = try self.alloc.alloc(u8, self.byte_offset);
            defer self.alloc.free(buf);
            _ = try f.readPositionalAll(self.io, buf, 0);
            try fresh.events_file.?.writePositionalAll(self.io, buf, 0);
            fresh.seq = self.seq;
            fresh.byte_offset = self.byte_offset;
            try fresh.writeManifest();
        }
        fresh.manifest.fork_of = try self.alloc.dupe(u8, self.manifest.id);
        try fresh.writeManifest();
        return fresh;
    }
};

// ---------------------------------------------------------------- listing

pub const SessionSummary = struct {
    id: []const u8, // full, e.g. "s_abc..."
    created_ms: i64,
    cwd: []const u8,
    title: ?[]const u8,
};

pub const max_log_bytes: usize = 256 * 1024 * 1024;

/// List sessions under `<parent>/<sessions_rel_path>/`, newest first.
pub fn list(
    parent: std.Io.Dir,
    io: std.Io,
    alloc: std.mem.Allocator,
    sessions_rel_path: []const u8,
) ![]SessionSummary {
    var out: std.ArrayListUnmanaged(SessionSummary) = .empty;
    var dir = parent.openDir(io, sessions_rel_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "s_")) continue;
        const manifest_rel = std.fmt.allocPrint(alloc, "{s}/{s}/manifest.json", .{ sessions_rel_path, entry.name }) catch continue;
        const text = fsutil.readSmallFile(parent, io, alloc, manifest_rel, 64 * 1024) catch continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch continue;
        const m = manifestFromJson(alloc, v) catch continue;
        try out.append(alloc, .{
            .id = m.id,
            .created_ms = m.created_ms,
            .cwd = m.cwd,
            .title = m.title,
        });
    }
    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(SessionSummary, items, {}, struct {
        fn lt(_: void, a: SessionSummary, b: SessionSummary) bool {
            return a.created_ms > b.created_ms;
        }
    }.lt);
    return items;
}

// ---------------------------------------------------------------- tests

fn testingSession() !struct { tmp: std.testing.TmpDir, parent: std.Io.Dir } {
    const tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    errdefer tmp.cleanup();
    return .{ .tmp = tmp, .parent = tmp.dir };
}

test "session create, append, reopen, replay" {
    const io = std.testing.io;
    var ts = try testingSession();
    defer ts.tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var s = try Session.create(ts.parent, io, arena, "sessions", "/tmp/proj");
        defer s.close();
        _ = try s.append(.{ .user = .{ .text = "hello" } });
        _ = try s.append(.{ .assistant = .{ .text = "hi there" } });
        _ = try s.append(.{ .tool_call = .{ .id = "c1", .name = "read", .arguments_json = "{}" } });
        try std.testing.expectEqual(@as(u64, 3), s.seq);
    }

    {
        // Reopen by full id from create's manifest listing.
        const summaries = try list(ts.parent, io, arena, "sessions");
        try std.testing.expectEqual(@as(usize, 1), summaries.len);

        var s = try Session.open(ts.parent, io, arena, "sessions", summaries[0].id);
        defer s.close();
        try std.testing.expectEqual(@as(u64, 3), s.seq);

        const events = try s.readEvents(arena, 1000);
        try std.testing.expectEqual(@as(usize, 3), events.len);
        try std.testing.expectEqual(EventKindTag.user, std.meta.activeTag(events[0].event));
        try std.testing.expectEqualStrings("hello", events[0].event.user.text);
        try std.testing.expectEqualStrings("read", events[2].event.tool_call.name);
    }
}

const EventKindTag = std.meta.Tag(Event);

test "session busy on concurrent open" {
    const io = std.testing.io;
    var ts = try testingSession();
    defer ts.tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s1 = try Session.create(ts.parent, io, arena, "sessions", "/tmp/proj");
    defer s1.close();

    try std.testing.expectError(error.SessionBusy, Session.open(ts.parent, io, arena, "sessions", s1.manifest.id));
}

test "torn tail ignored on reopen" {
    const io = std.testing.io;
    var ts = try testingSession();
    defer ts.tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var s = try Session.create(ts.parent, io, arena, "sessions", "/tmp/proj");
        defer s.close();
        _ = try s.append(.{ .user = .{ .text = "complete" } });
        // Simulate crash mid-append: partial bytes without newline, bypassing append().
        try s.events_file.?.writePositionalAll(io, "{\"seq\":2,\"ts_ms\":1,\"event\":{\"kind\":\"use", s.byte_offset);
    }

    const summaries = try list(ts.parent, io, arena, "sessions");
    try std.testing.expectEqual(@as(usize, 1), summaries.len);

    var s2 = try Session.open(ts.parent, io, arena, "sessions", summaries[0].id);
    defer s2.close();
    try std.testing.expectEqual(@as(u64, 1), s2.seq);
    const events = try s2.readEvents(arena, 100);
    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "id validation" {
    const io = std.testing.io;
    const id = SessionId.generate(io);
    try std.testing.expectEqual(id_len, id.text().len);
    try std.testing.expect(SessionId.parse(id.text()) != null);
    try std.testing.expect(SessionId.parse("short") == null);
    try std.testing.expect(SessionId.parse("has space_______") == null);
}

test "fork inherits events and records parent" {
    const io = std.testing.io;
    var ts = try testingSession();
    defer ts.tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Session.create(ts.parent, io, arena, "sessions", "/tmp/proj");
    defer s.close();
    _ = try s.append(.{ .user = .{ .text = "before fork" } });

    var child = try s.fork();
    defer child.close();
    try std.testing.expect(child.manifest.fork_of != null);
    try std.testing.expectEqualStrings(s.manifest.id, child.manifest.fork_of.?);
    try std.testing.expectEqual(s.seq, child.seq);

    // New events diverge.
    _ = try child.append(.{ .assistant = .{ .text = "on the fork" } });
    try std.testing.expectEqual(s.seq + 1, child.seq);
    try std.testing.expectEqual(@as(u64, 1), s.seq);

    const events = try child.readEvents(arena, 100);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("before fork", events[0].event.user.text);
}
