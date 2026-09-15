//! Skills: SKILL.md catalog, discovery, and injection (M1-T06,
//! DECISIONS section K, D016/D018).
//!
//! Format: Agent Skills SKILL.md — YAML-ish frontmatter (name,
//! description) + Markdown body (K147). Missing frontmatter tolerates the
//! directory basename (fx skill_contract semantics). Discovery roots:
//! user ~/.config/ifnh/skills, project .ifnh/skills, plus read-only
//! compat roots .claude/skills and .agents/skills (K148). Project
//! overrides user on name collision (K149). Skills never grant
//! permissions (K153).

const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const max_skill_bytes: usize = 256 * 1024;
pub const max_catalog_bytes: usize = 16 * 1024;

pub const Skill = struct {
    name: []const u8,
    description: []const u8 = "",
    path: []const u8, // repo-relative or absolute (user scope)
    scope: []const u8, // "project" | "user" | "compat"
};

pub const Catalog = struct {
    skills: []Skill,
    omitted: usize = 0,
};

pub const Parsed = struct {
    name: []const u8,
    description: []const u8,
    body: []const u8,
};

/// Parse a SKILL.md: optional `---` frontmatter with name/description
/// keys, then the body. Malformed frontmatter falls back to basename.
pub fn parseSkillFile(arena: std.mem.Allocator, content: []const u8, fallback_name: []const u8) !Parsed {
    var body = content;
    var name: ?[]const u8 = null;
    var description: []const u8 = "";

    if (std.mem.startsWith(u8, body, "---")) {
        if (std.mem.indexOfPos(u8, body, 3, "\n---")) |end| {
            const fm = body[3..end];
            body = body[end + 4 ..];
            if (body.len > 0 and body[0] == '\n') body = body[1..];
            var it = std.mem.splitScalar(u8, fm, '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len == 0) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const key = std.mem.trim(u8, line[0..colon], " ");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \"'\t\r");
                if (std.mem.eql(u8, key, "name")) {
                    name = try arena.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "description")) {
                    description = try arena.dupe(u8, value);
                }
                // Unknown frontmatter keys tolerated (forward-compat).
            }
        }
    }

    return .{
        .name = name orelse try arena.dupe(u8, fallback_name),
        .description = description,
        .body = body,
    };
}

const RootSpec = struct {
    rel: []const u8,
    scope: []const u8,
    /// Compat roots are read-only and lower precedence.
    compat: bool = false,
};

const project_roots = [_]RootSpec{
    .{ .rel = ".ifnh/skills", .scope = "project" },
    .{ .rel = ".claude/skills", .scope = "compat", .compat = true },
    .{ .rel = ".agents/skills", .scope = "compat", .compat = true },
};

/// Discover skills for `workspace`. Project scope overrides user on name
/// collision; entries are deduped by canonical name.
pub fn discover(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, user_skills_dir: ?[]const u8) !Catalog {
    var out: std.ArrayListUnmanaged(Skill) = .empty;

    // User scope first (lowest precedence).
    if (user_skills_dir) |ud| {
        collectRoot(workspace, io, arena, ud, "user", &out, true) catch {};
    }
    // Project scope (overrides user by name).
    for (project_roots) |root| {
        collectRoot(workspace, io, arena, root.rel, root.scope, &out, root.compat) catch {};
    }

    // Name-collision resolution: later entries (project) win.
    var deduped: std.ArrayListUnmanaged(Skill) = .empty;
    for (out.items) |s| {
        var replaced = false;
        for (deduped.items) |*d| {
            if (std.mem.eql(u8, d.name, s.name)) {
                if (!std.mem.eql(u8, d.scope, "project") and std.mem.eql(u8, s.scope, "project")) {
                    d.* = s;
                }
                replaced = true;
                break;
            }
        }
        if (!replaced) try deduped.append(arena, s);
    }

    return .{ .skills = deduped.items };
}

fn collectRoot(
    workspace: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    scope: []const u8,
    out: *std.ArrayListUnmanaged(Skill),
    compat: bool,
) !void {
    var dir = workspace.openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const skill_md = std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ root, entry.name }) catch continue;
        const content = fsutil.readSmallFile(workspace, io, arena, skill_md, max_skill_bytes) catch continue;
        const parsed = parseSkillFile(arena, content, entry.name) catch continue;
        try out.append(arena, .{
            .name = parsed.name,
            .description = parsed.description,
            .path = skill_md,
            .scope = scope,
        });
    }
    _ = compat;
}

/// Budgeted catalog index for the system prompt (fx available_skills
/// pattern): name + description lines, bounded, omitted count reported.
pub fn renderCatalog(arena: std.mem.Allocator, catalog: Catalog) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var included: usize = 0;
    var size: usize = 0;
    for (catalog.skills) |s| {
        const line = std.fmt.allocPrint(arena, "- {s}: {s} ({s})\n", .{ s.name, s.description, s.path }) catch continue;
        if (size + line.len > max_catalog_bytes) {
            out.appendSlice(arena, "...[catalog truncated]\n") catch {};
            break;
        }
        out.appendSlice(arena, line) catch {};
        size += line.len;
        included += 1;
    }
    if (out.items.len == 0) return "";
    const omitted = catalog.skills.len - included;
    if (omitted > 0) {
        out.print(arena, "[{d} skills omitted]\n", .{omitted}) catch {};
    }
    return out.items;
}

/// Load a skill body by name (the `skill` tool). Returns the raw file.
pub fn loadSkill(workspace: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, catalog: Catalog, name: []const u8) ![]const u8 {
    for (catalog.skills) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            return fsutil.readSmallFile(workspace, io, arena, s.path, max_skill_bytes);
        }
    }
    return error.SkillNotFound;
}

// ---------------------------------------------------------------- tests

test "parse skill with and without frontmatter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const with_fm = try parseSkillFile(a, "---\nname: pdf-review\ndescription: Review PDFs carefully\n---\nBody here.", "fallback");
    try std.testing.expectEqualStrings("pdf-review", with_fm.name);
    try std.testing.expectEqualStrings("Review PDFs carefully", with_fm.description);
    try std.testing.expectEqualStrings("Body here.", with_fm.body);

    const no_fm = try parseSkillFile(a, "just a body", "my-skill");
    try std.testing.expectEqualStrings("my-skill", no_fm.name);
    try std.testing.expectEqualStrings("just a body", no_fm.body);
}

test "discovery merges scopes; project overrides user" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Project skill + compat skill.
    try tmp.dir.createDirPath(io, ".ifnh/skills/testing");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ifnh/skills/testing/SKILL.md", .data = "---\nname: testing\ndescription: project testing\n---\nbody" });
    try tmp.dir.createDirPath(io, ".claude/skills/review");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/skills/review/SKILL.md", .data = "---\nname: review\ndescription: review skill\n---\nbody" });

    // Fake user dir: same tmp root acts as absolute user path.
    try tmp.dir.createDirPath(io, "user-skills/testing");
    try tmp.dir.writeFile(io, .{ .sub_path = "user-skills/testing/SKILL.md", .data = "---\nname: testing\ndescription: user testing\n---\nbody" });
    const user_dir = try std.fmt.allocPrint(a, "{s}/user-skills", .{"."});

    const catalog = try discover(tmp.dir, io, a, user_dir);
    try std.testing.expectEqual(@as(usize, 2), catalog.skills.len);
    for (catalog.skills) |s| {
        if (std.mem.eql(u8, s.name, "testing")) {
            try std.testing.expectEqualStrings("project testing", s.description); // project wins
            try std.testing.expectEqualStrings("project", s.scope);
        }
    }
}

test "catalog rendering is budgeted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var skills: std.ArrayListUnmanaged(Skill) = .empty;
    for (0..64) |i| {
        try skills.append(a, .{
            .name = try std.fmt.allocPrint(a, "skill-{d}", .{i}),
            .description = "x" ** 300,
            .path = "p",
            .scope = "project",
        });
    }
    const rendered = try renderCatalog(a, .{ .skills = skills.items });
    try std.testing.expect(rendered.len < max_catalog_bytes + 128);
}
