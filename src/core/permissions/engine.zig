//! Permission engine (DESIGN §3.3, DECISIONS section H).
//!
//! Model: tool+path+command rules with deny > allow > default evaluation.
//! Fail-closed: unknown/destructive actions ask; protected policy paths
//! always deny agent writes; malformed rules are a startup error, not a
//! silent bypass. Decisions are pure functions of engine state.

const std = @import("std");
const globm = @import("glob.zig");
const cmd_class = @import("command_class.zig");

pub const Decision = enum { allow, ask, deny };
pub const Mode = enum { ask, auto };
pub const Access = enum { read, write };

pub const Request = union(enum) {
    path: struct { access: Access, path: []const u8 },
    command: struct { command: []const u8 },
    env: struct { name: []const u8 },
};

pub const GrantScope = enum { once, session, pattern };

pub const GrantKind = enum { command_prefix, path_write_glob };

pub const Grant = struct {
    kind: GrantKind,
    pattern: []const u8,
    scope: GrantScope,
};

/// Policy paths agents may never write (DECISIONS H119/G99): harness
/// configuration, instructions, and lifecycle definitions.
const protected_paths = [_][]const u8{
    ".ifnh/config.json",
    ".ifnh/config.d/",
    ".ifnh/lifecycle/",
    ".ifnh/instructions/",
    ".ifnh/commands/",
    ".ifnh/skills/",
    "AGENTS.md",
    "CLAUDE.md",
};

pub const Engine = struct {
    mode: Mode = .ask,
    read_globs: []const []const u8 = &.{"**"},
    write_globs: []const []const u8 = &.{},
    command_allow: []const []const u8 = &.{},
    command_deny: []const []const u8 = &.{},
    env_allow: []const []const u8 = &.{},
    /// Session grants accumulated from approvals. `alloc` is the engine's
    /// arena (Grant patterns are duped into it).
    grants: std.ArrayListUnmanaged(Grant) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, mode: Mode) Engine {
        return .{ .alloc = alloc, .mode = mode };
    }

    /// Frees grant storage. Only valid when `alloc` is not an arena.
    pub fn deinit(self: *Engine) void {
        for (self.grants.items) |g| self.alloc.free(g.pattern);
        self.grants.deinit(self.alloc);
    }

    pub fn decide(self: *Engine, req: Request) Decision {
        return switch (req) {
            .path => |p| self.decidePath(p.access, p.path),
            .command => |c| self.decideCommand(c.command),
            .env => |e| self.decideEnv(e.name),
        };
    }

    pub fn decidePath(self: *Engine, access: Access, path: []const u8) Decision {
        const norm = stripDotSlash(path);
        if (access == .write) {
            if (isProtectedPath(norm)) return .deny;
            for (self.write_globs) |g| {
                if (globm.match(g, norm)) return .allow;
            }
            if (self.matchGrant(.path_write_glob, norm)) return .allow;
            return .ask;
        }
        // Reads.
        for (self.read_globs) |g| {
            if (globm.match(g, norm)) return .allow;
        }
        return .ask;
    }

    pub fn decideCommand(self: *Engine, command: []const u8) Decision {
        const trimmed = std.mem.trim(u8, command, " \t\n\r");
        for (self.command_deny) |d| {
            if (prefixMatch(d, trimmed)) return .deny;
        }
        const effect = cmd_class.classify(trimmed);
        switch (effect) {
            .read_only => return .allow,
            .destructive => return .ask, // never auto-allowed (H105)
            .write, .unknown => {
                for (self.command_allow) |a| {
                    if (prefixMatch(a, trimmed)) return .allow;
                }
                if (self.matchGrant(.command_prefix, trimmed)) return .allow;
                return .ask;
            },
        }
    }

    pub fn decideEnv(self: *Engine, name: []const u8) Decision {
        for (self.env_allow) |a| {
            if (std.mem.eql(u8, a, name)) return .allow;
        }
        return .deny;
    }

    fn matchGrant(self: *Engine, kind: GrantKind, target: []const u8) bool {
        for (self.grants.items) |*g| {
            if (g.kind != kind) continue;
            const hit = switch (kind) {
                .command_prefix => prefixMatch(g.pattern, target),
                .path_write_glob => globm.match(g.pattern, target),
            };
            if (!hit) continue;
            switch (g.scope) {
                .once => {
                    // Consume: free pattern and remove this grant.
                    const idx = self.indexOfGrant(g) orelse continue;
                    self.alloc.free(self.grants.items[idx].pattern);
                    _ = self.grants.orderedRemove(idx);
                },
                else => {},
            }
            return true;
        }
        return false;
    }

    fn indexOfGrant(self: *Engine, g: *const Grant) ?usize {
        for (self.grants.items, 0..) |item, i| {
            if (item.pattern.ptr == g.pattern.ptr and item.pattern.len == g.pattern.len) return i;
        }
        return null;
    }

    /// Record an approval grant (DECISIONS H112). Patterns are duped.
    pub fn addGrant(self: *Engine, grant: Grant) !void {
        try self.grants.append(self.alloc, .{
            .kind = grant.kind,
            .pattern = try self.alloc.dupe(u8, grant.pattern),
            .scope = grant.scope,
        });
    }

    pub fn commandPrefixGrant(self: *Engine, prefix: []const u8, scope: GrantScope) !void {
        try self.addGrant(.{ .kind = .command_prefix, .pattern = prefix, .scope = scope });
    }

    pub fn pathWriteGrant(self: *Engine, glob: []const u8, scope: GrantScope) !void {
        try self.addGrant(.{ .kind = .path_write_glob, .pattern = glob, .scope = scope });
    }
};

fn stripDotSlash(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '.' and s[1] == '/') return s[2..];
    return s;
}

fn prefixMatch(prefix: []const u8, target: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, " ");
    if (p.len == 0) return false;
    return std.mem.startsWith(u8, target, p) and
        (target.len == p.len or target[p.len] == ' ' or target[p.len] == '\t');
}

fn isProtectedPath(path: []const u8) bool {
    for (protected_paths) |pp| {
        const has_slash = pp[pp.len - 1] == '/';
        if (has_slash) {
            if (std.mem.startsWith(u8, path, pp)) return true;
        } else {
            if (std.mem.eql(u8, path, pp)) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

test "path reads allowed by read globs" {
    var e = Engine.init(t.allocator, .ask);
    defer e.deinit();
    try t.expectEqual(Decision.allow, e.decidePath(.read, "src/main.zig"));
    try t.expectEqual(Decision.deny, e.decide(.{ .env = .{ .name = "SECRET" } }));
}

test "path writes ask by default, deny for protected policy paths" {
    var e = Engine.init(t.allocator, .ask);
    defer e.deinit();
    try t.expectEqual(Decision.ask, e.decidePath(.write, "src/main.zig"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, ".ifnh/config.json"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, ".ifnh/config.d/extra.json"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, ".ifnh/lifecycle/default.json"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, "AGENTS.md"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, "./AGENTS.md"));
    // Sessions are not protected.
    try t.expectEqual(Decision.ask, e.decidePath(.write, ".ifnh/sessions/s_x/events.jsonl"));
}

test "write globs allow matching paths" {
    var e = Engine.init(t.allocator, .auto);
    defer e.deinit();
    e.write_globs = &.{"src/**"};
    try t.expectEqual(Decision.allow, e.decidePath(.write, "src/core/x.zig"));
    try t.expectEqual(Decision.ask, e.decidePath(.write, "docs/x.md"));
    try t.expectEqual(Decision.deny, e.decidePath(.write, ".ifnh/config.json")); // protection outranks globs
}

test "command decisions by effect" {
    var e = Engine.init(t.allocator, .ask);
    defer e.deinit();
    try t.expectEqual(Decision.allow, e.decideCommand("ls -la"));
    try t.expectEqual(Decision.allow, e.decideCommand("git status"));
    try t.expectEqual(Decision.ask, e.decideCommand("mkdir build"));
    try t.expectEqual(Decision.ask, e.decideCommand("rm -rf build")); // destructive always asks
    try t.expectEqual(Decision.ask, e.decideCommand("git push --force origin main")); // destructive asks; git ceiling enforced at tool layer

    e.command_deny = &.{"cargo"};
    try t.expectEqual(Decision.deny, e.decideCommand("cargo build"));

    e.command_allow = &.{"zig build"};
    try t.expectEqual(Decision.allow, e.decideCommand("zig build test"));
    try t.expectEqual(Decision.ask, e.decideCommand("zig buildx")); // word boundary respected
}

test "grants: session scope persists, once is consumed" {
    var e = Engine.init(t.allocator, .ask);
    defer e.deinit();
    try e.commandPrefixGrant("npm test", .session);
    try t.expectEqual(Decision.allow, e.decideCommand("npm test -- --watch"));
    try t.expectEqual(Decision.allow, e.decideCommand("npm test"));
    try t.expectEqual(Decision.ask, e.decideCommand("npm run other"));

    try e.commandPrefixGrant("make check", .once);
    try t.expectEqual(Decision.allow, e.decideCommand("make check"));
    try t.expectEqual(Decision.ask, e.decideCommand("make check")); // consumed

    try e.pathWriteGrant("docs/**", .session);
    try t.expectEqual(Decision.allow, e.decidePath(.write, "docs/a.md"));
    try t.expectEqual(Decision.ask, e.decidePath(.write, "docs2/a.md"));
}

test "env vars deny unless allowlisted" {
    var e = Engine.init(t.allocator, .ask);
    defer e.deinit();
    e.env_allow = &.{"ANTHROPIC_API_KEY"};
    try t.expectEqual(Decision.allow, e.decide(.{ .env = .{ .name = "ANTHROPIC_API_KEY" } }));
    try t.expectEqual(Decision.deny, e.decide(.{ .env = .{ .name = "AWS_SECRET_KEY" } }));
}
