//! Machine-readable configuration schema (D-06).
//!
//! The schema document is `docs/config.schema.json`, published verbatim;
//! this module embeds that same file so the binary and the docs cannot
//! drift apart (`ifnh config schema` prints `json_schema`). The tests at the
//! bottom walk the builtin defaults and fail when a key is missing from the
//! schema, and vice versa.

const std = @import("std");
const config_mod = @import("config.zig");

pub const json_schema = @embedFile("config_schema");

/// Resolve a dotted path inside a parsed schema document.
fn nodeAt(root: std.json.Value, dotted_path: []const u8) ?std.json.Value {
    var current = root;
    var it = std.mem.splitScalar(u8, dotted_path, '.');
    while (it.next()) |key| {
        if (current != .object) return null;
        const props = current.object.get("properties") orelse return null;
        if (props != .object) return null;
        current = props.object.get(key) orelse return null;
    }
    return current;
}

/// Dotted path of every leaf in a defaults object.
fn expectEveryDefaultHasProperty(
    arena: std.mem.Allocator,
    defaults: std.json.Value,
    schema: std.json.Value,
    prefix: []const u8,
    missing: *usize,
) !void {
    if (defaults != .object) return;
    const props = schema.object.get("properties") orelse {
        if (defaults.object.count() == 0) return;
        std.debug.print("schema node '{s}' has no properties\n", .{prefix});
        missing.* += 1;
        return;
    };
    var it = defaults.object.iterator();
    while (it.next()) |entry| {
        const path = if (prefix.len == 0)
            entry.key_ptr.*
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        const child = props.object.get(entry.key_ptr.*) orelse {
            std.debug.print("schema is missing default key '{s}'\n", .{path});
            missing.* += 1;
            continue;
        };
        try expectEveryDefaultHasProperty(arena, entry.value_ptr.*, child, path, missing);
    }
}

fn defaultHasPath(defaults: std.json.Value, dotted_path: []const u8) bool {
    var current = defaults;
    var it = std.mem.splitScalar(u8, dotted_path, '.');
    while (it.next()) |key| {
        if (current != .object) return false;
        current = current.object.get(key) orelse return false;
    }
    return true;
}

fn isDocumentedExtra(path: []const u8) bool {
    for (config_mod.extra_top_level_keys) |key| {
        if (std.mem.eql(u8, path, key)) return true;
    }
    for (config_mod.extra_section_keys) |key| {
        if (std.mem.eql(u8, path, key)) return true;
    }
    return false;
}

fn expectEveryPropertyHasDefault(
    arena: std.mem.Allocator,
    schema: std.json.Value,
    defaults: std.json.Value,
    prefix: []const u8,
    missing: *usize,
) !void {
    const props = schema.object.get("properties") orelse return;
    if (props != .object) return;
    var it = props.object.iterator();
    while (it.next()) |entry| {
        const path = if (prefix.len == 0)
            entry.key_ptr.*
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        if (!defaultHasPath(defaults, path) and !isDocumentedExtra(path)) {
            std.debug.print("schema documents '{s}' but the defaults do not define it\n", .{path});
            missing.* += 1;
            continue;
        }
        try expectEveryPropertyHasDefault(arena, entry.value_ptr.*, defaults, path, missing);
    }
}

test "config schema embeds the published document verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json_schema, .{});
    try std.testing.expect(schema == .object);
    try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
    try std.testing.expect(schema.object.get("properties") != null);
}

test "config schema matches the builtin defaults in both directions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_schema, .{});
    const defaults = try std.json.parseFromSliceLeaky(std.json.Value, arena, config_mod.default_config_json, .{});

    var missing_schema: usize = 0;
    try expectEveryDefaultHasProperty(arena, defaults, schema, "", &missing_schema);
    try std.testing.expectEqual(@as(usize, 0), missing_schema);

    var missing_default: usize = 0;
    try expectEveryPropertyHasDefault(arena, schema, defaults, "", &missing_default);
    try std.testing.expectEqual(@as(usize, 0), missing_default);
}

test "config schema allows only the modes validation allows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json_schema, .{});
    const mode = nodeAt(schema, "permissions.default_mode").?;
    const allowed = mode.object.get("enum").?.array;
    var saw_ask = false;
    var saw_auto = false;
    for (allowed.items) |item| {
        if (std.mem.eql(u8, item.string, "ask")) saw_ask = true;
        if (std.mem.eql(u8, item.string, "auto")) saw_auto = true;
    }
    try std.testing.expect(saw_ask and saw_auto);
    try std.testing.expectEqual(@as(usize, 2), allowed.items.len);
}
