//! Terminal styling (M0-T34, DECISIONS R243/246/247).
//!
//! Semantic ANSI palette, native Zig — no dependencies. Color carries
//! meaning only: success/error/warn/info states, one accent, headings.
//! Disabled by NO_COLOR env, `--no-color`, config ui.colors, or non-TTY
//! stdout. All functions return text unchanged when disabled — callers
//! never branch.

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

    // ---- semantic palette ----

    /// Positive outcomes (tool ok, checks pass).
    pub fn success(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("32", text, arena); // green
    }

    /// Failures and hard errors.
    pub fn err(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("91", text, arena); // bright red
    }

    /// Warnings, denials, "pay attention".
    pub fn warn(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("93", text, arena); // bright yellow
    }

    /// Informational highlights, accents (agent activity, picks).
    pub fn info(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("36", text, arena); // cyan
    }

    /// Brand accent (session banner, headings within output).
    pub fn accent(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("95", text, arena); // bright magenta
    }

    /// Headings and emphasis.
    pub fn heading(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("1;97", text, arena); // bold white
    }

    /// De-emphasis (hints, truncation notices, provenance).
    pub fn dim(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.wrap("2", text, arena);
    }

    // ---- compatibility aliases (call sites migrating to semantic names) ----

    pub fn green(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.success(text, arena);
    }

    pub fn red(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.err(text, arena);
    }

    pub fn yellow(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.warn(text, arena);
    }

    pub fn bold(self: Palette, text: []const u8, arena: std.mem.Allocator) []const u8 {
        return self.heading(text, arena);
    }
};

// ---------------------------------------------------------------- tests

test "palette wraps only when enabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const on = Palette{ .enabled = true };
    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m", on.success("ok", a));
    try std.testing.expectEqualStrings("\x1b[91mfail\x1b[0m", on.err("fail", a));
    try std.testing.expectEqualStrings("\x1b[93mwarn\x1b[0m", on.warn("warn", a));
    try std.testing.expectEqualStrings("\x1b[36minfo\x1b[0m", on.info("info", a));
    try std.testing.expectEqualStrings("\x1b[95mbrand\x1b[0m", on.accent("brand", a));
    try std.testing.expectEqualStrings("\x1b[1;97mtitle\x1b[0m", on.heading("title", a));
    try std.testing.expectEqualStrings("\x1b[2mhint\x1b[0m", on.dim("hint", a));

    const off = Palette{ .enabled = false };
    try std.testing.expectEqualStrings("ok", off.success("ok", a));
    try std.testing.expectEqualStrings("plain", off.err("plain", a));
    try std.testing.expectEqualStrings("", on.success("", a)); // empty passthrough
}
