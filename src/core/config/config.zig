//! Layered JSON configuration (DESIGN §3.5, DECISIONS section B).
//!
//! Precedence (low to high): builtin defaults < user < project < session < env < cli.
//! Every leaf key records which layer supplied it (`ifnh config explain`).
//! Security-relevant sections fail closed: malformed permission data is a
//! hard startup error, never silently ignored.

const std = @import("std");
const builtin = @import("builtin");

pub const Layer = enum {
    builtin,
    user,
    project,
    session,
    env,
    cli,

    pub fn name(self: Layer) []const u8 {
        return switch (self) {
            .builtin => "builtin",
            .user => "user",
            .project => "project",
            .session => "session",
            .env => "env",
            .cli => "cli",
        };
    }
};

pub const Source = struct {
    layer: Layer,
    /// File path, "env:VAR", "session", or "cli".
    origin: []const u8,
};

pub const ValidationError = struct {
    path: []const u8,
    message: []const u8,
};

/// Documented default configuration: the zero-config experience (D048).
pub const default_config_json =
    \\{
    \\  "schema_version": 1,
    \\  "model": {
    \\    "provider": "openai",
    \\    "model": "",
    \\    "base_url": null,
    \\    "api_key_env": "OPENAI_API_KEY",
    \\    "temperature": null,
    \\    "max_output_tokens": null
    \\  },
    \\  "permissions": {
    \\    "default_mode": "ask",
    \\    "read": ["**"],
    \\    "write": [],
    \\    "command_allow": [],
    \\    "command_deny": [],
    \\    "env_allow": [],
    \\    "read_dotenv": false
    \\  },
    \\  "git": {
    \\    "commits": "ask",
    \\    "push": "never",
    \\    "force_push": "never"
    \\  },
    \\  "agents": {
    \\    "max_depth": 1,
    \\    "max_concurrent": 4,
    \\    "timeout_tool_s": 120,
    \\    "timeout_turn_s": 600
    \\  },
    \\  "context": {
    \\    "auto_compact": true,
    \\    "compact_at_fraction": 0.8,
    \\    "max_file_read_bytes": 262144
    \\  },
    \\  "planning": {
    \\    "auto_call_threshold": 12
    \\  },
    \\  "sessions": {
    \\    "dir": "project",
    \\    "keep": 30
    \\  },
    \\  "ui": {
    \\    "colors": true,
    \\    "symbols": "unicode",
    \\    "verbosity": "normal"
    \\  },
    \\  "debug": {
    \\    "level": "info",
    \\    "redact": true
    \\  }
    \\}
;

/// Top-level sections recognized by the schema. Unknown keys produce
/// warnings (DECISIONS B19); unknown values in security sections are errors.
pub const known_sections = [_][]const u8{
    "schema_version", "model",    "permissions", "git", "agents",
    "context",        "planning", "sessions",    "ui",  "debug",
};

pub const Store = struct {
    arena_state: std.heap.ArenaAllocator,
    /// Merged configuration tree (owned by arena).
    value: std.json.Value,
    /// Dotted key path -> winning source.
    sources: std.StringHashMapUnmanaged(Source) = .empty,
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,
    errors: std.ArrayListUnmanaged(ValidationError) = .empty,

    pub fn alloc(self: *Store) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn init(parent_alloc: std.mem.Allocator) !Store {
        var arena_state = std.heap.ArenaAllocator.init(parent_alloc);
        errdefer arena_state.deinit();

        // Construct the Store first; every allocation below must go through
        // self.alloc() so the arena state lives in the returned struct.
        // (Allocating through a pre-copy captured allocator orphans nodes.)
        var store = Store{ .arena_state = arena_state, .value = .null };
        store.value = .{ .object = try std.json.ObjectMap.init(store.alloc(), &.{}, &.{}) };
        const defaults = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), default_config_json, .{});
        try store.mergeValue(defaults, .{ .layer = .builtin, .origin = "defaults" });
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.arena_state.deinit();
    }

    /// Deep-merge `src` into the tree, recording `source` for every leaf.
    /// Objects merge recursively; arrays and scalars replace wholesale.
    pub fn mergeValue(self: *Store, src: std.json.Value, source: Source) !void {
        const arena = self.alloc();
        if (self.value != .object or src != .object) {
            // Non-object top level: replace.
            self.value = try cloneValue(arena, src);
            return;
        }
        self.value = try mergeObjects(arena, self.value, src);
        try self.recordSources(src, source, "");
    }

    fn recordSources(self: *Store, src: std.json.Value, source: Source, prefix: []const u8) !void {
        const arena = self.alloc();
        switch (src) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const child_path = if (prefix.len == 0)
                        try arena.dupe(u8, entry.key_ptr.*)
                    else
                        try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key_ptr.* });
                    switch (entry.value_ptr.*) {
                        .object => try self.recordSources(entry.value_ptr.*, source, child_path),
                        else => try self.sources.put(arena, child_path, source),
                    }
                }
            },
            else => {
                if (prefix.len > 0) try self.sources.put(arena, prefix, source);
            },
        }
    }

    /// Runtime override (session `set` or CLI flag).
    pub fn applyOverride(self: *Store, dotted_path: []const u8, json_text: []const u8, source: Source) !void {
        const arena = self.alloc();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch
            return error.InvalidOverrideValue;
        try self.setPath(dotted_path, v);
        try self.sources.put(arena, try arena.dupe(u8, dotted_path), source);
    }

    pub fn setPath(self: *Store, dotted_path: []const u8, v: std.json.Value) !void {
        const arena = self.alloc();
        if (self.value != .object) {
            self.value = .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
        }
        var obj_ptr: *std.json.ObjectMap = &self.value.object;
        var it = std.mem.splitScalar(u8, dotted_path, '.');
        var key = it.next() orelse return error.InvalidOverrideValue;
        while (it.next()) |next_key| {
            const existing = obj_ptr.getPtr(key) orelse blk: {
                try obj_ptr.put(arena, try arena.dupe(u8, key), .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) });
                break :blk obj_ptr.getPtr(key).?;
            };
            if (existing.* != .object) existing.* = .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
            obj_ptr = &existing.object;
            key = next_key;
        }
        try obj_ptr.put(arena, try arena.dupe(u8, key), try cloneValue(arena, v));
    }

    /// Look up a value by dotted path.
    pub fn get(self: *const Store, dotted_path: []const u8) ?std.json.Value {
        var current = self.value;
        var it = std.mem.splitScalar(u8, dotted_path, '.');
        while (it.next()) |key| {
            if (current != .object) return null;
            current = current.object.get(key) orelse return null;
        }
        return current;
    }

    pub fn getSource(self: *const Store, dotted_path: []const u8) ?Source {
        return self.sources.get(dotted_path);
    }

    // ---- typed accessors ----

    pub fn getString(self: *const Store, path: []const u8, default: []const u8) []const u8 {
        const v = self.get(path) orelse return default;
        return switch (v) {
            .string => |s| s,
            else => default,
        };
    }

    pub fn getOptionalString(self: *const Store, path: []const u8) ?[]const u8 {
        const v = self.get(path) orelse return null;
        return switch (v) {
            .string => |s| s,
            .null => null,
            else => null,
        };
    }

    pub fn getBool(self: *const Store, path: []const u8, default: bool) bool {
        const v = self.get(path) orelse return default;
        return switch (v) {
            .bool => |b| b,
            else => default,
        };
    }

    pub fn getU32(self: *const Store, path: []const u8, default: u32) u32 {
        const v = self.get(path) orelse return default;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else default,
            .float => |f| if (f >= 0 and f <= std.math.maxInt(u32)) @intFromFloat(f) else default,
            else => default,
        };
    }

    pub fn getOptionalU32(self: *const Store, path: []const u8) ?u32 {
        const v = self.get(path) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            .float => |f| if (f >= 0 and f <= std.math.maxInt(u32)) @intFromFloat(f) else null,
            else => null,
        };
    }

    pub fn getF64(self: *const Store, path: []const u8, default: f64) f64 {
        const v = self.get(path) orelse return default;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => default,
        };
    }

    pub fn getOptionalF64(self: *const Store, path: []const u8) ?f64 {
        const v = self.get(path) orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }

    pub fn getStringList(self: *Store, path: []const u8) []const []const u8 {
        const v = self.get(path) orelse return &.{};
        switch (v) {
            .array => |arr| {
                var out: std.ArrayListUnmanaged([]const u8) = .empty;
                for (arr.items) |item| {
                    if (item == .string) out.append(self.alloc(), item.string) catch return &.{};
                }
                return out.items;
            },
            else => return &.{},
        }
    }

    /// Append a warning (bounded).
    pub fn warn(self: *Store, comptime fmt: []const u8, args: anytype) !void {
        if (self.warnings.items.len >= 64) return;
        const msg = try std.fmt.allocPrint(self.alloc(), fmt, args);
        try self.warnings.append(self.alloc(), msg);
    }

    pub fn addError(self: *Store, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.alloc(), fmt, args);
        try self.errors.append(self.alloc(), .{ .path = try self.alloc().dupe(u8, path), .message = msg });
    }

    /// Structural validation (DECISIONS B19/B20). Fills `errors` for hard
    /// failures; `warnings` for unknown keys.
    pub fn validate(self: *Store) !void {
        if (self.get("schema_version")) |v| {
            if (v != .integer or v.integer != 1) {
                try self.addError("schema_version", "unsupported schema version (expected 1)", .{});
            }
        }
        // Unknown top-level keys warn.
        if (self.value == .object) {
            var it = self.value.object.iterator();
            outer: while (it.next()) |entry| {
                for (known_sections) |known| {
                    if (std.mem.eql(u8, known, entry.key_ptr.*)) continue :outer;
                }
                try self.warn("unknown config key '{s}' ignored", .{entry.key_ptr.*});
            }
        }
        // Security sections fail closed.
        const mode = self.getString("permissions.default_mode", "ask");
        if (!std.mem.eql(u8, mode, "ask") and !std.mem.eql(u8, mode, "auto")) {
            try self.addError("permissions.default_mode", "must be \"ask\" or \"auto\", got \"{s}\"", .{mode});
        }
        const provider = self.getString("model.provider", "openai");
        if (!std.mem.eql(u8, provider, "openai") and !std.mem.eql(u8, provider, "anthropic")) {
            try self.addError("model.provider", "must be \"openai\" or \"anthropic\", got \"{s}\"", .{provider});
        }
    }
};

fn mergeObjects(arena: std.mem.Allocator, dst: std.json.Value, src: std.json.Value) !std.json.Value {
    var out = try std.json.ObjectMap.init(arena, &.{}, &.{});
    var dst_it = dst.object.iterator();
    while (dst_it.next()) |entry| {
        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    var src_it = src.object.iterator();
    while (src_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const src_v = entry.value_ptr.*;
        if (src_v == .object) {
            if (out.getPtr(key)) |dst_v| {
                if (dst_v.* == .object) {
                    try out.put(arena, try arena.dupe(u8, key), try mergeObjects(arena, dst_v.*, src_v));
                    continue;
                }
            }
        }
        try out.put(arena, try arena.dupe(u8, key), try cloneValue(arena, src_v));
    }
    return .{ .object = out };
}

fn cloneValue(arena: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float, .number_string => v,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(arena);
            for (arr.items) |item| try out.append(try cloneValue(arena, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = try std.json.ObjectMap.init(arena, &.{}, &.{});
            var it = obj.iterator();
            while (it.next()) |entry| {
                try out.put(arena, try arena.dupe(u8, entry.key_ptr.*), try cloneValue(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

/// Load configuration from disk layers (user + project) and environment.
/// `project_dir` is the directory that may contain `.ifnh/` (pass null to
/// skip project layers). Disk failures on optional layers are warnings.
pub fn load(
    parent_alloc: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    project_dir: ?std.Io.Dir,
) !Store {
    var store = try Store.init(parent_alloc);
    errdefer store.deinit();
    const arena = store.alloc();
    const cwd = project_dir orelse std.Io.Dir.cwd();

    // ---- user layer ----
    if (userConfigPath(arena, environ)) |user_path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, user_path, arena, .limited(max_config_bytes))) |text| {
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
                try store.addError("user", "invalid JSON in {s}", .{user_path});
                return store;
            };
            try store.mergeValue(v, .{ .layer = .user, .origin = user_path });
        } else |_| {}
    }

    // ---- project layer ----
    if (project_dir != null) {
        if (cwd.readFileAlloc(io, ".ifnh/config.json", arena, .limited(max_config_bytes))) |text| {
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
                try store.addError(".ifnh/config.json", "invalid JSON in .ifnh/config.json", .{});
                return store;
            };
            try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
        } else |_| {}

        // config.d/*.json merged in sorted filename order.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (cwd.openDir(io, ".ifnh/config.d", .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                    try names.append(arena, try arena.dupe(u8, entry.name));
                }
            }
        } else |_| {}
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const rel = try std.fmt.allocPrint(arena, ".ifnh/config.d/{s}", .{name});
            const text = cwd.readFileAlloc(io, rel, arena, .limited(max_config_bytes)) catch continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
                try store.addError(rel, "invalid JSON in {s}", .{rel});
                return store;
            };
            try store.mergeValue(v, .{ .layer = .project, .origin = rel });
        }
    }

    // ---- env layer: IFNH_<PATH>__<KEY> ----
    if (environ) |env| {
        var it = env.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, "IFNH_")) continue;
            const rest = key["IFNH_".len..];
            if (rest.len == 0) continue;
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            var sit = std.mem.splitSequence(u8, rest, "__");
            while (sit.next()) |part| {
                const lower = try std.ascii.allocLowerString(arena, part);
                try parts.append(arena, lower);
            }
            const dotted = try std.mem.join(arena, ".", parts.items);
            const raw = entry.value_ptr.*;
            // Parse as JSON when possible (numbers/bools); else string.
            const v: std.json.Value = blk: {
                if (std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{})) |parsed| {
                    break :blk parsed;
                } else |_| {
                    break :blk .{ .string = try arena.dupe(u8, raw) };
                }
            };
            try store.setPath(dotted, v);
            try store.sources.put(arena, dotted, .{
                .layer = .env,
                .origin = try std.fmt.allocPrint(arena, "env:{s}", .{key}),
            });
        }
    }

    try store.validate();
    return store;
}

pub const max_config_bytes: usize = 256 * 1024;

/// Platform-appropriate user config file path, allocated in `arena`.
pub fn userConfigPath(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const home = if (environ) |e| e.get("HOME") else null;
    if (home == null) return null;
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(arena, "{s}/Library/Application Support/ifnh/config.json", .{home.?}) catch null;
    }
    if (environ) |e| {
        if (e.get("XDG_CONFIG_HOME")) |xdg| {
            if (xdg.len > 0) {
                return std.fmt.allocPrint(arena, "{s}/ifnh/config.json", .{xdg}) catch null;
            }
        }
    }
    return std.fmt.allocPrint(arena, "{s}/.config/ifnh/config.json", .{home.?}) catch null;
}

test "defaults parse and validate" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.validate();
    try std.testing.expectEqualStrings("openai", store.getString("model.provider", ""));
    try std.testing.expectEqualStrings("ask", store.getString("permissions.default_mode", ""));
    try std.testing.expectEqual(@as(u32, 120), store.getU32("agents.timeout_tool_s", 0));
    try std.testing.expect(store.errors.items.len == 0);
}

test "merge layers with source tracking" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    const project_json =
        \\{ "model": { "model": "claude-sonnet-4-6", "provider": "anthropic" } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), project_json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });

    try std.testing.expectEqualStrings("anthropic", store.getString("model.provider", ""));
    // Untouched default key keeps builtin source.
    try std.testing.expectEqual(Layer.builtin, store.getSource("model.api_key_env").?.layer);
    // Overridden keys carry project source.
    const src = store.getSource("model.model").?;
    try std.testing.expectEqual(Layer.project, src.layer);
    try std.testing.expectEqualStrings(".ifnh/config.json", src.origin);
}

test "env overrides with __ nesting and json values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("IFNH_PERMISSIONS__DEFAULT_MODE", "auto");
    try env.put("IFNH_AGENTS__MAX_DEPTH", "2");
    try env.put("IFNH_MODEL__MODEL", "gpt-x");

    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    try applyEnvForTest(&store, &env);
    try std.testing.expectEqualStrings("auto", store.getString("permissions.default_mode", ""));
    try std.testing.expectEqual(@as(u32, 2), store.getU32("agents.max_depth", 0));
    try std.testing.expectEqualStrings("gpt-x", store.getString("model.model", ""));
    try std.testing.expectEqual(Layer.env, store.getSource("permissions.default_mode").?.layer);
}

/// Test helper mirroring the env pass of `load` without disk layers.
fn applyEnvForTest(store: *Store, env: *const std.process.Environ.Map) !void {
    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "IFNH_")) continue;
        const rest = key["IFNH_".len..];
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var sit = std.mem.splitSequence(u8, rest, "__");
        while (sit.next()) |part| {
            try parts.append(store.alloc(), try std.ascii.allocLowerString(store.alloc(), part));
        }
        const dotted = try std.mem.join(store.alloc(), ".", parts.items);
        const raw = entry.value_ptr.*;
        const v: std.json.Value = blk: {
            if (std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), raw, .{})) |parsed| {
                break :blk parsed;
            } else |_| {
                break :blk .{ .string = try store.alloc().dupe(u8, raw) };
            }
        };
        try store.setPath(dotted, v);
        try store.sources.put(store.alloc(), dotted, .{ .layer = .env, .origin = "env:test" });
    }
}

test "override and explain" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyOverride("model.model", "\"m1\"", .{ .layer = .cli, .origin = "cli" });
    try std.testing.expectEqualStrings("m1", store.getString("model.model", ""));
    try std.testing.expectEqual(Layer.cli, store.getSource("model.model").?.layer);
}

test "security section fails closed on bad mode" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyOverride("permissions.default_mode", "\"yolo-bypass\"", .{ .layer = .project, .origin = "test" });
    try store.validate();
    try std.testing.expect(store.errors.items.len == 1);
    try std.testing.expectEqualStrings("permissions.default_mode", store.errors.items[0].path);
}

test "setPath creates intermediate objects" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.setPath("a.b.c", .{ .integer = 7 });
    try std.testing.expectEqual(@as(i64, 7), store.get("a.b.c").?.integer);
}
