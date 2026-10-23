//! Timing spans for startup and per-turn overhead (ACTIVE_PLAN B-01).
//!
//! Enabled by `IFNH_TRACE_STARTUP=1`; every span is written to stderr as
//! `[trace] <name>: <ms> ms (t+<ms>)`. When the variable is unset, `begin`
//! is one bool check: no clock read, no allocation, no output, so the hot
//! path costs nothing.
//!
//! `init` must run before any spans (the composition root calls it first);
//! after that the module globals are read-only, so threads may emit spans.

const std = @import("std");

var enabled_flag: bool = false;
var origin_ns: i96 = 0;

/// Read the environment once. Later calls are no-ops.
pub fn init(io: std.Io, environ: ?*const std.process.Environ.Map) void {
    if (enabled_flag) return;
    const env = environ orelse return;
    const raw = env.get("IFNH_TRACE_STARTUP") orelse return;
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0 or std.mem.eql(u8, v, "0")) return;
    origin_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    enabled_flag = true;
}

pub fn enabled() bool {
    return enabled_flag;
}

/// An in-flight span. Disabled spans carry no timestamp.
pub const Span = struct {
    name: []const u8,
    start_ns: i96 = 0,
    on: bool = false,
};

pub fn begin(io: std.Io, name: []const u8) Span {
    if (!enabled_flag) return .{ .name = name };
    return .{
        .name = name,
        .start_ns = std.Io.Timestamp.now(io, .awake).nanoseconds,
        .on = true,
    };
}

/// Close a span; returns its duration in nanoseconds (0 when tracing is off).
pub fn end(io: std.Io, span: Span) i96 {
    if (!span.on) return 0;
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const dur = now - span.start_ns;
    emit(io, span.name, dur, now);
    return dur;
}

/// A point-in-time marker (duration 0).
pub fn mark(io: std.Io, name: []const u8) void {
    if (!enabled_flag) return;
    emit(io, name, 0, std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn emit(io: std.Io, name: []const u8, dur_ns: i96, at_ns: i96) void {
    var buf: [256]u8 = undefined;
    const line = formatLine(&buf, name, dur_ns, at_ns - origin_ns) catch return;
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

/// `[trace] name: 1.234 ms (t+5.678)` — pure so it can be tested.
fn formatLine(buf: []u8, name: []const u8, dur_ns: i96, since_origin_ns: i96) ![]const u8 {
    const dur: u96 = @intCast(@max(dur_ns, 0));
    const at: u96 = @intCast(@max(since_origin_ns, 0));
    return std.fmt.bufPrint(buf, "[trace] {s}: {d}.{d:0>3} ms (t+{d}.{d:0>3})\n", .{
        name,
        dur / std.time.ns_per_ms,
        (dur % std.time.ns_per_ms) / std.time.ns_per_us,
        at / std.time.ns_per_ms,
        (at % std.time.ns_per_ms) / std.time.ns_per_us,
    });
}

// ---------------------------------------------------------------- tests

test "spans are free and silent when tracing is unset" {
    // Module state starts disabled; nothing has been initialised here.
    try std.testing.expect(!enabled());
    const span = begin(std.testing.io, "test.disabled");
    try std.testing.expect(!span.on);
    try std.testing.expectEqual(@as(i96, 0), end(std.testing.io, span));
    mark(std.testing.io, "test.mark");
}

test "span formatting is millisecond-scale with process offset" {
    var buf: [128]u8 = undefined;
    const line = try formatLine(&buf, "turn.setup", 1_234_567, 5_678_901);
    try std.testing.expectEqualStrings("[trace] turn.setup: 1.234 ms (t+5.678)\n", line);
}
