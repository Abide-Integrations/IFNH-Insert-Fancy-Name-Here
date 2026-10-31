//! Layered JSON configuration (DESIGN §3.5, DECISIONS section B).
//!
//! Precedence (low to high): builtin defaults < user < project < session < env < cli.
//! Every leaf key records which layer supplied it (`ifnh config explain`).
//! Security-relevant sections fail closed: malformed permission data is a
//! hard startup error, never silently ignored.

const std = @import("std");
const trace_mod = @import("../trace.zig");

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
    \\    "max_retries": 3,
    \\    "max_tool_rounds": 25,
    \\    "timeout_tool_s": 120,
    \\    "timeout_turn_s": 600,
    \\    "budget_usd": null
    \\  },
    \\  "tools": {
    \\    "external": true
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
    \\    "footer": true,
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
    "schema_version", "model",    "permissions", "git", "agents", "tools",
    "context",        "planning", "sessions",    "ui",  "debug",
};

/// Top-level keys consumed at runtime that have no builtin default value
/// (optional features). They are valid and never warn.
pub const extra_top_level_keys = [_][]const u8{ "hooks", "mcp_servers" };

/// Section keys read by code that intentionally have no builtin default
/// (feature-detected or derived values). They are valid and never warn.
pub const extra_section_keys = [_][]const u8{
    "model.provider_label",
    "model.tools_enabled",
    "context.max_context_tokens",
};

/// Defaults leaves read at runtime (A-T07). The test at the bottom of this
/// file keeps this list and the defaults table in sync.
pub const wired_defaults = [_][]const u8{
    "model.provider",              "model.model",
    "model.base_url",              "model.api_key_env",
    "model.temperature",           "model.max_output_tokens",
    "permissions.default_mode",    "permissions.read",
    "permissions.write",           "permissions.command_allow",
    "permissions.command_deny",    "permissions.env_allow",
    "permissions.read_dotenv",     "git.commits",
    "git.push",                    "git.force_push",
    "agents.max_depth",            "agents.max_concurrent",
    "agents.max_retries",          "agents.max_tool_rounds",
    "agents.timeout_tool_s",       "agents.budget_usd",
    "tools.external",              "context.auto_compact",
    "context.compact_at_fraction", "context.max_file_read_bytes",
    "sessions.dir",                "sessions.keep",
    "ui.colors",                   "ui.footer",
    "debug.redact",
};

/// Defaults leaves deliberately not read yet: each would need a feature that
/// does not exist. Documented allowlist (A-T07), not a silent gap.
pub const unwired_defaults = [_][]const u8{
    "agents.timeout_turn_s", // no turn deadline yet (F-A06 follow-up)
    "planning.auto_call_threshold", // planning auto-invocation not implemented
    "ui.symbols", // no ascii/unicode symbol set yet
    "ui.verbosity", // no verbosity levels yet
    "debug.level", // std log level is comptime (`std_options`); no runtime logger
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
    /// Recursively compare the merged tree against the defaults schema,
    /// warning on keys the schema does not know (A-T07).
    fn validateKeys(self: *Store, value: std.json.Value, defaults: std.json.Value, prefix: []const u8) !void {
        if (value != .object) return;
        const arena = self.alloc();
        var it = value.object.iterator();
        loop: while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const path = if (prefix.len == 0)
                key
            else
                try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, key });
            if (prefix.len == 0) {
                for (known_sections) |known| {
                    if (!std.mem.eql(u8, known, key)) continue;
                    const no_default: std.json.Value = .{ .null = {} };
                    const child = if (defaults == .object) defaults.object.get(key) orelse no_default else no_default;
                    try self.validateKeys(entry.value_ptr.*, child, path);
                    continue :loop;
                }
                for (extra_top_level_keys) |known| {
                    if (std.mem.eql(u8, known, key)) continue :loop;
                }
            } else {
                for (extra_section_keys) |known| {
                    if (std.mem.eql(u8, known, path)) continue :loop;
                }
                if (defaults == .object) {
                    if (defaults.object.get(key)) |child| {
                        try self.validateKeys(entry.value_ptr.*, child, path);
                        continue :loop;
                    }
                }
            }
            try self.warn("unknown config key '{s}' ignored", .{path});
        }
    }

    pub fn validate(self: *Store) !void {
        if (self.get("schema_version")) |v| {
            if (v != .integer or v.integer != 1) {
                try self.addError("schema_version", "unsupported schema version (expected 1)", .{});
            }
        }
        // Unknown keys warn, at any depth, with their full dotted path. The
        // defaults table is the schema.
        const defaults = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc(), default_config_json, .{});
        try self.validateKeys(self.value, defaults, "");
        // Security sections fail closed.
        const mode = self.getString("permissions.default_mode", "ask");
        if (!std.mem.eql(u8, mode, "ask") and !std.mem.eql(u8, mode, "auto")) {
            try self.addError("permissions.default_mode", "must be \"ask\" or \"auto\", got \"{s}\"", .{mode});
        }
        const provider = self.getString("model.provider", "openai");
        if (!std.mem.eql(u8, provider, "openai") and !std.mem.eql(u8, provider, "anthropic")) {
            try self.addError("model.provider", "must be \"openai\" or \"anthropic\", got \"{s}\"", .{provider});
        }
        if (self.get("tools.external")) |value| {
            if (value != .bool) try self.addError("tools.external", "must be true or false", .{});
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
            if (std.mem.eql(u8, key, trace_mod.env_var)) continue; // runtime switch, not config
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

/// Single user config directory convention, on every platform including
/// macOS: `$XDG_CONFIG_HOME/ifnh` when set, else `~/.config/ifnh`.
pub fn userConfigDir(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    if (environ) |e| {
        if (e.get("XDG_CONFIG_HOME")) |xdg| {
            if (xdg.len > 0) {
                return std.fmt.allocPrint(arena, "{s}/ifnh", .{xdg}) catch null;
            }
        }
    }
    const home = if (environ) |e| e.get("HOME") else null;
    if (home == null or home.?.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/.config/ifnh", .{home.?}) catch null;
}

/// User config file path, allocated in `arena`.
pub fn userConfigPath(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const dir = userConfigDir(arena, environ) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/config.json", .{dir}) catch null;
}

/// Persistent provider-key file path (`<config dir>/env`).
pub fn userEnvPath(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const dir = userConfigDir(arena, environ) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/env", .{dir}) catch null;
}

/// User skills directory (`<config dir>/skills`).
pub fn userSkillsDir(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const dir = userConfigDir(arena, environ) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/skills", .{dir}) catch null;
}

/// User state root for logs/worktrees: `~/.local/state/ifnh` on every
/// platform (matching the existing code, macOS included).
pub fn userStateDir(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const home = if (environ) |e| e.get("HOME") else null;
    if (home == null or home.?.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/.local/state/ifnh", .{home.?}) catch null;
}

fn testEnvironment(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

test "user config path honours XDG_CONFIG_HOME and falls back on every platform" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var xdg_env = try testEnvironment(&.{
        .{ "HOME", "/home/me" },
        .{ "XDG_CONFIG_HOME", "/xdg" },
    });
    defer xdg_env.deinit();
    try std.testing.expectEqualStrings("/xdg/ifnh/config.json", userConfigPath(arena, &xdg_env).?);
    try std.testing.expectEqualStrings("/xdg/ifnh", userConfigDir(arena, &xdg_env).?);
    try std.testing.expectEqualStrings("/xdg/ifnh/env", userEnvPath(arena, &xdg_env).?);
    try std.testing.expectEqualStrings("/xdg/ifnh/skills", userSkillsDir(arena, &xdg_env).?);

    var home_env = try testEnvironment(&.{
        .{ "HOME", "/home/me" },
        .{ "XDG_CONFIG_HOME", "" },
    });
    defer home_env.deinit();
    try std.testing.expectEqualStrings("/home/me/.config/ifnh/config.json", userConfigPath(arena, &home_env).?);
    try std.testing.expectEqualStrings("/home/me/.local/state/ifnh", userStateDir(arena, &home_env).?);

    var empty_env = try testEnvironment(&.{});
    defer empty_env.deinit();
    try std.testing.expect(userConfigPath(arena, &empty_env) == null);
    try std.testing.expect(userStateDir(arena, &empty_env) == null);
}

test "defaults parse and validate" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.validate();
    try std.testing.expectEqualStrings("openai", store.getString("model.provider", ""));
    try std.testing.expectEqualStrings("ask", store.getString("permissions.default_mode", ""));
    try std.testing.expectEqual(@as(u32, 120), store.getU32("agents.timeout_tool_s", 0));
    try std.testing.expect(store.getBool("tools.external", false));
    try std.testing.expect(store.errors.items.len == 0);
}

test "tools.external must be a boolean" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyOverride("tools.external", "\"yes\"", .{ .layer = .project, .origin = "test" });
    try store.validate();
    try std.testing.expect(store.errors.items.len == 1);
    try std.testing.expectEqualStrings("tools.external", store.errors.items[0].path);
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

test "trace runtime env switch is not a config key" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(trace_mod.env_var, "1");

    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try applyEnvForTest(&store, &env);
    try store.validate();

    try std.testing.expect(store.get("trace.startup") == null);
    for (store.warnings.items) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "trace") == null);
    }
}

/// Test helper mirroring the env pass of `load` without disk layers.
fn applyEnvForTest(store: *Store, env: *const std.process.Environ.Map) !void {
    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "IFNH_")) continue;
        if (std.mem.eql(u8, key, trace_mod.env_var)) continue; // runtime switch, not config
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

test "validate warns on unknown keys at any depth with full path" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const project_json =
        \\{ "permissions": { "read_dotenv": true, "command_allowed": ["ls"] },
        \\  "model": { "provider_label": "local" },
        \\  "hooks": {}, "mcp_servers": {}, "bogus": 1 }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), project_json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
    try store.validate();
    try std.testing.expect(store.errors.items.len == 0);
    var saw_nested = false;
    var saw_top = false;
    for (store.warnings.items) |w| {
        if (std.mem.indexOf(u8, w, "permissions.command_allowed") != null) saw_nested = true;
        if (std.mem.indexOf(u8, w, "bogus") != null) saw_top = true;
    }
    try std.testing.expect(saw_nested);
    try std.testing.expect(saw_top);
    // Real keys (including runtime-only ones) never warn.
    for (store.warnings.items) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "provider_label") == null);
        try std.testing.expect(std.mem.indexOf(u8, w, "hooks") == null);
        try std.testing.expect(std.mem.indexOf(u8, w, "mcp_servers") == null);
        try std.testing.expect(std.mem.indexOf(u8, w, "read_dotenv") == null);
    }
}

test "every defaults key is wired or documented as unwired" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var leaves: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectLeaves(arena_state.allocator(), store.value, "", &leaves);

    for (leaves.items) |leaf| {
        const known = std.mem.eql(u8, leaf, "schema_version") or
            inList(&wired_defaults, leaf) or inList(&unwired_defaults, leaf);
        if (!known) {
            std.debug.print("defaults key '{s}' is neither wired nor in unwired_defaults\n", .{leaf});
            return error.TestUnexpectedResult;
        }
    }
    // Entries that are not defaults leaves are stale.
    for (&wired_defaults) |key| try std.testing.expect(inList(leaves.items, key));
    for (&unwired_defaults) |key| try std.testing.expect(inList(leaves.items, key));
}

fn inList(list: []const []const u8, key: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

fn collectLeaves(alloc: std.mem.Allocator, value: std.json.Value, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    if (value != .object) return;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const path = if (prefix.len == 0)
            try alloc.dupe(u8, entry.key_ptr.*)
        else
            try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        switch (entry.value_ptr.*) {
            .object => try collectLeaves(alloc, entry.value_ptr.*, path, out),
            else => try out.append(alloc, path),
        }
    }
}

test "setPath creates intermediate objects" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.setPath("a.b.c", .{ .integer = 7 });
    try std.testing.expectEqual(@as(i64, 7), store.get("a.b.c").?.integer);
}
