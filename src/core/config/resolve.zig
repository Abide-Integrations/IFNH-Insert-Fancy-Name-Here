//! Model resolution: aliases, role routing and fallback chains (DECISIONS
//! D44, D45, D49).
//!
//! `models.aliases.<name>` names a provider/model/parameters bundle;
//! `routing.<role>` selects one (or `"default"` for `model.*`), and
//! `models.fallbacks.<name>` lists aliases to try after retryable failures.
//! Everything here is pure: it reads a `config.Store` and allocates in the
//! caller's arena. `validateConfig` turns bad references into startup errors
//! naming the exact key.

const std = @import("std");
const config_mod = @import("config.zig");
const options_mod = @import("../../providers/options.zig");
const provider_mod = @import("../../providers/provider.zig");
const openai = @import("../../providers/openai.zig");
const anthropic = @import("../../providers/anthropic.zig");
const openai_responses = @import("../../providers/openai_responses.zig");

pub const roles = [_][]const u8{ "parent", "research", "implement", "review" };

/// Alias keys, before the per-provider option compile step.
/// Keys an alias may set (D44). Fallbacks live in `models.fallbacks` and a
/// profile prompt in `profiles.<name>.prompt`, not inside the alias.
const alias_keys = [_][]const u8{
    "model",       "provider",          "base_url",         "api_key_env",
    "temperature", "max_output_tokens", "provider_options",
};

pub const ResolvedModel = struct {
    provider: provider_mod.Provider,
    /// Adapter name: "openai", "openai-responses" or "anthropic" (options compile needs it).
    provider_name: []const u8,
    model: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    /// Compiled provider options as a JSON object ("" when none).
    provider_options: []const u8 = "",
    /// Alias this model came from ("default" for the configured base model).
    alias: []const u8 = "default",
    /// Fallback chain in try order (D49); empty means none.
    fallbacks: []const ResolvedModel = &.{},
};

pub const Error = error{ UnknownAlias, InvalidAlias, UnknownRole, Cycle };

pub fn providerFor(name: []const u8) ?provider_mod.Provider {
    if (std.mem.eql(u8, name, "openai")) return openai.instance;
    if (std.mem.eql(u8, name, "openai-responses")) return openai_responses.instance;
    if (std.mem.eql(u8, name, "anthropic")) return anthropic.instance;
    return null;
}

fn defaultBaseUrl(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "anthropic")) "https://api.anthropic.com" else "https://api.openai.com/v1";
}

fn defaultKeyEnv(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "anthropic")) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY";
}

fn inList(list: []const []const u8, key: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

fn objectItem(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const obj = v orelse return null;
    if (obj != .object) return null;
    return obj.object.get(key);
}

fn optionalString(v: ?std.json.Value, key: []const u8) ?[]const u8 {
    const item = objectItem(v, key) orelse return null;
    return switch (item) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn optionalNumber(v: ?std.json.Value, key: []const u8) ?f64 {
    const item = objectItem(v, key) orelse return null;
    return switch (item) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn optionalInt(v: ?std.json.Value, key: []const u8) ?u32 {
    const item = objectItem(v, key) orelse return null;
    return switch (item) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

fn aliasObject(store: *config_mod.Store, name: []const u8) ?std.json.Value {
    const aliases = store.get("models.aliases") orelse return null;
    if (aliases != .object) return null;
    const v = aliases.object.get(name) orelse return null;
    if (v != .object) return null;
    return v;
}

fn isKnownAlias(store: *config_mod.Store, name: []const u8) bool {
    if (std.mem.eql(u8, name, "default")) return true;
    return aliasObject(store, name) != null;
}

/// Resolve `name` (an alias, or "default" for `model.*`) to a concrete model
/// plus its fallback chain. Unknown or malformed aliases are errors.
pub fn resolveAlias(store: *config_mod.Store, arena: std.mem.Allocator, name: []const u8) !ResolvedModel {
    var model = try resolveShallow(store, arena, name);
    var chain: std.ArrayListUnmanaged(ResolvedModel) = .empty;
    try resolveChain(store, arena, &.{name}, &chain);
    model.fallbacks = chain.items;
    return model;
}

/// Resolve the model configured for `role` (`routing.<role>`, D45).
pub fn resolveRole(store: *config_mod.Store, arena: std.mem.Allocator, role: []const u8) !ResolvedModel {
    if (!inList(&roles, role)) return error.UnknownRole;
    const path = try std.fmt.allocPrint(arena, "routing.{s}", .{role});
    const alias = store.getOptionalString(path) orelse "default";
    return resolveAlias(store, arena, alias);
}

fn resolveShallow(store: *config_mod.Store, arena: std.mem.Allocator, name: []const u8) !ResolvedModel {
    const is_default = std.mem.eql(u8, name, "default");
    const alias: ?std.json.Value = if (is_default) null else aliasObject(store, name);
    if (!is_default and alias == null) return error.UnknownAlias;

    const base_provider = store.getString("model.provider", "openai");
    const provider_name = optionalString(alias, "provider") orelse base_provider;
    const provider = providerFor(provider_name) orelse return error.InvalidAlias;
    // Parameters (base_url, key, sampling) inherit from `model.*` only when
    // the alias talks to the same provider; a switch takes its defaults.
    const same = std.mem.eql(u8, provider_name, base_provider);
    const model: []const u8 = if (optionalString(alias, "model")) |m|
        m
    else if (is_default)
        store.getString("model.model", "")
    else
        return error.InvalidAlias;
    if (model.len == 0) return error.InvalidAlias;

    const base_url = optionalString(alias, "base_url") orelse blk: {
        if (same) {
            if (store.getOptionalString("model.base_url")) |url| break :blk url;
        }
        break :blk defaultBaseUrl(provider_name);
    };
    const api_key_env = optionalString(alias, "api_key_env") orelse blk: {
        if (same) {
            if (store.getOptionalString("model.api_key_env")) |env| break :blk env;
        }
        break :blk defaultKeyEnv(provider_name);
    };
    const temperature = optionalNumber(alias, "temperature") orelse
        (if (same) store.getOptionalF64("model.temperature") else null);
    const max_output_tokens = optionalInt(alias, "max_output_tokens") orelse
        (if (same) store.getOptionalU32("model.max_output_tokens") else null);

    const compiled = try mergeOptions(store, arena, alias, provider_name, model);
    for (compiled.warnings) |warning| try store.warn("{s}", .{warning});

    return .{
        .provider = provider,
        .provider_name = provider_name,
        .model = model,
        .base_url = base_url,
        .api_key_env = api_key_env,
        .temperature = temperature,
        .max_output_tokens = max_output_tokens,
        .provider_options = compiled.json,
        .alias = if (is_default) "default" else name,
    };
}

/// Per-key precedence (D05): `model.provider_options` <
/// `models.provider_options.<model id>` < the alias's own object.
fn mergeOptions(
    store: *config_mod.Store,
    arena: std.mem.Allocator,
    alias: ?std.json.Value,
    provider_name: []const u8,
    model: []const u8,
) !options_mod.Result {
    var merged = try std.json.ObjectMap.init(arena, &.{}, &.{});
    try overlay(arena, &merged, store.get("model.provider_options"));
    if (store.get("models.provider_options")) |bag| {
        if (bag == .object) try overlay(arena, &merged, bag.object.get(model));
    }
    try overlay(arena, &merged, objectItem(alias, "provider_options"));
    if (merged.count() == 0) return .{};

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(std.json.Value{ .object = merged }, .{}, &aw.writer);
    const compiled = try options_mod.compile(arena, provider_name, aw.written());
    // Dropped keys and bad types are config warnings; `Store.warn` dedupes,
    // so resolving the same model every turn reports each one once.
    for (compiled.warnings) |warning| try store.warn("{s}", .{warning});
    return compiled;
}

fn overlay(arena: std.mem.Allocator, dst: *std.json.ObjectMap, v: ?std.json.Value) !void {
    const src = v orelse return;
    if (src != .object) return;
    var it = src.object.iterator();
    while (it.next()) |entry| try dst.put(arena, entry.key_ptr.*, entry.value_ptr.*);
}

fn fallbackNames(store: *config_mod.Store, name: []const u8) []const []const u8 {
    const all = store.get("models.fallbacks") orelse return &.{};
    if (all != .object) return &.{};
    const v = all.object.get(name) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item == .string) out.append(store.alloc(), item.string) catch return out.items;
    }
    return out.items;
}

/// Flatten `name`'s fallback graph into try order. A repeated alias is a
/// cycle; a fallback that is already in the chain (diamond) is skipped.
fn resolveChain(
    store: *config_mod.Store,
    arena: std.mem.Allocator,
    path: []const []const u8,
    out: *std.ArrayListUnmanaged(ResolvedModel),
) !void {
    for (fallbackNames(store, path[path.len - 1])) |child| {
        if (inList(path, child)) return error.Cycle;
        if (!isKnownAlias(store, child)) return error.UnknownAlias;
        var seen = false;
        for (out.items) |resolved| {
            if (std.mem.eql(u8, resolved.alias, child)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        const resolved = try resolveShallow(store, arena, child);
        try out.append(arena, resolved);
        const next = try arena.alloc([]const u8, path.len + 1);
        @memcpy(next[0..path.len], path);
        next[path.len] = child;
        try resolveChain(store, arena, next, out);
    }
}

// ------------------------------------------------------------ validation

/// Check every alias, fallback and routing reference in `store`, adding
/// startup errors that name the offending key.
pub fn validateConfig(store: *config_mod.Store) !void {
    const arena = store.alloc();
    const aliases = store.get("models.aliases");
    if (aliases) |v| {
        if (v != .object) {
            try store.addError("models.aliases", "must be an object", .{});
        } else {
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const path = try std.fmt.allocPrint(arena, "models.aliases.{s}", .{entry.key_ptr.*});
                if (entry.value_ptr.* != .object) {
                    try store.addError(path, "must be an object", .{});
                    continue;
                }
                try validateAlias(store, path, entry.value_ptr.*);
            }
        }
    }
    try validateFallbacks(store);
    try validateRouting(store);
    try validateProfiles(store);
    // Resolve every reachable model once so provider-option warnings show up
    // at startup instead of on the first turn. Failures are already reported
    // above, so they are ignored here.
    _ = resolveAlias(store, arena, "default") catch {};
    if (aliases) |v| {
        if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |entry| _ = resolveAlias(store, arena, entry.key_ptr.*) catch {};
        }
    }
}

fn validateAlias(store: *config_mod.Store, path: []const u8, alias: std.json.Value) !void {
    const arena = store.alloc();
    if (objectItem(alias, "model")) |m| {
        if (m != .string or m.string.len == 0) {
            try store.addError(try std.fmt.allocPrint(arena, "{s}.model", .{path}), "must be a non-empty string", .{});
        }
    } else {
        try store.addError(path, "missing \"model\"", .{});
    }
    if (objectItem(alias, "provider")) |p| {
        if (p != .string or providerFor(p.string) == null) {
            try store.addError(try std.fmt.allocPrint(arena, "{s}.provider", .{path}), "must be \"openai\", \"anthropic\" or \"openai-responses\"", .{});
        }
    }
    const string_keys = [_][]const u8{ "base_url", "api_key_env" };
    for (string_keys) |key| {
        if (objectItem(alias, key)) |v| {
            if (v != .string and v != .null) {
                try store.addError(try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, key }), "must be a string or null", .{});
            }
        }
    }
    if (objectItem(alias, "temperature")) |v| {
        if (v != .integer and v != .float and v != .null) {
            try store.addError(try std.fmt.allocPrint(arena, "{s}.temperature", .{path}), "must be a number or null", .{});
        }
    }
    if (objectItem(alias, "max_output_tokens")) |v| {
        if ((v != .integer and v != .null) or (v == .integer and v.integer <= 0)) {
            try store.addError(try std.fmt.allocPrint(arena, "{s}.max_output_tokens", .{path}), "must be a positive integer or null", .{});
        }
    }
    if (objectItem(alias, "provider_options")) |v| {
        if (v != .object) {
            try store.addError(try std.fmt.allocPrint(arena, "{s}.provider_options", .{path}), "must be an object", .{});
        }
    }
    var it = alias.object.iterator();
    while (it.next()) |entry| {
        if (inList(&alias_keys, entry.key_ptr.*)) continue;
        try store.warn("unknown config key '{s}' ignored", .{try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, entry.key_ptr.* })});
    }
}

fn validateFallbacks(store: *config_mod.Store) !void {
    const arena = store.alloc();
    const fallbacks = store.get("models.fallbacks") orelse return;
    if (fallbacks != .object) {
        try store.addError("models.fallbacks", "must be an object", .{});
        return;
    }
    var it = fallbacks.object.iterator();
    while (it.next()) |entry| {
        const owner = entry.key_ptr.*;
        const path = try std.fmt.allocPrint(arena, "models.fallbacks.{s}", .{owner});
        if (!isKnownAlias(store, owner)) {
            try store.addError(path, "unknown alias '{s}'", .{owner});
            continue;
        }
        if (entry.value_ptr.* != .array) {
            try store.addError(path, "must be an array of alias names", .{});
            continue;
        }
        for (entry.value_ptr.*.array.items) |item| {
            if (item != .string) {
                try store.addError(path, "must be an array of alias names", .{});
                continue;
            }
            if (!isKnownAlias(store, item.string)) {
                try store.addError(path, "unknown alias '{s}'", .{item.string});
            }
        }
        try validateChain(store, owner, &.{owner});
    }
}

fn validateChain(store: *config_mod.Store, root: []const u8, path: []const []const u8) !void {
    const arena = store.alloc();
    if (path.len > 16) {
        try store.addError(try std.fmt.allocPrint(arena, "models.fallbacks.{s}", .{root}), "fallback chain is too deep", .{});
        return;
    }
    for (fallbackNames(store, path[path.len - 1])) |child| {
        if (inList(path, child)) {
            try store.addError(
                try std.fmt.allocPrint(arena, "models.fallbacks.{s}", .{root}),
                "fallback cycle at '{s}'",
                .{child},
            );
            continue;
        }
        if (!isKnownAlias(store, child)) continue; // reported by validateFallbacks
        const next = try arena.alloc([]const u8, path.len + 1);
        @memcpy(next[0..path.len], path);
        next[path.len] = child;
        try validateChain(store, root, next);
    }
}

fn validateRouting(store: *config_mod.Store) !void {
    const routing = store.get("routing") orelse return;
    if (routing != .object) {
        try store.addError("routing", "must be an object", .{});
        return;
    }
    const arena = store.alloc();
    var it = routing.object.iterator();
    while (it.next()) |entry| {
        const role = entry.key_ptr.*;
        if (!inList(&roles, role)) continue; // validateKeys warns about it
        const path = try std.fmt.allocPrint(arena, "routing.{s}", .{role});
        const v = entry.value_ptr.*;
        if (v != .string) {
            try store.addError(path, "must be an alias name or \"default\"", .{});
            continue;
        }
        if (!isKnownAlias(store, v.string)) {
            try store.addError(path, "unknown alias '{s}'", .{v.string});
        }
    }
}

fn validateProfiles(store: *config_mod.Store) !void {
    const profiles = store.get("profiles") orelse return;
    if (profiles != .object) {
        try store.addError("profiles", "must be an object", .{});
        return;
    }
    const arena = store.alloc();
    var it = profiles.object.iterator();
    while (it.next()) |entry| {
        const path = try std.fmt.allocPrint(arena, "profiles.{s}", .{entry.key_ptr.*});
        if (entry.value_ptr.* != .object) {
            try store.addError(path, "must be an object", .{});
            continue;
        }
        if (objectItem(entry.value_ptr.*, "prompt")) |p| {
            if (p != .string) try store.addError(try std.fmt.allocPrint(arena, "{s}.prompt", .{path}), "must be a string", .{});
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn storeWith(json: []const u8) !config_mod.Store {
    var store = try config_mod.Store.init(testing.allocator);
    errdefer store.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = "test" });
    return store;
}

test "default alias resolves to the base model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"provider":"openai","model":"gpt-base","base_url":"http://local/v1","api_key_env":"MY_KEY"}}
    );
    defer store.deinit();

    const m = try resolveAlias(&store, arena, "default");
    try testing.expectEqualStrings("default", m.alias);
    try testing.expectEqualStrings("gpt-base", m.model);
    try testing.expectEqualStrings("http://local/v1", m.base_url);
    try testing.expectEqualStrings("MY_KEY", m.api_key_env);
    try testing.expectEqualStrings("openai", m.provider_name);
    try testing.expect(m.fallbacks.len == 0);
}

test "alias inherits same-provider settings and overrides params" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"provider":"openai","model":"gpt-base","base_url":"http://local/v1","api_key_env":"MY_KEY"},
        \\ "models":{"aliases":{"fast":{"model":"gpt-mini","temperature":0.2,"max_output_tokens":512}}}}
    );
    defer store.deinit();

    const m = try resolveAlias(&store, arena, "fast");
    try testing.expectEqualStrings("fast", m.alias);
    try testing.expectEqualStrings("gpt-mini", m.model);
    try testing.expectEqualStrings("http://local/v1", m.base_url);
    try testing.expectEqualStrings("MY_KEY", m.api_key_env);
    try testing.expectEqual(@as(?f64, 0.2), m.temperature);
    try testing.expectEqual(@as(?u32, 512), m.max_output_tokens);
}

test "openai-responses resolves to its own adapter with the OpenAI defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"provider":"openai-responses","model":"gpt-5.1"},
        \\ "models":{"aliases":{"chat":{"provider":"openai","model":"gpt-4o"}}}}
    );
    defer store.deinit();

    const m = try resolveAlias(&store, arena, "default");
    try testing.expectEqualStrings("openai-responses", m.provider_name);
    try testing.expectEqualStrings("https://api.openai.com/v1", m.base_url);
    try testing.expectEqualStrings("OPENAI_API_KEY", m.api_key_env);
    try testing.expectEqual(@intFromPtr(openai_responses.instance.stream_fn), @intFromPtr(m.provider.stream_fn));
    try testing.expect(@intFromPtr(openai.instance.stream_fn) != @intFromPtr(m.provider.stream_fn));
    // An alias on the sibling adapter keeps the Chat Completions one.
    const chat = try resolveAlias(&store, arena, "chat");
    try testing.expectEqual(@intFromPtr(openai.instance.stream_fn), @intFromPtr(chat.provider.stream_fn));
}

test "switching provider in an alias drops the base url and key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"provider":"openai","model":"gpt-base","base_url":"http://local/v1","api_key_env":"MY_KEY"},
        \\ "models":{"aliases":{"claude":{"provider":"anthropic","model":"claude-x"}}}}
    );
    defer store.deinit();

    const m = try resolveAlias(&store, arena, "claude");
    try testing.expectEqualStrings("anthropic", m.provider_name);
    try testing.expectEqualStrings("https://api.anthropic.com", m.base_url);
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", m.api_key_env);
}

test "unknown and malformed aliases are errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"model":"gpt-base"},"models":{"aliases":{"broken":{"provider":"openai"},"bad-provider":{"model":"m","provider":"nope"}}}}
    );
    defer store.deinit();

    try testing.expectError(error.UnknownAlias, resolveAlias(&store, arena, "nope"));
    try testing.expectError(error.InvalidAlias, resolveAlias(&store, arena, "broken"));
    try testing.expectError(error.InvalidAlias, resolveAlias(&store, arena, "bad-provider"));
    try testing.expectError(error.UnknownRole, resolveRole(&store, arena, "researcher"));
}

test "routing selects the alias for a role" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"model":"gpt-base"},
        \\ "models":{"aliases":{"cheap":{"model":"gpt-mini"}}},
        \\ "routing":{"research":"cheap","parent":"default"}}
    );
    defer store.deinit();

    try testing.expectEqualStrings("cheap", (try resolveRole(&store, arena, "research")).alias);
    try testing.expectEqualStrings("default", (try resolveRole(&store, arena, "parent")).alias);
    // Unset roles use the base model.
    try testing.expectEqualStrings("gpt-base", (try resolveRole(&store, arena, "implement")).model);
}

test "fallback chain is pre-resolved and flattened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"model":"gpt-base"},
        \\ "models":{
        \\   "aliases":{"a":{"model":"ma"},"b":{"model":"mb"},"c":{"model":"mc"}},
        \\   "fallbacks":{"default":["a"],"a":["b"],"b":["c"]}}}
    );
    defer store.deinit();

    const m = try resolveAlias(&store, arena, "default");
    try testing.expectEqual(@as(usize, 3), m.fallbacks.len);
    try testing.expectEqualStrings("a", m.fallbacks[0].alias);
    try testing.expectEqualStrings("b", m.fallbacks[1].alias);
    try testing.expectEqualStrings("c", m.fallbacks[2].alias);
    try testing.expectEqualStrings("mb", m.fallbacks[1].model);
}

test "fallback cycles and unknown aliases are resolution errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cycle = try storeWith(
        \\{"model":{"model":"gpt-base"},
        \\ "models":{"aliases":{"a":{"model":"ma"},"b":{"model":"mb"}},"fallbacks":{"a":["b"],"b":["a"]}}}
    );
    defer cycle.deinit();
    try testing.expectError(error.Cycle, resolveAlias(&cycle, arena, "a"));

    var self_ref = try storeWith(
        \\{"model":{"model":"gpt-base"},"models":{"aliases":{"a":{"model":"ma"}},"fallbacks":{"a":["a"]}}}
    );
    defer self_ref.deinit();
    try testing.expectError(error.Cycle, resolveAlias(&self_ref, arena, "a"));

    var unknown = try storeWith(
        \\{"model":{"model":"gpt-base"},"models":{"aliases":{"a":{"model":"ma"}},"fallbacks":{"a":["ghost"]}}}
    );
    defer unknown.deinit();
    try testing.expectError(error.UnknownAlias, resolveAlias(&unknown, arena, "a"));
}

test "provider_options precedence: alias > per-model > model-wide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try storeWith(
        \\{"model":{"model":"gpt-base","provider_options":{"reasoning_effort":"low","reasoning":{"effort":"low"}}},
        \\ "models":{
        \\   "aliases":{"fast":{"model":"gpt-mini","provider_options":{"reasoning_effort":"high"}}},
        \\   "provider_options":{"gpt-mini":{"reasoning_effort":"medium"}}}}
    );
    defer store.deinit();

    // Alias wins over the per-model bag and the model-wide object.
    const fast = try resolveAlias(&store, arena, "fast");
    try testing.expectEqualStrings("{\"reasoning_effort\":\"high\",\"reasoning\":{\"effort\":\"low\"}}", fast.provider_options);

    // Without an alias object the per-model bag wins for that model id.
    var bag_store = try storeWith(
        \\{"model":{"model":"gpt-base","provider_options":{"reasoning_effort":"low"}},
        \\ "models":{"provider_options":{"gpt-base":{"reasoning_effort":"medium"}}}}
    );
    defer bag_store.deinit();
    const base = try resolveAlias(&bag_store, arena, "default");
    try testing.expectEqualStrings("{\"reasoning_effort\":\"medium\"}", base.provider_options);
}

test "validation reports unknown routing aliases and bad alias entries" {
    var store = try storeWith(
        \\{"routing":{"research":"ghost","review":7},
        \\ "models":{"aliases":{"broken":{"provider":"openai"},"nope":{"model":"m","provider":"x"}},
        \\           "fallbacks":{"ghost":["m"]}},
        \\ "profiles":{"quick":7}}
    );
    defer store.deinit();
    try validateConfig(&store);

    var saw_routing = false;
    var saw_routing_type = false;
    var saw_missing_model = false;
    var saw_bad_provider = false;
    var saw_fallback_owner = false;
    var saw_profile = false;
    for (store.errors.items) |e| {
        if (std.mem.eql(u8, e.path, "routing.research")) saw_routing = true;
        if (std.mem.eql(u8, e.path, "routing.review")) saw_routing_type = true;
        if (std.mem.eql(u8, e.path, "models.aliases.broken")) saw_missing_model = true;
        if (std.mem.eql(u8, e.path, "models.aliases.nope.provider")) saw_bad_provider = true;
        if (std.mem.eql(u8, e.path, "models.fallbacks.ghost")) saw_fallback_owner = true;
        if (std.mem.eql(u8, e.path, "profiles.quick")) saw_profile = true;
    }
    try testing.expect(saw_routing and saw_routing_type and saw_missing_model);
    try testing.expect(saw_bad_provider and saw_fallback_owner and saw_profile);
}

test "validation flags fallback cycles without failing resolution of a valid alias" {
    var store = try storeWith(
        \\{"model":{"model":"gpt-base"},
        \\ "models":{"aliases":{"a":{"model":"ma"}},"fallbacks":{"a":["a"]}}}
    );
    defer store.deinit();
    try validateConfig(&store);
    try testing.expect(store.errors.items.len == 1);
    try testing.expectEqualStrings("models.fallbacks.a", store.errors.items[0].path);
    try testing.expect(std.mem.indexOf(u8, store.errors.items[0].message, "cycle") != null);
}
