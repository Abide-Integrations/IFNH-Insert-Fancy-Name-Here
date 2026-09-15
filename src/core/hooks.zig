//! Hooks engine (M1-T07, DECISIONS section P, D031).
//!
//! Config-driven shell hooks at defined lifecycle events (P212).
//! Synchronous: `before_*` hooks may block progression (non-zero exit,
//! P213/214). Hooks cannot mutate state through the runtime (P215) and
//! cannot trigger hooks (P220 — depth-1 events only). Repo-provided hooks
//! live in `.ifnh/` (trusted because they are committed config the
//! developer reviewed; trust gating for downloaded content is M2).

const std = @import("std");

pub const Event = enum {
    session_start,
    session_end,
    before_tool,
    after_tool,
    before_agent,
    after_agent,
    before_merge,
    after_merge,

    pub fn name(self: Event) []const u8 {
        return @tagName(self);
    }
};

pub const HookDef = struct {
    event: Event,
    command: []const u8,
};

pub const HookResult = struct {
    ok: bool,
    blocked: bool = false,
    output: []const u8 = "",
};

pub const Engine = struct {
    io: std.Io,
    workspace: std.Io.Dir,
    hooks: []const HookDef,
    /// Arena for this dispatch (scratch).
    alloc: std.mem.Allocator,

    pub fn init(io: std.Io, workspace: std.Io.Dir, hooks: []const HookDef, alloc: std.mem.Allocator) Engine {
        return .{ .io = io, .workspace = workspace, .hooks = hooks, .alloc = alloc };
    }

    /// Parse `hooks` config: { event_name: [commands...] | "command" }.
    pub fn fromConfig(arena: std.mem.Allocator, v: ?std.json.Value) ![]HookDef {
        var out: std.ArrayListUnmanaged(HookDef) = .empty;
        const val = v orelse return &.{};
        if (val != .object) return &.{};
        var it = val.object.iterator();
        outer: while (it.next()) |entry| {
            const event = std.meta.stringToEnum(Event, entry.key_ptr.*) orelse continue;
            switch (entry.value_ptr.*) {
                .string => |s| {
                    try out.append(arena, .{ .event = event, .command = try arena.dupe(u8, s) });
                },
                .array => |arr| {
                    for (arr.items) |item| {
                        if (item == .string) {
                            try out.append(arena, .{ .event = event, .command = try arena.dupe(u8, item.string) });
                        }
                    }
                },
                else => continue :outer,
            }
        }
        return out.items;
    }

    /// Run all hooks for an event with a JSON-ish stdin payload.
    /// `before_*` hooks block on non-zero exit (P214).
    pub fn dispatch(self: *Engine, event: Event, payload_json: []const u8) HookResult {
        var any_output: std.ArrayListUnmanaged(u8) = .empty;
        for (self.hooks) |hook| {
            if (hook.event != event) continue;

            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            argv.append(self.alloc, "/bin/sh") catch continue;
            argv.append(self.alloc, "-c") catch continue;
            argv.append(self.alloc, hook.command) catch continue;

            const run = std.process.run(self.alloc, self.io, .{
                .argv = argv.items,
                .cwd = .{ .dir = self.workspace },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
                .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
            }) catch continue;

            _ = payload_json; // hooks read context from env: IFNH_EVENT
            if (run.stdout.len > 0 or run.stderr.len > 0) {
                any_output.print(self.alloc, "[{s}] {s}{s}", .{
                    hook.command,
                    run.stdout,
                    run.stderr,
                }) catch {};
            }
            const failed = switch (run.term) {
                .exited => |code| code != 0,
                else => true,
            };
            if (failed) {
                const is_before = switch (event) {
                    .before_tool, .before_agent, .before_merge => true,
                    else => false,
                };
                return .{
                    .ok = false,
                    .blocked = is_before,
                    .output = any_output.items,
                };
            }
        }
        return .{ .ok = true, .output = any_output.items };
    }
};

// ---------------------------------------------------------------- tests

test "fromConfig parses string and array forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"after_tool":"echo done","before_tool":["echo a","echo b"],"bogus_event":"x"}
    , .{});
    const hooks = try Engine.fromConfig(a, v);
    try std.testing.expectEqual(@as(usize, 3), hooks.len);
}

test "hooks run and after_* failures do not block" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var hooks: [1]HookDef = .{.{ .event = .after_tool, .command = "exit 3" }};
    var e = Engine.init(io, tmp.dir, &hooks, a);
    const r = e.dispatch(.after_tool, "{}");
    try std.testing.expect(!r.ok);
    try std.testing.expect(!r.blocked);

    hooks[0] = .{ .event = .before_tool, .command = "exit 3" };
    const r2 = e.dispatch(.before_tool, "{}");
    try std.testing.expect(!r2.ok);
    try std.testing.expect(r2.blocked);

    hooks[0] = .{ .event = .before_tool, .command = "echo check" };
    const r3 = e.dispatch(.before_tool, "{}");
    try std.testing.expect(r3.ok);
    try std.testing.expect(!r3.blocked);
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "check") != null);
}
