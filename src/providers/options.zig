//! Provider-specific request options (DECISIONS D41, D05).
//!
//! `model.provider_options`, `models.provider_options.<model>` and an alias's
//! own `provider_options` merge into one JSON object; `compile` keeps only the
//! keys the adapter actually implements, drops the rest with a warning, and
//! serializes the result. The adapters splice that object into the request
//! body, so an option the wire format does not know can never be sent.

const std = @import("std");

pub const Result = struct {
    /// Compact JSON object text; "" when the request carries no options.
    json: []const u8 = "",
    /// Human-readable warnings for dropped keys (surfaced as config warnings).
    warnings: []const []const u8 = &.{},
};

pub const openai_reasoning_efforts = [_][]const u8{ "minimal", "low", "medium", "high" };

/// Keep the options `provider` implements from `raw_json` (a JSON object).
/// Keys are serialized in input order, so the request body is deterministic.
pub fn compile(arena: std.mem.Allocator, provider: []const u8, raw_json: []const u8) !Result {
    const trimmed = std.mem.trim(u8, raw_json, " \t\r\n");
    if (trimmed.len == 0) return .{};

    var warnings: std.ArrayListUnmanaged([]const u8) = .empty;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch {
        try warnf(arena, &warnings, "provider_options: not valid JSON; ignored", .{});
        return .{ .warnings = warnings.items };
    };
    if (value != .object) {
        try warnf(arena, &warnings, "provider_options: must be a JSON object; ignored", .{});
        return .{ .warnings = warnings.items };
    }

    var kept = try std.json.ObjectMap.init(arena, &.{}, &.{});
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (isOpenAiFamily(provider) and try openaiOption(arena, &warnings, key, v)) {
            try kept.put(arena, key, v);
        } else if (std.mem.eql(u8, provider, "anthropic") and try anthropicOption(arena, &warnings, key, v)) {
            try kept.put(arena, key, v);
        } else if (!isKnown(key, provider)) {
            try warnf(arena, &warnings, "provider_options: unknown key '{s}' for {s}; ignored", .{ key, provider });
        }
    }

    if (kept.count() == 0) return .{ .warnings = warnings.items };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(std.json.Value{ .object = kept }, .{}, &aw.writer);
    return .{ .json = aw.written(), .warnings = warnings.items };
}

/// Append the members of a compiled options object to a request body that is
/// already open, each prefixed with `,`. Options text that is not an object
/// (never produced by `compile`) adds nothing.
pub fn splice(w: *std.Io.Writer, json: []const u8) !void {
    const text = std.mem.trim(u8, json, " \t\r\n");
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return;
    const members = std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
    if (members.len == 0) return;
    try w.writeByte(',');
    try w.writeAll(members);
}

/// Chat Completions and Responses share the same option keys.
fn isOpenAiFamily(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "openai-responses");
}

fn isKnown(key: []const u8, provider: []const u8) bool {
    if (isOpenAiFamily(provider)) {
        return std.mem.eql(u8, key, "reasoning_effort") or std.mem.eql(u8, key, "reasoning");
    }
    if (std.mem.eql(u8, provider, "anthropic")) {
        return std.mem.eql(u8, key, "thinking") or std.mem.eql(u8, key, "top_k");
    }
    return false;
}

/// True when the key belongs to the provider and the value type is right.
fn openaiOption(
    arena: std.mem.Allocator,
    warnings: *std.ArrayListUnmanaged([]const u8),
    key: []const u8,
    v: std.json.Value,
) !bool {
    if (std.mem.eql(u8, key, "reasoning_effort")) {
        if (v != .string) {
            try warnf(arena, warnings, "provider_options: reasoning_effort must be a string; ignored", .{});
            return false;
        }
        for (openai_reasoning_efforts) |effort| {
            if (std.mem.eql(u8, v.string, effort)) return true;
        }
        try warnf(arena, warnings, "provider_options: reasoning_effort must be one of minimal|low|medium|high; ignored", .{});
        return false;
    }
    if (std.mem.eql(u8, key, "reasoning")) {
        if (v != .object) {
            try warnf(arena, warnings, "provider_options: reasoning must be an object; ignored", .{});
            return false;
        }
        return true;
    }
    return false;
}

fn anthropicOption(
    arena: std.mem.Allocator,
    warnings: *std.ArrayListUnmanaged([]const u8),
    key: []const u8,
    v: std.json.Value,
) !bool {
    if (std.mem.eql(u8, key, "thinking")) {
        if (v != .object) {
            try warnf(arena, warnings, "provider_options: thinking must be an object; ignored", .{});
            return false;
        }
        return true;
    }
    if (std.mem.eql(u8, key, "top_k")) {
        if (v != .integer) {
            try warnf(arena, warnings, "provider_options: top_k must be an integer; ignored", .{});
            return false;
        }
        return true;
    }
    return false;
}

fn warnf(
    arena: std.mem.Allocator,
    warnings: *std.ArrayListUnmanaged([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    try warnings.append(arena, msg);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn compileFor(arena: std.mem.Allocator, provider: []const u8, raw: []const u8) !Result {
    return compile(arena, provider, raw);
}

test "provider_options: openai keeps reasoning_effort and reasoning, drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try compileFor(arena, "openai",
        \\{"reasoning_effort":"high","reasoning":{"effort":"low"},"thinking":{"type":"enabled"},"temperature":0.2}
    );
    try testing.expectEqualStrings("{\"reasoning_effort\":\"high\",\"reasoning\":{\"effort\":\"low\"}}", res.json);
    try testing.expectEqual(@as(usize, 2), res.warnings.len);
    try testing.expect(std.mem.indexOf(u8, res.warnings[0], "thinking") != null);
    try testing.expect(std.mem.indexOf(u8, res.warnings[1], "temperature") != null);
}

test "provider_options: openai-responses implements the same keys as openai" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try compileFor(arena_state.allocator(), "openai-responses",
        \\{"reasoning_effort":"low","reasoning":{"summary":"auto"},"thinking":{"type":"enabled"}}
    );
    try testing.expectEqualStrings("{\"reasoning_effort\":\"low\",\"reasoning\":{\"summary\":\"auto\"}}", res.json);
    try testing.expectEqual(@as(usize, 1), res.warnings.len);
}

test "provider_options: anthropic keeps thinking and top_k only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try compileFor(arena, "anthropic",
        \\{"thinking":{"type":"enabled","budget_tokens":2048},"top_k":5,"reasoning_effort":"high"}
    );
    try testing.expectEqualStrings("{\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048},\"top_k\":5}", res.json);
    try testing.expectEqual(@as(usize, 1), res.warnings.len);
    try testing.expect(std.mem.indexOf(u8, res.warnings[0], "reasoning_effort") != null);
}

test "provider_options: wrong value types are dropped with a warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try compileFor(arena, "openai", "{\"reasoning_effort\":\"extreme\"}");
    try testing.expectEqualStrings("", res.json);
    try testing.expectEqual(@as(usize, 1), res.warnings.len);

    const res2 = try compileFor(arena, "anthropic", "{\"top_k\":\"five\"}");
    try testing.expectEqualStrings("", res2.json);
    try testing.expectEqual(@as(usize, 1), res2.warnings.len);
}

test "provider_options: empty, non-object and invalid input compile to nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("", (try compileFor(arena, "openai", "")).json);
    try testing.expectEqualStrings("", (try compileFor(arena, "openai", " {} ")).json);
    const array = try compileFor(arena, "openai", "[1,2]");
    try testing.expectEqualStrings("", array.json);
    try testing.expectEqual(@as(usize, 1), array.warnings.len);
    const bad = try compileFor(arena, "openai", "{");
    try testing.expectEqualStrings("", bad.json);
    try testing.expectEqual(@as(usize, 1), bad.warnings.len);
}

test "provider_options: a fully filtered object compiles to empty text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Nothing kept -> "" so the adapter adds no bytes to the body.
    const res = try compileFor(arena, "anthropic", "{\"reasoning_effort\":\"high\"}");
    try testing.expectEqualStrings("", res.json);
}
