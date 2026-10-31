//! Live status footer (ACTIVE_PLAN C-04).
//!
//!   <model> | ctx <pct>% (<used>/<window>) | ↑<in> ↓<out> | $<cost> | <elapsed>s
//!
//! Drawn on stderr so stdout stays the assistant's text, and only when
//! stderr is a terminal and `ui.footer` is on. A disabled footer writes
//! nothing at all, not even a newline.
//!
//! Interleaving policy: the footer is a single line without a trailing
//! newline, so it is "live" only while nothing else is being printed. Every
//! other writer (text deltas, tool lines, prompts, notices) calls `clear()`
//! first, which erases the line; the footer is redrawn after a tool result
//! (throttled to once per 100 ms), at turn start, and at turn end. It never
//! redraws inside the text stream, so it cannot interleave with it.

const std = @import("std");
const style = @import("style.zig");
const pricing = @import("../providers/pricing.zig");
const core_types = @import("../core/types.zig");

pub const min_redraw_ms: i64 = 100;

pub const Stats = struct {
    model: []const u8 = "",
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    /// Prompt + output tokens of the last request: how full the window is.
    ctx_used: u64 = 0,
    /// Effective context budget; null when none is configured.
    window: ?u64 = null,
    cost_usd: f64 = 0,
    priced: bool = false,
    elapsed_ms: u64 = 0,
    turn_index: u32 = 0,
};

/// Tokens the last request occupied. Anthropic reports cache reads and writes
/// outside `input_tokens`; OpenAI-style usage already includes them.
pub fn contextTokens(last_round: core_types.Usage, input_excludes_cache: bool) u64 {
    const prompt = last_round.input_tokens +
        (if (input_excludes_cache) last_round.cache_read_tokens + last_round.cache_write_tokens else 0);
    return prompt + last_round.output_tokens;
}

/// The footer text for `s` (no styling, no escape codes). Pure.
pub fn renderLine(buf: []u8, s: Stats) []const u8 {
    var cost_buf: [32]u8 = undefined;
    const cost: []const u8 = if (s.priced) pricing.formatUsd(&cost_buf, s.cost_usd) else "n/a";
    const elapsed_tenths = s.elapsed_ms / 100;
    const model = if (s.model.len > 0) s.model else "?";
    if (s.window) |win| {
        if (win > 0) {
            return std.fmt.bufPrint(buf, "{s} | ctx {d}% ({d}/{d}) | \u{2191}{d} \u{2193}{d} | {s} | {d}.{d}s", .{
                model, s.ctx_used * 100 / win, s.ctx_used, win, s.tokens_in, s.tokens_out, cost, elapsed_tenths / 10, elapsed_tenths % 10,
            }) catch model;
        }
    }
    return std.fmt.bufPrint(buf, "{s} | ctx ?% | \u{2191}{d} \u{2193}{d} | {s} | {d}.{d}s", .{
        model, s.tokens_in, s.tokens_out, cost, elapsed_tenths / 10, elapsed_tenths % 10,
    }) catch model;
}

/// Redraw throttle: always on `force`, otherwise at most once per 100 ms.
pub fn shouldDraw(last_draw_ms: ?i64, now_ms: i64, force: bool) bool {
    if (force) return true;
    const last = last_draw_ms orelse return true;
    return now_ms - last >= min_redraw_ms;
}

pub const Footer = struct {
    enabled: bool,
    io: std.Io,
    palette: style.Palette,
    stats: Stats = .{},
    /// A footer line is currently on screen (cursor sits at its end).
    live: bool = false,
    started_ms: ?i64 = null,
    last_draw_ms: ?i64 = null,
    line_buf: [320]u8 = undefined,

    pub fn init(io: std.Io, enabled: bool, palette: style.Palette) Footer {
        return .{ .enabled = enabled, .io = io, .palette = palette };
    }

    fn nowMs(self: *const Footer) i64 {
        return @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
    }

    /// The text that would be drawn for the current stats.
    pub fn render(self: *Footer) []const u8 {
        return renderLine(&self.line_buf, self.stats);
    }

    /// A turn starts: reset the clock and draw immediately.
    pub fn beginTurn(self: *Footer, stats: Stats) void {
        if (!self.enabled) return;
        self.stats = stats;
        self.started_ms = self.nowMs();
        self.draw(true);
    }

    /// New numbers; redraws unless inside the 100 ms window.
    pub fn update(self: *Footer, stats: Stats) void {
        if (!self.enabled) return;
        self.stats = stats;
        self.draw(false);
    }

    /// Redraw with the current numbers and a fresh elapsed time (throttled).
    pub fn tick(self: *Footer) void {
        if (!self.enabled) return;
        self.draw(false);
    }

    /// Erase the live footer line so other output starts on a clean line.
    pub fn clear(self: *Footer) void {
        if (!self.enabled or !self.live) return;
        self.write("\r\x1b[K");
        self.live = false;
    }

    /// Turn over: erase any live line, then print the final one with a newline.
    pub fn finish(self: *Footer, stats: Stats) void {
        if (!self.enabled) return;
        self.clear();
        self.stats = stats;
        if (self.started_ms) |t0| self.stats.elapsed_ms = @intCast(@max(self.nowMs() - t0, 0));
        self.started_ms = null;
        var scratch: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const styled = self.palette.dim(self.render(), fba.allocator());
        self.write(styled);
        self.write("\n");
    }

    /// The turn never reached the provider: leave no trace.
    pub fn abandon(self: *Footer) void {
        self.clear();
        self.started_ms = null;
    }

    fn draw(self: *Footer, force: bool) void {
        const now = self.nowMs();
        if (!shouldDraw(self.last_draw_ms, now, force)) return;
        self.last_draw_ms = now;
        if (self.started_ms) |t0| self.stats.elapsed_ms = @intCast(@max(now - t0, 0));
        var scratch: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const styled = self.palette.dim(self.render(), fba.allocator());
        self.write("\r\x1b[K");
        self.write(styled);
        self.live = true;
    }

    fn write(self: *Footer, bytes: []const u8) void {
        std.Io.File.stderr().writeStreamingAll(self.io, bytes) catch {};
    }
};

// ---------------------------------------------------------------- tests

test "footer: renders every segment in order" {
    var buf: [256]u8 = undefined;
    const line = renderLine(&buf, .{
        .model = "claude-sonnet-4-6",
        .tokens_in = 1200,
        .tokens_out = 345,
        .ctx_used = 24000,
        .window = 96000,
        .cost_usd = 0.0123,
        .priced = true,
        .elapsed_ms = 4560,
    });
    try std.testing.expectEqualStrings("claude-sonnet-4-6 | ctx 25% (24000/96000) | \u{2191}1200 \u{2193}345 | $0.0123 | 4.5s", line);
}

test "footer: unknown window and unpriced model show placeholders" {
    var buf: [256]u8 = undefined;
    const line = renderLine(&buf, .{ .model = "local-model", .tokens_in = 5, .tokens_out = 7, .elapsed_ms = 0 });
    try std.testing.expectEqualStrings("local-model | ctx ?% | \u{2191}5 \u{2193}7 | n/a | 0.0s", line);
    // A zero window is treated as unknown rather than dividing by zero.
    const zero = renderLine(&buf, .{ .model = "m", .window = 0, .priced = true });
    try std.testing.expectEqualStrings("m | ctx ?% | \u{2191}0 \u{2193}0 | $0.00 | 0.0s", zero);
    try std.testing.expect(std.mem.startsWith(u8, renderLine(&buf, .{}), "? | ctx ?%"));
}

test "footer: rendered text carries no escape bytes" {
    var buf: [256]u8 = undefined;
    const line = renderLine(&buf, .{ .model = "m", .window = 1000, .ctx_used = 2000, .priced = true, .cost_usd = 12.5, .elapsed_ms = 123456 });
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "ctx 200%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "$12.5000") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "123.4s"));
}

test "footer: redraw throttle allows one draw per 100 ms except when forced" {
    try std.testing.expect(shouldDraw(null, 5, false));
    try std.testing.expect(!shouldDraw(1000, 1050, false));
    try std.testing.expect(!shouldDraw(1000, 1099, false));
    try std.testing.expect(shouldDraw(1000, 1100, false));
    try std.testing.expect(shouldDraw(1000, 1001, true));
}

test "footer: context tokens count cache only for providers that report it apart" {
    const u = core_types.Usage{ .input_tokens = 100, .output_tokens = 20, .cache_read_tokens = 500, .cache_write_tokens = 30 };
    try std.testing.expectEqual(@as(u64, 650), contextTokens(u, true));
    try std.testing.expectEqual(@as(u64, 120), contextTokens(u, false));
}

test "footer: a disabled footer never writes or tracks a line" {
    var f = Footer.init(std.testing.io, false, .{});
    f.beginTurn(.{ .model = "m" });
    f.update(.{ .model = "m" });
    f.tick();
    f.finish(.{ .model = "m" });
    f.abandon();
    try std.testing.expect(!f.live);
    try std.testing.expect(f.started_ms == null);
    try std.testing.expect(f.last_draw_ms == null);
}
