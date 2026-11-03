//! Custom tools as data (D-02, ADR 0004): `<workspace>/.ifnh/tools/*.json`.
//!
//! A custom tool is a shell command template with a name, a description and a
//! JSON Schema for its arguments. Defining one needs no code and no rebuild,
//! so a project can hand the model project-specific verbs (`deploy-staging`,
//! `query-metrics`) as committed data.
//!
//! Loading is fail-soft: a bad file, name or field skips that tool and records
//! a warning (`Set.warnings`); the caller prints the warnings. Nothing here
//! executes anything or touches the terminal.

const std = @import("std");

pub const dir_path = ".ifnh/tools";

pub const max_tools: usize = 64;
pub const max_file_bytes: usize = 64 * 1024;
pub const default_timeout_s: u32 = 60;
pub const max_timeout_s: u32 = 3600;

/// Advisory permission class: it tells the model and future allowlists
/// whether the tool merely reads, writes, or executes. It authorises nothing
/// by itself — enforcement is the command gate plus approval in `tool.zig`.
pub const Permission = enum { read, write, exec };

pub const CustomTool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    command_template: []const u8,
    permission: Permission,
    /// Wall-clock limit for one run; still capped by `agents.timeout_tool_s`.
    timeout_s: u32 = default_timeout_s,
};

/// Builtin tool names, which a custom tool may not shadow, plus the `mcp_`
/// prefix (MCP tools are registered through the same table later, D-03).
/// `tool.zig` asserts at compile time that this list matches its registry, so
/// the two cannot drift.
pub const reserved_names = [_][]const u8{
    "read",             "glob",     "grep",          "edit",            "write",         "bash",
    "skill",            "mcp_list", "mcp_describe",  "mcp_call",        "agent",         "exec",
    "read_tool_result", "git",      "memory_recall", "memory_remember", "memory_forget",
};

pub fn isReserved(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "mcp_")) return true;
    for (reserved_names) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// `^[a-z][a-z0-9_-]{0,63}$`
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn findTool(tools: []const CustomTool, name: []const u8) ?*const CustomTool {
    for (tools) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

pub const Set = struct {
    /// Loaded definitions in load order (filename order, then file order).
    tools: []const CustomTool = &.{},
    /// Human-readable "warning: ..." lines; the caller decides where they go.
    warnings: []const []const u8 = &.{},

    pub fn find(self: Set, name: []const u8) ?*const CustomTool {
        return findTool(self.tools, name);
    }

    /// Load every `<workspace>/.ifnh/tools/*.json` (non-recursive, filename
    /// sorted). `enabled` is `tools.external`: false loads nothing.
    ///
    /// Deviation from the D-02 sketch: `io` is a parameter, because a
    /// `std.Io.Dir` in Zig 0.16 can only be read through an explicit `std.Io`.
    pub fn load(arena: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, enabled: bool) Set {
        var tools: std.ArrayListUnmanaged(CustomTool) = .empty;
        var warnings: std.ArrayListUnmanaged([]const u8) = .empty;
        if (!enabled) {
            warn(arena, &warnings, "tools.external is false; custom tools in " ++ dir_path ++ " are not loaded", .{});
            return .{ .tools = &.{}, .warnings = warnings.items };
        }

        var dir = workspace.openDir(io, dir_path, .{ .iterate = true }) catch
            return .{ .tools = &.{}, .warnings = warnings.items };
        defer dir.close(io);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            names.append(arena, arena.dupe(u8, entry.name) catch continue) catch continue;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        // Set when a tool beyond `max_tools` is seen, not when the cap is reached.
        var over_cap = false;
        for (names.items) |name| {
            const label = std.fmt.allocPrint(arena, dir_path ++ "/{s}", .{name}) catch name;
            if (over_cap) break;
            const text = dir.readFileAlloc(io, name, arena, .limited(max_file_bytes)) catch |err| {
                switch (err) {
                    error.StreamTooLong => warn(arena, &warnings, "{s}: larger than {d} bytes; skipped", .{ label, max_file_bytes }),
                    error.FileNotFound => {},
                    else => warn(arena, &warnings, "{s}: cannot be read ({s}); skipped", .{ label, @errorName(err) }),
                }
                continue;
            };
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
                warn(arena, &warnings, "{s}: invalid JSON; skipped", .{label});
                continue;
            };
            switch (parsed) {
                .object => if (tools.items.len >= max_tools) {
                    over_cap = true;
                } else parseOne(arena, label, parsed, &tools, &warnings),
                .array => |items| {
                    for (items.items) |item| {
                        if (tools.items.len >= max_tools) {
                            over_cap = true;
                            break;
                        }
                        parseOne(arena, label, item, &tools, &warnings);
                    }
                },
                else => warn(arena, &warnings, "{s}: expected a tool object or an array of them; skipped", .{label}),
            }
        }
        if (over_cap) warn(arena, &warnings, "more than {d} custom tools defined; the rest were ignored", .{max_tools});
        return .{ .tools = tools.items, .warnings = warnings.items };
    }
};

fn warn(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, "warning: " ++ fmt ++ "\n", args) catch return;
    out.append(arena, msg) catch {};
}

/// Validate one tool object and append it, or warn and skip it. Never fails.
fn parseOne(
    arena: std.mem.Allocator,
    label: []const u8,
    value: std.json.Value,
    tools: *std.ArrayListUnmanaged(CustomTool),
    warnings: *std.ArrayListUnmanaged([]const u8),
) void {
    if (value != .object) {
        warn(arena, warnings, "{s}: tool definition must be a JSON object; skipped", .{label});
        return;
    }
    const obj = value.object;

    const name_v = obj.get("name") orelse {
        warn(arena, warnings, "{s}: missing \"name\"; skipped", .{label});
        return;
    };
    if (name_v != .string or !validName(name_v.string)) {
        warn(arena, warnings, "{s}: invalid \"name\" (want ^[a-z][a-z0-9_-]{{0,63}}$); skipped", .{label});
        return;
    }
    const name = name_v.string;
    if (isReserved(name)) {
        warn(arena, warnings, "{s}: name '{s}' collides with a builtin tool; skipped", .{ label, name });
        return;
    }
    if (findTool(tools.items, name) != null) {
        warn(arena, warnings, "{s}: duplicate tool '{s}' (the first definition wins); skipped", .{ label, name });
        return;
    }

    const description = requiredString(obj, "description") orelse {
        warn(arena, warnings, "{s}: tool '{s}' is missing a \"description\"; skipped", .{ label, name });
        return;
    };
    const command = requiredString(obj, "command") orelse {
        warn(arena, warnings, "{s}: tool '{s}' is missing a \"command\"; skipped", .{ label, name });
        return;
    };
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
        warn(arena, warnings, "{s}: tool '{s}' has an empty \"command\"; skipped", .{ label, name });
        return;
    }
    const parameters = obj.get("parameters") orelse {
        warn(arena, warnings, "{s}: tool '{s}' is missing \"parameters\"; skipped", .{ label, name });
        return;
    };
    if (parameters != .object) {
        warn(arena, warnings, "{s}: tool '{s}' has non-object \"parameters\"; skipped", .{ label, name });
        return;
    }
    const perm_v = obj.get("permission") orelse {
        warn(arena, warnings, "{s}: tool '{s}' is missing \"permission\"; skipped", .{ label, name });
        return;
    };
    const permission: Permission = blk: {
        if (perm_v == .string) {
            if (std.mem.eql(u8, perm_v.string, "read")) break :blk .read;
            if (std.mem.eql(u8, perm_v.string, "write")) break :blk .write;
            if (std.mem.eql(u8, perm_v.string, "exec")) break :blk .exec;
        }
        warn(arena, warnings, "{s}: tool '{s}' has \"permission\" other than read|write|exec; skipped", .{ label, name });
        return;
    };
    var timeout_s: u32 = default_timeout_s;
    if (obj.get("timeout_s")) |tv| {
        const n: i64 = switch (tv) {
            .integer => |i| i,
            else => 0,
        };
        if (n < 1 or n > max_timeout_s) {
            warn(arena, warnings, "{s}: tool '{s}' has \"timeout_s\" outside 1..{d}; skipped", .{ label, name, max_timeout_s });
            return;
        }
        timeout_s = @intCast(n);
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(parameters, .{}, &aw.writer) catch {
        warn(arena, warnings, "{s}: tool '{s}' has unusable \"parameters\"; skipped", .{ label, name });
        return;
    };
    tools.append(arena, .{
        .name = name,
        .description = description,
        .parameters_json = aw.written(),
        .command_template = command,
        .permission = permission,
        .timeout_s = timeout_s,
    }) catch {};
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Rendered command, or a ready-to-return `error: custom tool ...` message.
pub const RenderResult = union(enum) { command: []const u8, err: []const u8 };

const Renderer = struct {
    arena: std.mem.Allocator,
    name: []const u8,
    out: std.ArrayListUnmanaged(u8) = .empty,

    fn fail(self: *Renderer, comptime fmt: []const u8, args: anytype) RenderResult {
        const detail = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        const msg = std.fmt.allocPrint(self.arena, "error: custom tool '{s}': {s}", .{ self.name, detail }) catch
            "error: custom tool: invalid arguments";
        return .{ .err = msg };
    }

    fn put(self: *Renderer, text: []const u8) bool {
        self.out.appendSlice(self.arena, text) catch return false;
        return true;
    }
};

/// Substitute `{key}` placeholders in the command template.
///
/// Every value is shell-quoted (`'` -> `'\''`) and wrapped in single quotes,
/// so an argument can never break out of the command. `{{` and `}}` are
/// literal braces. A missing key, an unclosed brace, a stray `}` or a
/// non-scalar argument is an error.
pub fn render(arena: std.mem.Allocator, tool: CustomTool, args: std.json.ObjectMap) RenderResult {
    var r = Renderer{ .arena = arena, .name = tool.name };
    const tpl = tool.command_template;
    var i: usize = 0;
    while (i < tpl.len) {
        const c = tpl[i];
        if (c == '{') {
            if (i + 1 < tpl.len and tpl[i + 1] == '{') {
                if (!r.put("{")) return oom(&r);
                i += 2;
                continue;
            }
            const close = std.mem.findScalarPos(u8, tpl, i + 1, '}') orelse
                return r.fail("unclosed '{{' in the command template", .{});
            const key = tpl[i + 1 .. close];
            if (key.len == 0) return r.fail("empty placeholder '{{}}' in the command template", .{});
            const v = args.get(key) orelse
                return r.fail("argument '{s}' is required by the command template and was not provided", .{key});
            const text = switch (v) {
                .string => |s| s,
                .integer => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch return oom(&r),
                .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}) catch return oom(&r),
                .bool => |b| (if (b) "true" else "false"),
                .null => return r.fail("argument '{s}' is null; a string, number or boolean is required", .{key}),
                .number_string => |s| s,
                .object, .array => return r.fail("argument '{s}' must be a string, number or boolean", .{key}),
            };
            if (!r.put("'")) return oom(&r);
            for (text) |ch| {
                if (ch == '\'') {
                    if (!r.put("'\\''")) return oom(&r);
                } else {
                    if (r.out.append(arena, ch)) |_| {} else |_| return oom(&r);
                }
            }
            if (!r.put("'")) return oom(&r);
            i = close + 1;
        } else if (c == '}') {
            if (i + 1 < tpl.len and tpl[i + 1] == '}') {
                if (!r.put("}")) return oom(&r);
                i += 2;
                continue;
            }
            return r.fail("stray '}}' in the command template (use '}}}}' for a literal brace)", .{});
        } else {
            if (r.out.append(arena, c)) |_| {} else |_| return oom(&r);
            i += 1;
        }
    }
    return .{ .command = r.out.items };
}

fn oom(r: *Renderer) RenderResult {
    const msg = std.fmt.allocPrint(r.arena, "error: custom tool '{s}': out of memory", .{r.name}) catch
        "error: custom tool: out of memory";
    return .{ .err = msg };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn writeToolFile(workspace: std.Io.Dir, io: std.Io, name: []const u8, body: []const u8) !void {
    workspace.createDirPath(io, dir_path) catch {};
    const path = try std.fmt.allocPrint(testing.allocator, dir_path ++ "/{s}", .{name});
    defer testing.allocator.free(path);
    try workspace.writeFile(io, .{ .sub_path = path, .data = body });
}

fn testArgs(arena: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (v != .object) return error.NotAnObject;
    return v.object;
}

fn expectRender(arena: std.mem.Allocator, tool: CustomTool, json: []const u8, want: []const u8) !void {
    const args = try testArgs(arena, json);
    switch (render(arena, tool, args)) {
        .command => |c| try testing.expectEqualStrings(want, c),
        .err => |e| {
            std.debug.print("render failed: {s}\n", .{e});
            return error.UnexpectedRenderError;
        },
    }
}

fn expectRenderError(arena: std.mem.Allocator, tool: CustomTool, json: []const u8, needle: []const u8) !void {
    const args = try testArgs(arena, json);
    switch (render(arena, tool, args)) {
        .command => |c| {
            std.debug.print("unexpected command: {s}\n", .{c});
            return error.ExpectedRenderError;
        },
        .err => |e| {
            try testing.expect(std.mem.startsWith(u8, e, "error: custom tool '"));
            try testing.expect(std.mem.indexOf(u8, e, needle) != null);
        },
    }
}

fn writeManyTools(arena: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, n: usize) !void {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.append(arena, '[');
    for (0..n) |i| {
        if (i != 0) try body.append(arena, ',');
        try body.print(arena, "{{\"name\":\"t{d}\",\"description\":\"d\",\"parameters\":{{\"type\":\"object\"}},\"command\":\"true\",\"permission\":\"read\"}}", .{i});
    }
    try body.append(arena, ']');
    try writeToolFile(dir, io, "many.json", body.items);
}

test "custom tools: cap warns only past max_tools, not at it" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var at = testing.tmpDir(.{});
    defer at.cleanup();
    try writeManyTools(arena, at.dir, io, max_tools);
    const set_at = Set.load(arena, io, at.dir, true);
    try testing.expectEqual(max_tools, set_at.tools.len);
    try testing.expectEqual(@as(usize, 0), set_at.warnings.len);

    var over = testing.tmpDir(.{});
    defer over.cleanup();
    try writeManyTools(arena, over.dir, io, max_tools + 1);
    const set_over = Set.load(arena, io, over.dir, true);
    try testing.expectEqual(max_tools, set_over.tools.len);
    try testing.expectEqual(@as(usize, 1), set_over.warnings.len);
    try testing.expect(std.mem.indexOf(u8, set_over.warnings[0], "more than 64") != null);
}

test "custom tools: loads a single file and an array file in filename order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeToolFile(tmp.dir, io, "b-two.json",
        \\[{"name":"second","description":"second tool","parameters":{"type":"object"},
        \\  "command":"echo two","permission":"read"},
        \\ {"name":"third","description":"third tool","parameters":{"type":"object","properties":{}},
        \\  "command":"echo three {n}","permission":"exec","timeout_s":30}]
    );
    try writeToolFile(tmp.dir, io, "a-one.json",
        \\{"name":"deploy-staging","description":"Deploy to staging","parameters":
        \\  {"type":"object","properties":{"env":{"type":"string"}},"required":["env"]},
        \\ "command":"scripts/deploy.sh --env {env}","permission":"write","timeout_s":120}
    );
    // Not a tool definition: ignored, not a warning.
    try tmp.dir.writeFile(io, .{ .sub_path = dir_path ++ "/notes.txt", .data = "hello" });

    const set = Set.load(arena, io, tmp.dir, true);
    try testing.expectEqual(@as(usize, 0), set.warnings.len);
    try testing.expectEqual(@as(usize, 3), set.tools.len);

    const first = set.tools[0];
    try testing.expectEqualStrings("deploy-staging", first.name);
    try testing.expectEqualStrings("Deploy to staging", first.description);
    try testing.expectEqualStrings("scripts/deploy.sh --env {env}", first.command_template);
    try testing.expectEqual(Permission.write, first.permission);
    try testing.expectEqual(@as(u32, 120), first.timeout_s);
    // parameters is carried through as JSON text for the model.
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena, first.parameters_json, .{});
    try testing.expect(params == .object);
    try testing.expect(params.object.get("properties") != null);

    try testing.expectEqualStrings("second", set.tools[1].name);
    try testing.expectEqual(@as(u32, default_timeout_s), set.tools[1].timeout_s);
    try testing.expectEqualStrings("third", set.tools[2].name);
    try testing.expectEqual(Permission.exec, set.tools[2].permission);

    try testing.expect(set.find("deploy-staging") != null);
    try testing.expect(set.find("nope") == null);
}

test "custom tools: malformed files and bad fields are skipped with warnings" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeToolFile(tmp.dir, io, "bad-json.json", "{ not json");
    try writeToolFile(tmp.dir, io, "bad-name.json",
        \\{"name":"Deploy Staging","description":"d","parameters":{"type":"object"},"command":"x","permission":"exec"}
    );
    try writeToolFile(tmp.dir, io, "missing-field.json",
        \\{"name":"no-command","description":"d","parameters":{"type":"object"},"permission":"exec"}
    );
    try writeToolFile(tmp.dir, io, "bad-permission.json",
        \\{"name":"bad-perm","description":"d","parameters":{"type":"object"},"command":"x","permission":"root"}
    );
    try writeToolFile(tmp.dir, io, "bad-timeout.json",
        \\{"name":"bad-timeout","description":"d","parameters":{"type":"object"},"command":"x","permission":"exec","timeout_s":99999}
    );
    try writeToolFile(tmp.dir, io, "ok.json",
        \\{"name":"good","description":"d","parameters":{"type":"object"},"command":"true","permission":"read"}
    );

    const set = Set.load(arena, io, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), set.tools.len);
    try testing.expectEqualStrings("good", set.tools[0].name);
    try testing.expectEqual(@as(usize, 5), set.warnings.len);
    for (set.warnings) |w| {
        try testing.expect(std.mem.startsWith(u8, w, "warning: " ++ dir_path ++ "/"));
    }
}

test "custom tools: builtin, mcp_ and duplicate names are skipped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeToolFile(tmp.dir, io, "a.json",
        \\[{"name":"read","description":"shadow","parameters":{"type":"object"},"command":"x","permission":"read"},
        \\ {"name":"mcp_evil","description":"shadow","parameters":{"type":"object"},"command":"x","permission":"exec"},
        \\ {"name":"agent","description":"shadow","parameters":{"type":"object"},"command":"x","permission":"exec"},
        \\ {"name":"dup","description":"first","parameters":{"type":"object"},"command":"echo first","permission":"read"}]
    );
    try writeToolFile(tmp.dir, io, "b.json",
        \\{"name":"dup","description":"second","parameters":{"type":"object"},"command":"echo second","permission":"read"}
    );

    const set = Set.load(arena, io, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), set.tools.len);
    try testing.expectEqualStrings("dup", set.tools[0].name);
    try testing.expectEqualStrings("first", set.tools[0].description); // first wins
    try testing.expectEqual(@as(usize, 4), set.warnings.len);
    var saw_collision = false;
    var saw_duplicate = false;
    for (set.warnings) |w| {
        if (std.mem.indexOf(u8, w, "collides with a builtin") != null) saw_collision = true;
        if (std.mem.indexOf(u8, w, "duplicate tool 'dup'") != null) saw_duplicate = true;
    }
    try testing.expect(saw_collision);
    try testing.expect(saw_duplicate);
}

test "custom tools: tools.external false loads nothing and warns once" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeToolFile(tmp.dir, io, "ok.json",
        \\{"name":"good","description":"d","parameters":{"type":"object"},"command":"true","permission":"read"}
    );

    const set = Set.load(arena, io, tmp.dir, false);
    try testing.expectEqual(@as(usize, 0), set.tools.len);
    try testing.expectEqual(@as(usize, 1), set.warnings.len);
    try testing.expect(std.mem.indexOf(u8, set.warnings[0], "tools.external is false") != null);
    try testing.expect(set.find("good") == null);
}

test "custom tools: missing directory is not a warning" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const set = Set.load(arena_state.allocator(), io, tmp.dir, true);
    try testing.expectEqual(@as(usize, 0), set.tools.len);
    try testing.expectEqual(@as(usize, 0), set.warnings.len);
}

test "custom tools: render quotes every substituted value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tool = CustomTool{
        .name = "deploy",
        .description = "d",
        .parameters_json = "{}",
        .command_template = "scripts/deploy.sh --env {env} --retries {n} --dry {flag}",
        .permission = .exec,
    };
    try expectRender(arena, tool, "{\"env\":\"staging\",\"n\":3,\"flag\":true}", "scripts/deploy.sh --env 'staging' --retries '3' --dry 'true'");
    // A shell-injection payload stays one quoted word.
    try expectRender(arena, tool, "{\"env\":\"a; rm -rf / #'\",\"n\":1,\"flag\":false}", "scripts/deploy.sh --env 'a; rm -rf / #'\\''' --retries '1' --dry 'false'");
    // Literal braces escape.
    const braced = CustomTool{
        .name = "braces",
        .description = "d",
        .parameters_json = "{}",
        .command_template = "echo {{literal}} {msg}",
        .permission = .exec,
    };
    try expectRender(arena, braced, "{\"msg\":\"hi\"}", "echo {literal} 'hi'");
}

test "custom tools: render rejects bad placeholders and arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tool = CustomTool{
        .name = "deploy",
        .description = "d",
        .parameters_json = "{}",
        .command_template = "run {env} {missing}",
        .permission = .exec,
    };
    // Placeholder key absent from the arguments.
    try expectRenderError(arena, tool, "{\"env\":\"x\"}", "argument 'missing'");
    // Object/array arguments are not shell scalars.
    try expectRenderError(arena, tool, "{\"env\":{\"a\":1},\"missing\":1}", "must be a string, number or boolean");
    try expectRenderError(arena, tool, "{\"env\":[1],\"missing\":1}", "must be a string, number or boolean");

    const unclosed = CustomTool{
        .name = "unclosed",
        .description = "d",
        .parameters_json = "{}",
        .command_template = "echo {env",
        .permission = .exec,
    };
    try expectRenderError(arena, unclosed, "{\"env\":\"x\"}", "unclosed");
    const stray = CustomTool{
        .name = "stray",
        .description = "d",
        .parameters_json = "{}",
        .command_template = "echo } {env}",
        .permission = .exec,
    };
    try expectRenderError(arena, stray, "{\"env\":\"x\"}", "stray");
}
