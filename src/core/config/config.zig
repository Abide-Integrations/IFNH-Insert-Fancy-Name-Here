//! Layered JSON configuration (DESIGN §3.5, DECISIONS section B).
//!
//! Precedence (low to high): builtin defaults < user < project < session < env < cli.
//! Every leaf key records which layer supplied it (`ifnh config explain`).
//! Security-relevant sections fail closed: malformed permission data is a
//! hard startup error, never silently ignored.

const std = @import("std");
const trace_mod = @import("../trace.zig");
const wire_log = @import("../wire_log.zig");
const resolve_mod = @import("resolve.zig");
const mcp_mod = @import("../mcp.zig");

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
    \\    "max_output_tokens": null,
    \\    "provider_options": {}
    \\  },
    \\  "models": {
    \\    "aliases": {},
    \\    "fallbacks": {},
    \\    "provider_options": {}
    \\  },
    \\  "routing": {
    \\    "parent": "default",
    \\    "research": "default",
    \\    "implement": "default",
    \\    "review": "default"
    \\  },
    \\  "profiles": {},
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
    \\  "sessions": {
    \\    "dir": "project",
    \\    "keep": 30
    \\  },
    \\  "ui": {
    \\    "colors": true,
    \\    "footer": true
    \\  },
    \\  "debug": {
    \\    "redact": true
    \\  },
    \\  "memory": {
    \\    "adapter": "none",
    \\    "scope": "project"
    \\  }
    \\}
;

/// Top-level sections recognized by the schema. Unknown keys produce
/// warnings (DECISIONS B19); unknown values in security sections are errors.
pub const known_sections = [_][]const u8{
    "schema_version", "model", "models", "routing", "profiles",
    "permissions",    "git",   "agents", "tools",   "context",
    "sessions",       "ui",    "debug",  "memory",
};

/// Subtrees keyed by user-chosen names (alias names, model ids, profile
/// names): there is no schema to compare below them, so validation stops.
pub const free_form_paths = [_][]const u8{
    "models.aliases",
    "models.fallbacks",
    "models.provider_options",
    "model.provider_options",
    "profiles",
};

/// Top-level keys consumed at runtime that have no builtin default value
/// (optional features). They are valid and never warn.
pub const extra_top_level_keys = [_][]const u8{ "hooks", "mcp_servers" };

/// Section keys read by code that intentionally have no builtin default
/// (feature-detected or derived values). They are valid and never warn.
pub const extra_section_keys = [_][]const u8{
    "model.provider_label",
    "model.tools_enabled",
    "model.auth",
    "memory.server",
    "memory.tools",
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
    "debug.redact",                "routing.parent",
    "routing.research",            "routing.implement",
    "routing.review",              "memory.adapter",
    "memory.scope",
};

/// `IFNH_*` variables that switch runtime features and are not config keys.
fn isRuntimeSwitch(key: []const u8) bool {
    return std.mem.eql(u8, key, trace_mod.env_var) or std.mem.eql(u8, key, wire_log.env_var);
}

pub const Store = struct {
    arena_state: std.heap.ArenaAllocator,
    /// Merged configuration tree (owned by arena).
    value: std.json.Value,
    /// Dotted key path -> winning source.
    sources: std.StringHashMapUnmanaged(Source) = .empty,
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Messages already handed out by `newWarnings`.
    reported: std.ArrayListUnmanaged([]const u8) = .empty,
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
        try setPathIn(self.alloc(), &self.value, dotted_path, v);
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

    /// Like `getOptionalString`, but null unless a user, project, session, env
    /// or cli layer set the key. The builtin default of `model.api_key_env`
    /// names OpenAI's variable and must not stand in for another provider's.
    pub fn getConfiguredString(self: *const Store, path: []const u8) ?[]const u8 {
        const src = self.sources.get(path) orelse return null;
        if (src.layer == .builtin) return null;
        return self.getOptionalString(path);
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

    /// Append a warning (bounded). Reachable from per-turn model resolution
    /// too, so each distinct message is reported once.
    pub fn warn(self: *Store, comptime fmt: []const u8, args: anytype) !void {
        if (self.warnings.items.len >= 64) return;
        const msg = try std.fmt.allocPrint(self.alloc(), fmt, args);
        for (self.warnings.items) |existing| {
            if (std.mem.eql(u8, existing, msg)) return;
        }
        try self.warnings.append(self.alloc(), msg);
    }

    /// Warnings not returned by an earlier call. Applying a profile or flags
    /// re-validates (and regenerates every warning), so callers print through
    /// this rather than iterating `warnings`, or each would show up twice.
    pub fn newWarnings(self: *Store) ![]const []const u8 {
        const start = self.reported.items.len;
        outer: for (self.warnings.items) |w| {
            for (self.reported.items) |r| {
                if (std.mem.eql(u8, r, w)) continue :outer;
            }
            try self.reported.append(self.alloc(), w);
        }
        return self.reported.items[start..];
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
        for (free_form_paths) |free_form| {
            if (std.mem.eql(u8, prefix, free_form)) return;
        }
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
        if (resolve_mod.providerFor(provider) == null) {
            try self.addError("model.provider", "must be \"openai\", \"anthropic\", \"openai-responses\" or \"gemini\", got \"{s}\"", .{provider});
        }
        if (self.get("model.auth")) |a| {
            if (a != .null and (a != .string or resolve_mod.parseAuth(a.string) == null)) {
                try self.addError("model.auth", "must be \"api_key\" or \"oauth\"", .{});
            }
        }
        if (self.get("tools.external")) |value| {
            if (value != .bool) try self.addError("tools.external", "must be true or false", .{});
        }
        // Aliases, fallback chains, routing and profiles reference each
        // other by name; check the references (D44/D45/D49).
        try resolve_mod.validateConfig(self);
        try self.validateMcpServers();
        try self.validateMemory();
    }

    /// `memory.*`: adapter and scope are closed sets; the MCP adapter needs a
    /// `server` that exists in `mcp_servers`; `tools` names three MCP tools.
    fn validateMemory(self: *Store) !void {
        const adapter = self.getString("memory.adapter", "none");
        const known_adapter = std.mem.eql(u8, adapter, "none") or std.mem.eql(u8, adapter, "file") or std.mem.eql(u8, adapter, "mcp");
        if (!known_adapter) {
            try self.addError("memory.adapter", "must be \"none\", \"file\" or \"mcp\", got \"{s}\"", .{adapter});
        }
        const scope = self.getString("memory.scope", "project");
        if (!std.mem.eql(u8, scope, "project") and !std.mem.eql(u8, scope, "user")) {
            try self.addError("memory.scope", "must be \"project\" or \"user\", got \"{s}\"", .{scope});
        }
        if (self.get("memory.tools")) |tools| {
            var ok = tools == .object;
            if (ok) {
                var it = tools.object.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.* != .string or kv.value_ptr.string.len == 0) ok = false;
                }
            }
            if (!ok) try self.addError("memory.tools", "must be an object of tool names {{recall, remember, forget}}", .{});
        }
        if (!std.mem.eql(u8, adapter, "mcp")) return;
        const server = self.getOptionalString("memory.server") orelse
            return self.addError("memory.server", "required when memory.adapter is \"mcp\"", .{});
        const servers = self.get("mcp_servers");
        const listed = if (servers) |sv| sv == .object and sv.object.get(server) != null else false;
        if (!listed) try self.addError("memory.server", "\"{s}\" is not an entry of mcp_servers", .{server});
    }

    /// `mcp_servers.<name>`: exactly one of `command` (stdio) or `url` (HTTP),
    /// well-typed `headers`/`agents`. An unknown agent identity only warns, so
    /// a role list written for a newer build still loads.
    fn validateMcpServers(self: *Store) !void {
        const servers = self.get("mcp_servers") orelse return;
        if (servers != .object) return self.addError("mcp_servers", "must be an object", .{});
        const arena = self.alloc();
        var it = servers.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const path = try std.fmt.allocPrint(arena, "mcp_servers.{s}", .{name});
            if (entry.value_ptr.* != .object) {
                try self.addError(path, "must be an object", .{});
                continue;
            }
            const o = entry.value_ptr.object;
            const has_command = o.get("command") != null;
            const has_url = o.get("url") != null;
            if (has_command and has_url) {
                try self.addError(path, "set either \"command\" (stdio) or \"url\" (HTTP), not both", .{});
            } else if (!has_command and !has_url) {
                try self.addError(path, "needs \"command\" (stdio server) or \"url\" (HTTP server)", .{});
            }
            if (o.get("command")) |c| {
                if (c != .string or c.string.len == 0) try self.addError(path, "\"command\" must be a non-empty string", .{});
            }
            if (o.get("url")) |u| {
                if (u != .string or u.string.len == 0) try self.addError(path, "\"url\" must be a non-empty string", .{});
            }
            if (o.get("headers")) |h| {
                var ok = h == .object;
                if (ok) {
                    var hit = h.object.iterator();
                    while (hit.next()) |kv| {
                        if (kv.value_ptr.* != .string) ok = false;
                    }
                }
                if (!ok) try self.addError(path, "\"headers\" must be an object of strings", .{});
            }
            if (o.get("agents")) |a| {
                if (a != .array) {
                    try self.addError(path, "\"agents\" must be an array of strings", .{});
                    continue;
                }
                for (a.array.items, 0..) |item, i| {
                    if (item != .string) {
                        try self.addError(path, "\"agents\" must be an array of strings", .{});
                        break;
                    }
                    const known = for (mcp_mod.agent_identities) |id| {
                        if (std.mem.eql(u8, id, item.string)) break true;
                    } else false;
                    if (!known) try self.warn("{s}.agents[{d}]: unknown agent '{s}' (parent, research, implement, review)", .{ path, i, item.string });
                }
            }
        }
    }

    /// Merge `profiles.<name>` into the live tree at the CLI layer and
    /// re-validate (a profile is config like any other). The `prompt`
    /// fragment stays out of the tree: the prompt assembler reads it through
    /// `profilePrompt`.
    pub fn applyProfile(self: *Store, name: []const u8) !void {
        const arena = self.alloc();
        const profiles = self.get("profiles") orelse return error.UnknownProfile;
        if (profiles != .object) return error.UnknownProfile;
        const profile = profiles.object.get(name) orelse return error.UnknownProfile;
        if (profile != .object) return error.UnknownProfile;

        var copy = try std.json.ObjectMap.init(arena, &.{}, &.{});
        var it = profile.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "prompt")) continue;
            try copy.put(arena, entry.key_ptr.*, try cloneValue(arena, entry.value_ptr.*));
        }
        const origin = try std.fmt.allocPrint(arena, "--profile {s}", .{name});
        try self.mergeValue(.{ .object = copy }, .{ .layer = .cli, .origin = origin });

        self.errors.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();
        try self.validate();
    }

    /// `profiles.<name>.prompt`: the fragment appended after the assembled
    /// system prompt (D-03).
    pub fn profilePrompt(self: *const Store, name: []const u8) ?[]const u8 {
        const profiles = self.get("profiles") orelse return null;
        if (profiles != .object) return null;
        const profile = profiles.object.get(name) orelse return null;
        if (profile != .object) return null;
        const v = profile.object.get("prompt") orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// Merge the per-key CLI flags (`--model`, `--temperature`, ...) as the
    /// highest-precedence layer and re-validate (a flag is config like any
    /// other, D-06). Call after `applyProfile` so an explicit flag wins.
    pub fn applyCliOverrides(self: *Store, overrides: []const CliOverride) !void {
        if (overrides.len == 0) return;
        const arena = self.alloc();
        for (overrides) |o| {
            const json = switch (o.kind) {
                .string => blk: {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    try std.json.Stringify.value(o.value, .{}, &aw.writer);
                    break :blk aw.written();
                },
                .raw_json => o.value,
                .boolean_false => "false",
            };
            try self.applyOverride(o.path, json, .{ .layer = .cli, .origin = o.origin });
        }
        self.errors.clearRetainingCapacity();
        self.warnings.clearRetainingCapacity();
        try self.validate();
    }

    /// Diagnostic for `--profile`: names the unknown profile and lists the
    /// known ones in a stable order.
    pub fn unknownProfileMessage(self: *const Store, arena: std.mem.Allocator, name: []const u8) []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.get("profiles")) |profiles| {
            if (profiles == .object) {
                var it = profiles.object.iterator();
                while (it.next()) |entry| names.append(arena, entry.key_ptr.*) catch {};
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const joined = std.mem.join(arena, ", ", names.items) catch "";
        return std.fmt.allocPrint(arena, "unknown profile '{s}'; known profiles: {s}", .{
            name,
            if (joined.len == 0) "(none)" else joined,
        }) catch "unknown profile";
    }
};

/// One per-key CLI flag (`--model`, `--temperature`, ...) applied as the
/// `.cli` layer. `value` is the raw flag text for `.raw_json` and the
/// literal string for `.string`.
pub const CliOverride = struct {
    path: []const u8,
    value: []const u8 = "",
    kind: CliValueKind = .string,
    origin: []const u8,
};

pub const CliValueKind = enum { string, raw_json, boolean_false };

/// Set `dotted_path` inside an arbitrary JSON tree, creating intermediate
/// objects. Shared by `Store.setPath` and `ifnh config set`, which mutates a
/// file tree before writing it back (D-06).
pub fn setPathIn(
    arena: std.mem.Allocator,
    value: *std.json.Value,
    dotted_path: []const u8,
    v: std.json.Value,
) !void {
    if (value.* != .object) {
        value.* = .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
    }
    var obj_ptr: *std.json.ObjectMap = &value.object;
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
            if (isRuntimeSwitch(key)) continue; // runtime switch, not config
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

/// Result of checking a candidate config *file* body before writing it.
pub const FileCheck = struct {
    errors: []const ValidationError,
    warnings: []const []const u8,
};

/// Validate one config file's text exactly as `load` would: parse, merge it
/// over the builtin defaults, run the structural checks. `ifnh config set`
/// refuses to write while `errors` is non-empty. All storage is arena-owned.
pub fn validateFileText(arena: std.mem.Allocator, text: []const u8) !FileCheck {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return .{ .errors = try arena.dupe(ValidationError, &.{.{ .path = "file", .message = "invalid JSON" }}), .warnings = &.{} };
    };
    var store = try Store.init(arena);
    defer store.deinit();
    try store.mergeValue(v, .{ .layer = .project, .origin = "candidate" });
    try store.validate();

    var errors: std.ArrayListUnmanaged(ValidationError) = .empty;
    for (store.errors.items) |e| try errors.append(arena, .{
        .path = try arena.dupe(u8, e.path),
        .message = try arena.dupe(u8, e.message),
    });
    var warnings: std.ArrayListUnmanaged([]const u8) = .empty;
    for (store.warnings.items) |w| try warnings.append(arena, try arena.dupe(u8, w));
    return .{ .errors = errors.items, .warnings = warnings.items };
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

test "model.provider accepts the four adapters and names them on error" {
    for ([_][]const u8{ "\"openai\"", "\"anthropic\"", "\"openai-responses\"", "\"gemini\"" }) |value| {
        var store = try Store.init(std.testing.allocator);
        defer store.deinit();
        try store.applyOverride("model.provider", value, .{ .layer = .project, .origin = "test" });
        try store.validate();
        try std.testing.expectEqual(@as(usize, 0), store.errors.items.len);
    }
    var bad = try Store.init(std.testing.allocator);
    defer bad.deinit();
    try bad.applyOverride("model.provider", "\"bedrock\"", .{ .layer = .project, .origin = "test" });
    try bad.validate();
    try std.testing.expectEqual(@as(usize, 1), bad.errors.items.len);
    try std.testing.expectEqualStrings("must be \"openai\", \"anthropic\", \"openai-responses\" or \"gemini\", got \"bedrock\"", bad.errors.items[0].message);
}

test "model.auth accepts api_key and oauth only, naming the key" {
    for ([_][]const u8{ "\"api_key\"", "\"oauth\"" }) |value| {
        var store = try Store.init(std.testing.allocator);
        defer store.deinit();
        try store.applyOverride("model.auth", value, .{ .layer = .project, .origin = "test" });
        try store.validate();
        try std.testing.expectEqual(@as(usize, 0), store.errors.items.len);
        try std.testing.expectEqual(@as(usize, 0), store.warnings.items.len);
    }
    var bad = try Store.init(std.testing.allocator);
    defer bad.deinit();
    try bad.applyOverride("model.auth", "\"token\"", .{ .layer = .project, .origin = "test" });
    try bad.validate();
    try std.testing.expectEqual(@as(usize, 1), bad.errors.items.len);
    try std.testing.expectEqualStrings("model.auth", bad.errors.items[0].path);
}

test "memory: unknown adapter and scope are startup errors naming the key" {
    var store = try mcpStore("{\"memory\":{\"adapter\":\"redis\",\"scope\":\"team\"}}");
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 2), store.errors.items.len);
    try std.testing.expectEqualStrings("memory.adapter", store.errors.items[0].path);
    try std.testing.expectEqualStrings("memory.scope", store.errors.items[1].path);

    var ok = try mcpStore("{\"memory\":{\"adapter\":\"file\",\"scope\":\"user\"}}");
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 0), ok.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), ok.warnings.items.len);
}

test "memory: adapter mcp needs a server that exists in mcp_servers" {
    var missing = try mcpStore("{\"memory\":{\"adapter\":\"mcp\"},\"mcp_servers\":{\"honcho\":{\"command\":\"x\"}}}");
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.errors.items.len);
    try std.testing.expectEqualStrings("memory.server", missing.errors.items[0].path);

    var absent = try mcpStore("{\"memory\":{\"adapter\":\"mcp\",\"server\":\"nope\"},\"mcp_servers\":{\"honcho\":{\"command\":\"x\"}}}");
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 1), absent.errors.items.len);
    try std.testing.expectEqualStrings("memory.server", absent.errors.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, absent.errors.items[0].message, "nope") != null);

    var ok = try mcpStore("{\"memory\":{\"adapter\":\"mcp\",\"server\":\"honcho\",\"tools\":{\"recall\":\"r\"}},\"mcp_servers\":{\"honcho\":{\"command\":\"x\"}}}");
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 0), ok.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), ok.warnings.items.len);

    var bad_tools = try mcpStore("{\"memory\":{\"adapter\":\"file\",\"tools\":{\"recall\":3}}}");
    defer bad_tools.deinit();
    try std.testing.expectEqual(@as(usize, 1), bad_tools.errors.items.len);
    try std.testing.expectEqualStrings("memory.tools", bad_tools.errors.items[0].path);
}

fn mcpStore(json: []const u8) !Store {
    var store = try Store.init(std.testing.allocator);
    errdefer store.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = "test" });
    try store.validate();
    return store;
}

test "mcp_servers: command xor url, naming the server" {
    var both = try mcpStore("{\"mcp_servers\":{\"remote\":{\"command\":\"x\",\"url\":\"http://h/mcp\"}}}");
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.errors.items.len);
    try std.testing.expectEqualStrings("mcp_servers.remote", both.errors.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, both.errors.items[0].message, "not both") != null);

    var neither = try mcpStore("{\"mcp_servers\":{\"empty\":{\"args\":[]}}}");
    defer neither.deinit();
    try std.testing.expectEqual(@as(usize, 1), neither.errors.items.len);
    try std.testing.expectEqualStrings("mcp_servers.empty", neither.errors.items[0].path);

    var ok = try mcpStore(
        \\{"mcp_servers":{"a":{"command":"x"},"b":{"url":"http://h/mcp","headers":{"Authorization":"Bearer t"},"agents":["parent","research"]}}}
    );
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 0), ok.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), ok.warnings.items.len);

    var bad_types = try mcpStore(
        \\{"mcp_servers":{"b":{"url":"http://h","headers":{"A":1},"agents":"parent"}}}
    );
    defer bad_types.deinit();
    try std.testing.expectEqual(@as(usize, 2), bad_types.errors.items.len);
}

test "mcp_servers: an unknown agent identity warns but does not fail" {
    var store = try mcpStore("{\"mcp_servers\":{\"s\":{\"command\":\"x\",\"agents\":[\"research\",\"planner\"]}}}");
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.warnings.items.len);
    try std.testing.expectEqualStrings(
        "mcp_servers.s.agents[1]: unknown agent 'planner' (parent, research, implement, review)",
        store.warnings.items[0],
    );
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
    try env.put(wire_log.env_var, "/tmp/wire.ndjson");

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
        if (isRuntimeSwitch(key)) continue; // runtime switch, not config
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

test "every defaults key is listed in wired_defaults" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var leaves: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectLeaves(arena_state.allocator(), store.value, "", &leaves);

    for (leaves.items) |leaf| {
        const known = std.mem.eql(u8, leaf, "schema_version") or
            inList(&wired_defaults, leaf);
        if (!known) {
            std.debug.print("defaults key '{s}' is not in wired_defaults\n", .{leaf});
            return error.TestUnexpectedResult;
        }
    }
    // Entries that are not defaults leaves are stale.
    for (&wired_defaults) |key| try std.testing.expect(inList(leaves.items, key));
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

test "applyProfile merges at the cli layer without the prompt fragment" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const json =
        \\{ "model": { "model": "base-model" },
        \\  "profiles": { "fast": { "model": { "model": "fast-model" },
        \\                           "permissions": { "default_mode": "auto" },
        \\                           "prompt": "be brief" } } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
    try store.validate();
    try std.testing.expect(store.errors.items.len == 0);

    try store.applyProfile("fast");
    try std.testing.expect(store.errors.items.len == 0);
    try std.testing.expectEqualStrings("fast-model", store.getString("model.model", ""));
    try std.testing.expectEqualStrings("auto", store.getString("permissions.default_mode", ""));
    const src = store.getSource("model.model").?;
    try std.testing.expectEqual(Layer.cli, src.layer);
    try std.testing.expectEqualStrings("--profile fast", src.origin);
    // The prompt fragment is read separately, never merged.
    try std.testing.expectEqualStrings("be brief", store.profilePrompt("fast").?);
    try std.testing.expect(store.get("prompt") == null);
    try std.testing.expect(store.profilePrompt("nope") == null);
}

test "unknown profile is an error naming the known profiles" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const json =
        \\{ "profiles": { "slowp": {}, "alp": {} } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .user, .origin = "user" });

    try std.testing.expectError(error.UnknownProfile, store.applyProfile("bogus"));
    try std.testing.expectEqualStrings(
        "unknown profile 'bogus'; known profiles: alp, slowp",
        store.unknownProfileMessage(store.alloc(), "bogus"),
    );

    var empty = try Store.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectError(error.UnknownProfile, empty.applyProfile("x"));
    try std.testing.expectEqualStrings(
        "unknown profile 'x'; known profiles: (none)",
        empty.unknownProfileMessage(empty.alloc(), "x"),
    );
}

test "applyProfile re-validates aliases and routing it introduces" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const json =
        \\{ "profiles": { "bad": { "routing": { "research": "ghost" } } } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
    try store.validate();
    try std.testing.expect(store.errors.items.len == 0);

    try store.applyProfile("bad");
    try std.testing.expect(store.errors.items.len == 1);
    try std.testing.expectEqualStrings("routing.research", store.errors.items[0].path);
}

test "free-form name sections never warn" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const json =
        \\{ "model": { "provider_options": { "reasoning_effort": "high", "x": 1 } },
        \\  "models": { "aliases": { "fast": { "model": "m", "note": 1 } },
        \\              "fallbacks": { "fast": ["other"] },
        \\              "provider_options": { "gpt-x": { "reasoning_effort": "low" } } },
        \\  "profiles": { "quick": { "model": { "model": "m2" }, "prompt": "p" } } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
    try store.validate();
    // A free-form map is never itself an unknown key: the quoted path has to
    // be the whole section, not a child of one.
    for (free_form_paths) |path| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "unknown config key '{s}'", .{path});
        defer std.testing.allocator.free(needle);
        for (store.warnings.items) |w| {
            try std.testing.expect(std.mem.indexOf(u8, w, needle) == null);
        }
    }
    // Keys inside the maps are still policed: the alias's own stray key warns,
    // and so does an option the openai adapter does not implement.
    var saw_alias_key = false;
    var saw_option = false;
    for (store.warnings.items) |w| {
        if (std.mem.indexOf(u8, w, "models.aliases.fast.note") != null) saw_alias_key = true;
        if (std.mem.indexOf(u8, w, "unknown key 'x' for openai") != null) saw_option = true;
    }
    try std.testing.expect(saw_alias_key and saw_option);
}

test "setPath creates intermediate objects" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.setPath("a.b.c", .{ .integer = 7 });
    try std.testing.expectEqual(@as(i64, 7), store.get("a.b.c").?.integer);
}

test "config setPathIn mutates a file tree and keeps siblings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{ "model": { "provider": "anthropic" }, "ui": { "footer": true } }
    , .{});
    try setPathIn(arena, &tree, "model.model", .{ .string = "claude-sonnet-4" });
    try std.testing.expectEqualStrings("claude-sonnet-4", tree.object.get("model").?.object.get("model").?.string);
    try std.testing.expectEqualStrings("anthropic", tree.object.get("model").?.object.get("provider").?.string);
    try std.testing.expect(tree.object.get("ui").?.object.get("footer").?.bool);

    // A scalar on the path becomes an object rather than failing.
    try setPathIn(arena, &tree, "ui.footer.mode", .{ .bool = false });
    try std.testing.expect(!tree.object.get("ui").?.object.get("footer").?.object.get("mode").?.bool);
}

test "config cli overrides win over the profile at the cli layer" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    const json =
        \\{ "profiles": { "fast": { "model": { "model": "fast-model", "temperature": 0.2 } } } }
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, store.alloc(), json, .{});
    try store.mergeValue(v, .{ .layer = .project, .origin = ".ifnh/config.json" });
    try store.applyProfile("fast");
    try std.testing.expectEqual(@as(f64, 0.2), store.get("model.temperature").?.float);

    try store.applyCliOverrides(&.{
        .{ .path = "model.model", .value = "flag-model", .origin = "--model" },
        .{ .path = "model.temperature", .value = "0.7", .kind = .raw_json, .origin = "--temperature" },
        .{ .path = "ui.footer", .kind = .boolean_false, .origin = "--no-footer" },
    });
    try std.testing.expect(store.errors.items.len == 0);
    try std.testing.expectEqualStrings("flag-model", store.getString("model.model", ""));
    try std.testing.expectEqual(@as(f64, 0.7), store.get("model.temperature").?.float);
    try std.testing.expect(!store.get("ui.footer").?.bool);
    const src = store.getSource("model.model").?;
    try std.testing.expectEqual(Layer.cli, src.layer);
    try std.testing.expectEqualStrings("--model", src.origin);
}

test "config cli override re-validates the merged tree" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyCliOverrides(&.{
        .{ .path = "permissions.default_mode", .value = "sometimes", .origin = "--permission-mode" },
    });
    try std.testing.expectEqual(@as(usize, 1), store.errors.items.len);
    try std.testing.expectEqualStrings("permissions.default_mode", store.errors.items[0].path);
}

test "config warn reports each distinct message once" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.warn("unknown config key '{s}' ignored", .{"a.b"});
    try store.warn("unknown config key '{s}' ignored", .{"a.b"});
    try store.warn("unknown config key '{s}' ignored", .{"c.d"});
    try std.testing.expectEqual(@as(usize, 2), store.warnings.items.len);
}

test "config warnings are reported once across profile and flag re-validation" {
    var store = try Store.init(std.testing.allocator);
    defer store.deinit();
    try store.warn("unknown config key '{s}' ignored", .{"a.b"});
    try std.testing.expectEqual(@as(usize, 1), (try store.newWarnings()).len);

    // Re-validation clears and regenerates the same warning.
    store.warnings.clearRetainingCapacity();
    try store.warn("unknown config key '{s}' ignored", .{"a.b"});
    try std.testing.expectEqual(@as(usize, 0), (try store.newWarnings()).len);

    // A genuinely new warning still shows, once.
    try store.warn("unknown config key '{s}' ignored", .{"c.d"});
    const fresh = try store.newWarnings();
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
    try std.testing.expect(std.mem.indexOf(u8, fresh[0], "c.d") != null);
    try std.testing.expectEqual(@as(usize, 0), (try store.newWarnings()).len);
}

test "config validateFileText rejects bad values and warns on unknown keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try validateFileText(arena, "{ \"permissions\": { \"default_mode\": \"always\" } }");
    try std.testing.expectEqual(@as(usize, 1), bad.errors.len);
    try std.testing.expectEqualStrings("permissions.default_mode", bad.errors[0].path);

    const typo = try validateFileText(arena, "{ \"model\": { \"modle\": \"x\" } }");
    try std.testing.expectEqual(@as(usize, 0), typo.errors.len);
    try std.testing.expect(typo.warnings.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, typo.warnings[0], "model.modle") != null);

    const broken = try validateFileText(arena, "{ not json");
    try std.testing.expectEqual(@as(usize, 1), broken.errors.len);

    const ok = try validateFileText(arena, "{ \"model\": { \"model\": \"m\" } }");
    try std.testing.expectEqual(@as(usize, 0), ok.errors.len);
    try std.testing.expectEqual(@as(usize, 0), ok.warnings.len);
}

/// Concatenated non-test source of every `.zig` file under `src/` (each file is
/// cut at its first top-level `test`, so a key mentioned only by a test does
/// not count as read). Tests run with the project root as cwd.
fn readSourceText(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var all: std.ArrayListUnmanaged(u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.path, arena, .limited(8 * 1024 * 1024));
        var body = text[0 .. std.mem.indexOf(u8, text, "\ntest \"") orelse text.len];
        if (std.mem.eql(u8, entry.path, "core/config/config.zig")) {
            // The wired/unwired bookkeeping lists name every key; they are not readers.
            const from = std.mem.indexOf(u8, body, "pub const wired_defaults") orelse 0;
            const to = std.mem.indexOf(u8, body, "/// `IFNH_*` variables") orelse from;
            try all.appendSlice(arena, body[0..from]);
            body = body[to..];
        }
        try all.appendSlice(arena, body);
    }
    return all.items;
}

/// Append the dotted path of every leaf of `v` (a non-object, or an empty
/// object such as `"aliases": {}`) to `out`.
fn collectLeafPaths(arena: std.mem.Allocator, v: std.json.Value, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    if (v == .object and v.object.count() > 0) {
        var it = v.object.iterator();
        while (it.next()) |e| {
            const path = if (prefix.len == 0) e.key_ptr.* else try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, e.key_ptr.* });
            try collectLeafPaths(arena, e.value_ptr.*, path, out);
        }
        return;
    }
    try out.append(arena, prefix);
}

test "coverage: every key in default_config_json is read somewhere in src" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try readSourceText(arena, std.testing.io);

    const defaults = try std.json.parseFromSliceLeaky(std.json.Value, arena, default_config_json, .{});
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectLeafPaths(arena, defaults, "", &paths);
    try std.testing.expect(paths.items.len > 30);

    var dead: std.ArrayListUnmanaged(u8) = .empty;
    for (paths.items) |path| {
        // A key is read when its dotted path appears as a string literal, or
        // when a sibling-generic reader builds it (`"routing.{s}"`).
        const literal = try std.fmt.allocPrint(arena, "\"{s}\"", .{path});
        if (std.mem.indexOf(u8, source, literal) != null) continue;
        if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
            const generic = try std.fmt.allocPrint(arena, "\"{s}.{{s}}\"", .{path[0..dot]});
            if (std.mem.indexOf(u8, source, generic) != null) continue;
        }
        try dead.print(arena, "\n  dead config key: {s} (in default_config_json, never read in src/)", .{path});
    }
    if (dead.items.len > 0) {
        std.debug.print("{s}\n", .{dead.items});
        return error.DeadConfigKey;
    }
}
