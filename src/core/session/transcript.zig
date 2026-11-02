//! Session export and offline replay (D-09).
//!
//! `exportText` turns a session's raw `events.jsonl` into redacted NDJSON,
//! one stored record per line in the original order. `replay` reads that
//! NDJSON back with no provider and no config: a readable transcript, or
//! (`json`) the records re-emitted unchanged. Both are pure over bytes.

const std = @import("std");
const store = @import("store.zig");
const redact = @import("../redact.zig");

pub const ReplayError = error{Malformed} || std.mem.Allocator.Error;

/// Tool output longer than this many lines is cut in the transcript.
pub const max_output_lines: usize = 20;

pub const Resolved = union(enum) {
    ok: []const u8,
    unknown,
    ambiguous,
};

/// Resolve a full id or unique prefix (`s_` optional) against known ids.
pub fn resolveId(ids: []const []const u8, query: []const u8) Resolved {
    const bare = if (std.mem.startsWith(u8, query, "s_")) query[2..] else query;
    var found: ?[]const u8 = null;
    for (ids) |id| {
        const id_bare = if (std.mem.startsWith(u8, id, "s_")) id[2..] else id;
        if (std.mem.eql(u8, id_bare, bare)) return .{ .ok = id };
        if (bare.len > 0 and std.mem.startsWith(u8, id_bare, bare)) {
            if (found != null) return .ambiguous;
            found = id;
        }
    }
    return if (found) |id| .{ .ok = id } else .unknown;
}

/// Redacted NDJSON of the complete lines in `raw` (a torn tail is dropped,
/// as the store does). Redaction runs on the serialized line: credential
/// tokens contain no JSON escapes, so the line stays valid JSON.
pub fn exportText(arena: std.mem.Allocator, raw: []const u8, secrets: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = raw;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (line.len == 0) continue;
        try out.appendSlice(arena, redact.redact(arena, line, secrets));
        try out.append(arena, '\n');
    }
    return out.items;
}

/// Parse every non-empty line as a stored record; all-or-nothing.
fn parseAll(arena: std.mem.Allocator, input: []const u8, bad_line: *usize) ReplayError![]store.Record {
    var records: std.ArrayList(store.Record) = .empty;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        n += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        const rec = store.Session.parseRecord(arena, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                bad_line.* = n;
                return error.Malformed;
            },
        };
        try records.append(arena, rec);
    }
    return records.items;
}

/// Render `input` into `w`. On `error.Malformed` nothing was written and
/// `bad_line` holds the 1-based line number.
pub fn replay(arena: std.mem.Allocator, input: []const u8, json: bool, w: *std.Io.Writer, bad_line: *usize) (ReplayError || std.Io.Writer.Error)!void {
    const records = try parseAll(arena, input, bad_line);
    if (json) {
        // Byte-for-byte: only blank lines and the final newline are normalised.
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |line| {
            const l = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.trim(u8, l, " \t").len == 0) continue;
            try w.writeAll(l);
            try w.writeByte('\n');
        }
        return;
    }
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (records) |rec| switch (rec.event) {
        .user => |v| try block(w, "user:", v.text),
        .assistant => |v| try block(w, "assistant:", v.text),
        .tool_call => |v| {
            try names.put(arena, v.id, v.name);
            try w.print("tool {s}: call\n", .{v.name});
            try indented(w, v.arguments_json, 4);
        },
        .tool_result => |v| {
            try w.print("tool {s}: {s}\n", .{ names.get(v.call_id) orelse v.call_id, v.status });
            try indented(w, v.output, max_output_lines);
        },
        .note => |v| try block(w, "note:", v.text),
        .interrupted => try w.writeAll("(interrupted)\n"),
    };
}

fn block(w: *std.Io.Writer, label: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}\n", .{label});
    try indented(w, text, std.math.maxInt(usize));
}

/// Print `text` indented, at most `max_lines` lines, then `... (n more lines)`.
fn indented(w: *std.Io.Writer, text: []const u8, max_lines: usize) std.Io.Writer.Error!void {
    const body = std.mem.trimEnd(u8, text, "\n");
    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (shown == max_lines) {
            var more: usize = 1;
            while (it.next()) |_| more += 1;
            try w.print("  ... ({d} more lines)\n", .{more});
            return;
        }
        try w.print("  {s}\n", .{line});
        shown += 1;
    }
}

// ---------------------------------------------------------------- tests

const sample =
    "{\"seq\":1,\"ts_ms\":10,\"event\":{\"kind\":\"user\",\"text\":\"list files\"}}\n" ++
    "{\"seq\":2,\"ts_ms\":11,\"event\":{\"kind\":\"tool_call\",\"id\":\"c1\",\"name\":\"bash\",\"arguments_json\":\"{\\\"command\\\":\\\"ls\\\"}\"}}\n" ++
    "{\"seq\":3,\"ts_ms\":12,\"event\":{\"kind\":\"tool_result\",\"call_id\":\"c1\",\"status\":\"ok\",\"output\":\"a\\nb\"}}\n" ++
    "{\"seq\":4,\"ts_ms\":13,\"event\":{\"kind\":\"assistant\",\"text\":\"two files\"}}\n";

fn render(arena: std.mem.Allocator, input: []const u8, json: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var bad: usize = 0;
    try replay(arena, input, json, &aw.writer, &bad);
    return aw.written();
}

test "export then replay round trips a four-record session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const exported = try exportText(a, sample, &.{});
    try std.testing.expectEqualStrings(sample, exported);
    const text = try render(a, exported, false);
    try std.testing.expectEqualStrings(
        "user:\n  list files\ntool bash: call\n  {\"command\":\"ls\"}\ntool bash: ok\n  a\n  b\nassistant:\n  two files\n",
        text,
    );
}

test "export redacts an api key in stored records" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "{\"seq\":1,\"ts_ms\":1,\"event\":{\"kind\":\"user\",\"text\":\"my key is sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV ok\"}}\n";
    const exported = try exportText(a, raw, &.{});
    try std.testing.expect(std.mem.indexOf(u8, exported, "ABCDEFGH") == null);
    try std.testing.expect(std.mem.indexOf(u8, exported, redact.marker) != null);
    _ = try render(a, exported, false); // still valid records
}

test "replay json is line-identical to the input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(sample, try render(a, sample, true));
    // A missing final newline and blank lines are the only normalisation.
    const loose = try render(a, "\n" ++ sample[0 .. sample.len - 1], true);
    try std.testing.expectEqualStrings(sample, loose);
}

test "replay truncates long tool output with a line count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.ArrayList(u8) = .empty;
    for (0..25) |i| try lines.print(a, "l{d}\\n", .{i});
    const raw = try std.fmt.allocPrint(a, "{{\"seq\":1,\"ts_ms\":1,\"event\":{{\"kind\":\"tool_result\",\"call_id\":\"x\",\"status\":\"ok\",\"output\":\"{s}\"}}}}\n", .{lines.items});
    const text = try render(a, raw, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "  l19\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "l20") == null);
    try std.testing.expect(std.mem.endsWith(u8, text, "  ... (5 more lines)\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "tool x: ok") != null);
}

test "replay malformed input is rejected before any output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    var bad: usize = 0;
    const input = sample ++ "{not json\n";
    try std.testing.expectError(error.Malformed, replay(a, input, false, &aw.writer, &bad));
    try std.testing.expectEqual(@as(usize, 5), bad);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
    try std.testing.expectError(error.Malformed, replay(a, "{\"seq\":1}\n", true, &aw.writer, &bad));
}

test "export resolves ids: unknown and ambiguous are reported" {
    const ids = [_][]const u8{ "s_abcdef123456", "s_abcxyz123456", "s_zzzzzz123456" };
    try std.testing.expectEqualStrings("s_zzzzzz123456", resolveId(&ids, "zzz").ok);
    try std.testing.expectEqualStrings("s_abcdef123456", resolveId(&ids, "s_abcdef123456").ok);
    try std.testing.expect(resolveId(&ids, "abc") == .ambiguous);
    try std.testing.expect(resolveId(&ids, "nope") == .unknown);
    try std.testing.expect(resolveId(&ids, "") == .unknown);
}

test "export drops a torn final line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try exportText(a, sample ++ "{\"seq\":5,\"ts_ms", &.{});
    try std.testing.expectEqualStrings(sample, out);
}
