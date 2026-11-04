//! `ifnh debug-bundle` (D-09): one redacted JSON file for bug reports.
//!
//! Everything that goes in is either structural (versions, key names, layer
//! origins, counts) or passed through `redact`. Config keys that look like
//! credentials are removed, session message text is never read into the
//! bundle, and the user env file (`~/.config/ifnh/env`) is never opened.

const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config/config.zig");
const redact = @import("redact.zig");
const fsutil = @import("fsutil.zig");
const session_store = @import("session/store.zig");

pub const max_log_lines: usize = 200;
const max_log_line_bytes: usize = 16 * 1024;
const max_sessions: usize = 20;
const max_file_bytes: usize = 64 * 1024 * 1024;

pub const LogSource = struct { name: []const u8, text: []const u8 };

pub const SessionInfo = struct {
    id: []const u8,
    created_ms: i64,
    updated_ms: i64,
    turns: u32,
};

pub const Inputs = struct {
    version: []const u8,
    git_tag: []const u8 = "",
    cfg: *const config_mod.Store,
    doctor: []const u8,
    logs: []const LogSource,
    sessions: []const SessionInfo,
    environ: *const std.process.Environ.Map,
    /// Exact secret values to scrub from the whole document.
    secrets: []const []const u8,
};

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// `api_key`, `token`, `secret`, `password` in the name. Plural `*_tokens`
/// names are counts (`max_output_tokens`), not credentials, and stay.
pub fn isSecretName(name: []const u8) bool {
    if (containsIgnoreCase(name, "api_key") or containsIgnoreCase(name, "apikey") or
        containsIgnoreCase(name, "secret") or containsIgnoreCase(name, "password")) return true;
    if (std.ascii.endsWithIgnoreCase(name, "_tokens")) return false;
    return containsIgnoreCase(name, "token");
}

fn looksSecretEnv(name: []const u8) bool {
    return isSecretName(name) or containsIgnoreCase(name, "key");
}

const alias_keys = [_][]const u8{ "provider", "model", "base_url" };

fn sanitize(arena: std.mem.Allocator, v: std.json.Value, path: []const u8, alias_entry: bool) std.mem.Allocator.Error!std.json.Value {
    if (v != .object) return v;
    var out = try std.json.ObjectMap.init(arena, &.{}, &.{});
    var it = v.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (isSecretName(key)) continue;
        if (alias_entry) {
            // `models.aliases.<name>` keeps only where the request goes.
            const keep = for (alias_keys) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false;
            if (!keep) continue;
        }
        const child_path = if (path.len == 0) key else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, key });
        const child_is_alias = std.mem.eql(u8, path, "models.aliases");
        try out.put(arena, key, try sanitize(arena, e.value_ptr.*, child_path, child_is_alias));
    }
    return .{ .object = out };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeTail(arena: std.mem.Allocator, s: *std.json.Stringify, text: []const u8, secrets: []const []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| try lines.append(arena, line);
    const start = if (lines.items.len > max_log_lines) lines.items.len - max_log_lines else 0;
    try s.beginArray();
    for (lines.items[start..]) |line| {
        const cut = if (line.len > max_log_line_bytes) line[0..max_log_line_bytes] else line;
        try s.write(redact.redact(arena, cut, secrets));
    }
    try s.endArray();
}

/// Build the bundle document. Pure over `in`.
pub fn build(arena: std.mem.Allocator, in: Inputs) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();

    try s.objectField("version");
    try s.beginObject();
    try s.objectField("ifnh");
    try s.write(in.version);
    try s.objectField("git_tag");
    try s.write(in.git_tag);
    try s.endObject();

    try s.objectField("platform");
    try s.beginObject();
    try s.objectField("os");
    try s.write(@tagName(builtin.os.tag));
    try s.objectField("arch");
    try s.write(@tagName(builtin.cpu.arch));
    try s.objectField("zig");
    try s.write(builtin.zig_version_string);
    try s.endObject();

    try s.objectField("config");
    try s.write(try sanitize(arena, in.cfg.value, "", false));

    try s.objectField("config_sources");
    try s.beginObject();
    var keys: std.ArrayList([]const u8) = .empty;
    var kit = in.cfg.sources.keyIterator();
    while (kit.next()) |k| {
        if (!pathHasSecretName(k.*)) try keys.append(arena, k.*);
    }
    std.mem.sort([]const u8, keys.items, {}, lessThan);
    for (keys.items) |k| {
        const src = in.cfg.sources.get(k).?;
        try s.objectField(k);
        try s.beginObject();
        try s.objectField("layer");
        try s.write(src.layer.name());
        try s.objectField("origin");
        try s.write(src.origin);
        try s.endObject();
    }
    try s.endObject();

    try s.objectField("config_errors");
    try s.beginArray();
    for (in.cfg.errors.items) |e| {
        try s.beginObject();
        try s.objectField("path");
        try s.write(e.path);
        try s.objectField("message");
        try s.write(e.message);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("config_warnings");
    try s.write(in.cfg.warnings.items);

    try s.objectField("doctor");
    try s.write(in.doctor);

    try s.objectField("logs");
    try s.beginArray();
    for (in.logs) |log| {
        try s.beginObject();
        try s.objectField("file");
        try s.write(log.name);
        try s.objectField("lines");
        try writeTail(arena, &s, log.text, in.secrets);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("sessions");
    try s.beginArray();
    for (in.sessions) |si| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(si.id);
        try s.objectField("created_ms");
        try s.write(si.created_ms);
        try s.objectField("updated_ms");
        try s.write(si.updated_ms);
        try s.objectField("turns");
        try s.write(si.turns);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("env");
    try s.beginObject();
    var env_keys: std.ArrayList([]const u8) = .empty;
    var eit = in.environ.iterator();
    while (eit.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.startsWith(u8, k, "IFNH_") or isFixedEnv(k)) try env_keys.append(arena, k);
    }
    std.mem.sort([]const u8, env_keys.items, {}, lessThan);
    for (env_keys.items) |k| {
        try s.objectField(k);
        try s.write(if (looksSecretEnv(k)) redact.marker else in.environ.get(k).?);
    }
    try s.endObject();

    try s.endObject();
    // Last line of defence: the whole document goes through redact once more.
    return redact.redact(arena, aw.written(), in.secrets);
}

fn isFixedEnv(name: []const u8) bool {
    for ([_][]const u8{ "TERM", "SHELL", "OS", "ARCH" }) |k| {
        if (std.mem.eql(u8, k, name)) return true;
    }
    return false;
}

fn pathHasSecretName(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        if (isSecretName(part)) return true;
    }
    return false;
}

/// Write the bundle privately (0600 from creation) and atomically.
pub fn write(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, doc: []const u8) !void {
    try fsutil.atomicWriteFilePerm(dir, io, arena, path, doc, std.Io.File.Permissions.fromMode(0o600));
}

/// Newest `max_sessions` sessions: id, created, last-write time, user turns.
/// Only counts are read from the event log, never message text.
pub fn collectSessions(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sessions_rel: []const u8) []const SessionInfo {
    const summaries = session_store.list(dir, io, arena, sessions_rel) catch return &.{};
    var out: std.ArrayList(SessionInfo) = .empty;
    for (summaries[0..@min(summaries.len, max_sessions)]) |sm| {
        const rel = std.fmt.allocPrint(arena, "{s}/{s}/events.jsonl", .{ sessions_rel, sm.id }) catch continue;
        var info = SessionInfo{ .id = sm.id, .created_ms = sm.created_ms, .updated_ms = sm.created_ms, .turns = 0 };
        if (dir.statFile(io, rel, .{})) |st| {
            info.updated_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
        } else |_| {}
        if (fsutil.readSmallFile(dir, io, arena, rel, max_file_bytes)) |text| {
            info.turns = @intCast(std.mem.count(u8, text, "\"kind\":\"user\""));
        } else |_| {}
        out.append(arena, info) catch break;
    }
    return out.items;
}

/// Read every regular file under `logs_dir` (best effort, sorted by name).
pub fn collectLogDir(arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8) []const LogSource {
    var out: std.ArrayList(LogSource) = .empty;
    var d = std.Io.Dir.cwd().openDir(io, logs_dir, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const text = fsutil.readSmallFile(d, io, arena, entry.name, max_file_bytes) catch continue;
        const name = std.fmt.allocPrint(arena, "{s}/{s}", .{ logs_dir, entry.name }) catch continue;
        out.append(arena, .{ .name = name, .text = text }) catch break;
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

test "bundle drops credential config, redacts logs and keeps the rest" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var cfg = try config_mod.Store.init(std.testing.allocator);
    defer cfg.deinit();
    const layer =
        \\{ "model": { "model": "m1", "provider": "anthropic", "api_token": "tok-supersecret-ABCDEFGHIJKLMNOPQRSTUV" },
        \\  "models": { "aliases": { "fast": { "provider": "openai", "model": "x", "base_url": "https://h/v1", "api_key": "sk-aliaskey-ABCDEFGHIJKLMNOPQRSTUV", "extra": 1 } } },
        \\  "mcp_servers": { "s": { "password": "hunter2hunter2" } } }
    ;
    try cfg.mergeValue(try std.json.parseFromSliceLeaky(std.json.Value, cfg.alloc(), layer, .{}), .{ .layer = .project, .origin = ".ifnh/config.json" });

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "wire.ndjson", .data = "{\"kind\":\"request\",\"body\":\"key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV and ghp_abcdefghijklmnopqrstuvwxyz0123456789\"}\nsecond line\n" });
    const log_text = try tmp.dir.readFileAlloc(io, "wire.ndjson", a, .limited(1 << 16));

    var env = std.process.Environ.Map.init(a);
    try env.put("IFNH_TRACE_LOG", "/tmp/x");
    try env.put("IFNH_API_KEY", "envsecretvalue1234");
    try env.put("TERM", "xterm");
    try env.put("HOME", "/home/nobody");
    try env.put("ANTHROPIC_API_KEY", "sk-ant-envkey-ABCDEFGHIJKLMNOPQRSTUV");

    const doc = try build(a, .{
        .version = "9.9.9",
        .cfg = &cfg,
        .doctor = "ifnh doctor\n  config: ok\n",
        .logs = &.{.{ .name = "wire.ndjson", .text = log_text }},
        .sessions = &.{.{ .id = "s_abc", .created_ms = 1, .updated_ms = 2, .turns = 3 }},
        .environ = &env,
        .secrets = &.{"envsecretvalue1234"},
    });
    for ([_][]const u8{ "supersecret", "sk-ant", "ghp_", "hunter2", "aliaskey", "envsecretvalue", "ANTHROPIC_API_KEY", "/home/nobody" }) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, doc, bad) == null);
    }
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, doc, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("9.9.9", o.get("version").?.object.get("ifnh").?.string);
    try std.testing.expectEqualStrings("m1", o.get("config").?.object.get("model").?.object.get("model").?.string);
    const fast = o.get("config").?.object.get("models").?.object.get("aliases").?.object.get("fast").?.object;
    try std.testing.expectEqual(@as(usize, 3), fast.count());
    try std.testing.expectEqualStrings("project", o.get("config_sources").?.object.get("model.provider").?.object.get("layer").?.string);
    try std.testing.expectEqual(@as(usize, 2), o.get("logs").?.array.items[0].object.get("lines").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 3), o.get("sessions").?.array.items[0].object.get("turns").?.integer);
    try std.testing.expectEqualStrings("[REDACTED]", o.get("env").?.object.get("IFNH_API_KEY").?.string);
    try std.testing.expectEqualStrings("xterm", o.get("env").?.object.get("TERM").?.string);
    try std.testing.expect(o.get("env").?.object.get("HOME") == null);
}

test "bundle keeps only the last log lines and counts sessions from raw events" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var cfg = try config_mod.Store.init(std.testing.allocator);
    defer cfg.deinit();
    var text: std.ArrayList(u8) = .empty;
    for (0..300) |i| try text.print(a, "line {d}\n", .{i});
    var env = std.process.Environ.Map.init(a);
    const doc = try build(a, .{ .version = "v", .cfg = &cfg, .doctor = "", .logs = &.{.{ .name = "l", .text = text.items }}, .sessions = &.{}, .environ = &env, .secrets = &.{} });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, doc, .{});
    const lines = v.object.get("logs").?.array.items[0].object.get("lines").?.array.items;
    try std.testing.expectEqual(@as(usize, max_log_lines), lines.len);
    try std.testing.expectEqualStrings("line 299", lines[lines.len - 1].string);

    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var sess = try session_store.Session.create(tmp.dir, io, a, ".ifnh/sessions", "/w");
    _ = try sess.append(.{ .user = .{ .text = "SECRET-PROMPT-TEXT" } });
    _ = try sess.append(.{ .assistant = .{ .text = "ok" } });
    _ = try sess.append(.{ .user = .{ .text = "again" } });
    sess.close();
    const infos = collectSessions(a, io, tmp.dir, ".ifnh/sessions");
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqual(@as(u32, 2), infos[0].turns);
}

test "bundle file is written 0600 and holds no secret bytes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var cfg = try config_mod.Store.init(std.testing.allocator);
    defer cfg.deinit();
    var env = std.process.Environ.Map.init(a);
    const fake_log = "boot ok\nAuthorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789\nkey=exact-secret-value-123\n";
    const doc = try build(a, .{
        .version = "v",
        .cfg = &cfg,
        .doctor = "",
        .logs = &.{.{ .name = "fake.log", .text = fake_log }},
        .sessions = &.{},
        .environ = &env,
        .secrets = &.{"exact-secret-value-123"},
    });
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    try write(a, io, tmp.dir, "bundle.json", doc);
    const bytes = try tmp.dir.readFileAlloc(io, "bundle.json", a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "abcdefghijklmnopqrstuvwxyz0123456789") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "exact-secret-value-123") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "boot ok") != null);
    const st = try tmp.dir.statFile(io, "bundle.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}
