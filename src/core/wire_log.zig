//! Opt-in wire log (`--trace <path>` / `IFNH_TRACE_LOG`, D-09).
//!
//! One NDJSON object per line, mode 0600:
//!   {"ts_ms","kind":"request"|"response"|"error","provider","model","round",
//!    "url","headers":{...},"body":<parsed JSON or string>}
//! Redaction happens at write time and is not optional: live key values are
//! exact secrets, credential headers are replaced, and the pattern list in
//! `redact.zig` runs over every body and message. A log failure never fails
//! the turn: the first write error prints one warning and disables the log.
//! The sink is owned by the CLI run; a disabled sink is a null `?*WireLog`.

const std = @import("std");
const redact_mod = @import("redact.zig");
const core_types = @import("types.zig");

pub const env_var = "IFNH_TRACE_LOG";

pub const Header = struct { name: []const u8, value: []const u8 };

const credential_headers = [_][]const u8{ "authorization", "x-api-key", "api-key", "proxy-authorization" };

pub const WireLog = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    offset: u64,
    /// Exact secret values (borrowed; must outlive the log).
    secrets: []const []const u8,
    /// Requests started so far; stamped on every line of that request.
    round: u32 = 0,
    failed: bool = false,
    provider: []const u8 = "unknown",
    model: []const u8 = "",
    url_buf: [512]u8 = undefined,
    url_len: usize = 0,

    /// Create (or append to) `path` with mode 0600.
    pub fn open(io: std.Io, gpa: std.mem.Allocator, path: []const u8, secrets: []const []const u8) !WireLog {
        const perm = std.Io.File.Permissions.fromMode(0o600);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = perm });
        errdefer file.close(io);
        // A pre-existing file keeps its old mode through createFile.
        try file.setPermissions(io, perm);
        const stat = try file.stat(io);
        return .{ .io = io, .gpa = gpa, .file = file, .offset = stat.size, .secrets = secrets };
    }

    pub fn close(self: *WireLog) void {
        self.file.close(self.io);
    }

    /// Start of one provider request: bumps the round and records where it goes.
    pub fn begin(self: *WireLog, model: []const u8) void {
        self.round += 1;
        self.model = model;
        self.provider = "unknown";
        self.url_len = 0;
    }

    /// Log the request body actually sent. `url` is reduced to scheme+host+path.
    pub fn request(self: *WireLog, provider: []const u8, url: []const u8, headers: []const Header, body: []const u8, api_key: []const u8) void {
        self.provider = provider;
        self.url_len = sanitizeUrl(&self.url_buf, url);
        self.writeLine("request", headers, body, api_key);
    }

    /// Log a finished response from the accumulated stream events.
    pub fn response(self: *WireLog, acc: *const Accumulator, api_key: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var aw: std.Io.Writer.Allocating = .init(a);
        acc.writeJson(&aw.writer) catch return;
        self.writeLine("response", &.{}, aw.written(), api_key);
    }

    pub fn failure(self: *WireLog, message: []const u8, api_key: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var aw: std.Io.Writer.Allocating = .init(a);
        std.json.Stringify.value(message, .{}, &aw.writer) catch return;
        self.writeLine("error", &.{}, aw.written(), api_key);
    }

    fn writeLine(self: *WireLog, kind: []const u8, headers: []const Header, body: []const u8, api_key: []const u8) void {
        if (self.failed) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const line = self.render(a, kind, headers, body, api_key) catch return;
        self.file.writePositionalAll(self.io, line, self.offset) catch {
            self.failed = true;
            std.Io.File.stderr().writeStreamingAll(self.io, "warning: trace log write failed; tracing disabled\n") catch {};
            return;
        };
        self.offset += line.len;
    }

    fn render(self: *WireLog, a: std.mem.Allocator, kind: []const u8, headers: []const Header, body: []const u8, api_key: []const u8) ![]const u8 {
        // The live API key is always an exact secret, whatever the caller passed.
        var secrets: std.ArrayList([]const u8) = .empty;
        try secrets.appendSlice(a, self.secrets);
        if (api_key.len > 0) try secrets.append(a, api_key);

        const ts = std.Io.Timestamp.now(self.io, .real);
        const ts_ms: i64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
        var aw: std.Io.Writer.Allocating = .init(a);
        const w = &aw.writer;
        try w.print("{{\"ts_ms\":{d},\"kind\":\"{s}\",\"provider\":", .{ ts_ms, kind });
        try std.json.Stringify.value(self.provider, .{}, w);
        try w.writeAll(",\"model\":");
        try std.json.Stringify.value(self.model, .{}, w);
        try w.print(",\"round\":{d},\"url\":", .{self.round});
        try std.json.Stringify.value(self.url_buf[0..self.url_len], .{}, w);
        try w.writeAll(",\"headers\":{");
        for (headers, 0..) |h, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(h.name, .{}, w);
            try w.writeByte(':');
            const value = if (isCredentialHeader(h.name)) redact_mod.marker else redact_mod.redact(a, h.value, secrets.items);
            try std.json.Stringify.value(value, .{}, w);
        }
        try w.writeAll("},\"body\":");
        // Redact the serialized text, then embed it as parsed JSON when it
        // still parses (it does: markers only replace string contents), else
        // as a string.
        const clean = redact_mod.redact(a, body, secrets.items);
        if (std.json.parseFromSliceLeaky(std.json.Value, a, clean, .{})) |_| {
            try w.writeAll(clean);
        } else |_| {
            try std.json.Stringify.value(clean, .{}, w);
        }
        try w.writeAll("}\n");
        return aw.written();
    }
};

fn isCredentialHeader(name: []const u8) bool {
    for (credential_headers) |c| {
        if (std.ascii.eqlIgnoreCase(name, c)) return true;
    }
    return false;
}

/// Copy `scheme://host/path` into `dst` without userinfo, query or fragment;
/// returns the length written (truncated to `dst.len`).
fn sanitizeUrl(dst: []u8, url: []const u8) usize {
    var rest = url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
    var scheme: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        scheme = rest[0 .. i + 3];
        rest = rest[i + 3 ..];
    }
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@')) |at| rest = rest[at + 1 ..];
    var n: usize = 0;
    for ([_][]const u8{ scheme, rest }) |part| {
        const take = @min(part.len, dst.len - n);
        @memcpy(dst[n..][0..take], part[0..take]);
        n += take;
    }
    return n;
}

/// Streamed response, accumulated for the log (never raw SSE frames).
pub const Accumulator = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(core_types.ToolCall) = .empty,
    usage: ?core_types.Usage = null,
    failure_message: ?[]const u8 = null,

    pub fn add(self: *Accumulator, ev: core_types.StreamEvent) void {
        switch (ev) {
            .content_delta => |t| self.text.appendSlice(self.arena, t) catch {},
            .tool_call => |c| self.calls.append(self.arena, .{
                .id = self.arena.dupe(u8, c.id) catch "",
                .name = self.arena.dupe(u8, c.name) catch "",
                .arguments_json = self.arena.dupe(u8, c.arguments_json) catch "",
            }) catch {},
            .usage => |u| self.usage = u,
            .failure => |f| self.failure_message = self.arena.dupe(u8, f.message) catch "",
            .reasoning_delta, .done => {},
        }
    }

    fn writeJson(self: *const Accumulator, w: *std.Io.Writer) !void {
        try w.writeAll("{\"text\":");
        try std.json.Stringify.value(self.text.items, .{}, w);
        try w.writeAll(",\"tool_calls\":[");
        for (self.calls.items, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try std.json.Stringify.value(c.id, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.value(c.name, .{}, w);
            try w.writeAll(",\"arguments\":");
            try std.json.Stringify.value(c.arguments_json, .{}, w);
            try w.writeByte('}');
        }
        try w.writeAll("]");
        if (self.usage) |u| {
            try w.print(",\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d}}}", .{ u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens });
        }
        try w.writeByte('}');
    }
};

// ---------------------------------------------------------------- tests

fn readAll(arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFileAlloc(std.testing.io, name, arena, .limited(1 << 20));
}

fn tmpPath(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "trace wire log redacts keys, credential headers and bearer tokens in requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const path = try tmpPath(a, &tmp, "wire.ndjson");
    var log = try WireLog.open(std.testing.io, std.testing.allocator, path, &.{});
    defer log.close();
    log.begin("m1");
    const key = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWX";
    log.request(
        "anthropic",
        "https://u:p@api.example.com/v1/messages?token=zzz",
        &.{ .{ .name = "Authorization", .value = "Bearer " ++ key }, .{ .name = "x-api-key", .value = key }, .{ .name = "content-type", .value = "application/json" } },
        "{\"api_key\":\"" ++ key ++ "\",\"note\":\"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdefghijklmnop\"}",
        key,
    );
    const text = try readAll(a, tmp.dir, "wire.ndjson");
    try std.testing.expect(std.mem.indexOf(u8, text, "ABCDEFGHIJKLMNOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "eyJhbGci") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, redact_mod.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zzz") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "u:p@") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "content-type") != null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.trimEnd(u8, text, "\n"), .{});
    try std.testing.expectEqualStrings("request", v.object.get("kind").?.string);
    try std.testing.expectEqualStrings("anthropic", v.object.get("provider").?.string);
    try std.testing.expect(v.object.get("body").? == .object);
}

test "trace wire log redacts a github token in a streamed response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var log = try WireLog.open(std.testing.io, std.testing.allocator, try tmpPath(a, &tmp, "w.ndjson"), &.{});
    defer log.close();
    log.begin("m");
    var acc = Accumulator{ .arena = a };
    acc.add(.{ .content_delta = "your token is ghp_abcdefghijklmnopqrstuvwxyz0123456789 ok" });
    acc.add(.{ .usage = .{ .input_tokens = 5, .output_tokens = 7 } });
    log.response(&acc, "");
    const text = try readAll(a, tmp.dir, "w.ndjson");
    try std.testing.expect(std.mem.indexOf(u8, text, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, redact_mod.marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"input_tokens\":5") != null);
}

test "trace wire log leaves sk- inside ordinary words alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var log = try WireLog.open(std.testing.io, std.testing.allocator, try tmpPath(a, &tmp, "w.ndjson"), &.{});
    defer log.close();
    log.begin("m");
    log.request("openai", "https://h/x", &.{}, "{\"msg\":\"run the task-runner and the desk-lamp test\"}", "");
    const text = try readAll(a, tmp.dir, "w.ndjson");
    try std.testing.expect(std.mem.indexOf(u8, text, "task-runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, redact_mod.marker) == null);
}

test "trace wire log writes one well-formed line per event across rounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var log = try WireLog.open(std.testing.io, std.testing.allocator, try tmpPath(a, &tmp, "w.ndjson"), &.{});
    defer log.close();
    var acc = Accumulator{ .arena = a };
    acc.add(.{ .content_delta = "hi" });
    log.begin("m");
    log.request("openai", "https://h/x", &.{}, "{\"n\":1}", "");
    log.response(&acc, "");
    log.begin("m");
    log.request("openai", "https://h/x", &.{}, "{\"n\":2}", "");
    log.failure("boom Bearer abcdefghijklmnopqrstuvwxyz0123456789", "");
    const text = try readAll(a, tmp.dir, "w.ndjson");
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| : (lines += 1) {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        try std.testing.expect(v == .object);
        try std.testing.expect(v.object.get("round").?.integer >= 1);
    }
    try std.testing.expectEqual(@as(usize, 4), lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"round\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "abcdefghijklmnopqrstuvwxyz0123456789") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"error\"") != null);
}

test "trace wire log file is created 0600 even when it already exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old.ndjson", .data = "", .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o644) } });
    for ([_][]const u8{ "new.ndjson", "old.ndjson" }) |name| {
        var log = try WireLog.open(std.testing.io, std.testing.allocator, try tmpPath(a, &tmp, name), &.{});
        log.close();
        const st = try tmp.dir.statFile(std.testing.io, name, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    }
}

test "trace wire log write failure warns once and never fails the caller" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ro.ndjson", .data = "" });
    // Opened read-only: every write fails.
    const ro = try tmp.dir.openFile(std.testing.io, "ro.ndjson", .{ .mode = .read_only });
    var log = WireLog{ .io = std.testing.io, .gpa = std.testing.allocator, .file = ro, .offset = 0, .secrets = &.{} };
    defer log.close();
    log.begin("m");
    log.request("openai", "https://h/x", &.{}, "{}", "");
    try std.testing.expect(log.failed);
    log.failure("again", ""); // no-op after the first failure
    const text = try readAll(a, tmp.dir, "ro.ndjson");
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "trace wire log redacts exact secrets supplied by the host" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const secrets = [_][]const u8{"plainsecretvalue99"};
    var log = try WireLog.open(std.testing.io, std.testing.allocator, try tmpPath(a, &tmp, "w.ndjson"), &secrets);
    defer log.close();
    log.begin("m");
    log.request("openai", "https://h/x", &.{.{ .name = "x-custom", .value = "plainsecretvalue99" }}, "{\"a\":\"plainsecretvalue99\"}", "");
    const text = try readAll(a, tmp.dir, "w.ndjson");
    try std.testing.expect(std.mem.indexOf(u8, text, "plainsecretvalue99") == null);
}
