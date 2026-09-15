//! Terminal styling (M0-T34, DECISIONS R243/246/247).
//!
//! Data-driven, near-monochrome palette (fx convention): color carries
//! meaning only for status (green ok, red failure, yellow ask) and dim
//! for hints. Disabled by NO_COLOR env, `--no-color`, config ui.colors,
//! or non-TTY stdout. All functions return the text unchanged when
//! disabled — callers never branch.

const std = @import("std");

pub const Palette = struct {
    enabled: bool = false,

    pub fn detect(allocator: std.mem.Allocator, io: std.Io, environ_get: *const fn ([]const u8) ?[]const u8, config_colors: bool, cli_no_color: bool) Palette {
        _ = allocator;
        if (cli_no_color) return .{ .enabled = false };
        if (environ_get("NO_COLOR") != null) return .{ .enabled = false };
        if (!config_colors) return .{ .enabled = false };
        // Color only when stdout is a TTY (best-effort).
        const is_tty = std.Io.File.stdout().isTty(io) catch false;
        return .{ .enabled = is_tty };
    }

    fn wrap(self: Palette, code: []const u8, text: []const u8, arena: std.mem.Allocator) []const u8 {
        if (!self.enabled or text.len == 0) return text;
        return std.fmt.allocPrint(arena, "\x1b[{s}m{s}\x1b[0m", .{ code, text }) catch text;
    }

    pub fn green(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("32", text, arena);
    }

    pub fn red(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("31", text, arena);
    }

    pub fn yellow(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("33", text, arena);
    }

    pub fn dim(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("2", text, arena);
    }

    pub fn bold(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("1", text, arena);
    }
};

// ---------------------------------------------------------------- tests

test "palette wraps only when enabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const on = Palette{ .enabled = true };
    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m", on.green("ok", a));
    try std.testing.expectEqualStrings("\x1b[31mfail\x1b[0m", on.red("fail", a));
    try std.testing.expectEqualStrings("\x1b[2mhint\x1b[0m", on.dim("hint", a));

    const off = Palette{ .enabled = false };
    try std.testing.expectEqualStrings("ok", off.green("ok", a));
    try std.testing.expectEqualStrings("plain", off.red("plain", a));
    try std.testing.expectEqualStrings("", on.green("", a)); // empty passthrough
}
