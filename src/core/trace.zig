//! Timing spans for startup and per-turn work (ACTIVE_PLAN B-01).
//!
//! Enabled by `IFNH_TRACE_STARTUP=1`; every span is written to stderr and
//! timed against a baseline taken when the trace is created (process start),
//! so a turn reads as an offset from launch.
//!
//! Cost when disabled is one branch: `start` returns a `Span` with no
//! trace, so ending it touches no clock and no stream. When enabled, a line
//! is formatted into a stack buffer and written with one call; nothing is
//! allocated on either path.
//!
//! Spans are plain values passed by pointer alongside the work they time
//! (`ModelRequest.trace`, `RunParams.trace`); the module owns no global
//! state, so a session's spans follow that session's `Trace`.

const std = @import("std");

pub const env_var = "IFNH_TRACE_STARTUP";

pub const Trace = struct {
    io: std.Io,
    enabled: bool,
    /// Baseline for relative times ("+x ms since process start").
    t0: std.Io.Timestamp,

    /// Never reads the clock when tracing is off.
    pub fn init(io: std.Io, environ: ?*const std.process.Environ.Map) Trace {
        if (!enabledIn(environ)) return .{ .io = io, .enabled = false, .t0 = .zero };
        return .{ .io = io, .enabled = true, .t0 = std.Io.Timestamp.now(io, .awake) };
    }

    /// A disabled trace records nothing.
    pub fn isOn(self: *const Trace) bool {
        return self.enabled;
    }
};

/// `IFNH_TRACE_STARTUP=1` turns spans on ("true"/"yes" accepted); every
/// other value, including unset, leaves them off.
pub fn enabledIn(environ: ?*const std.process.Environ.Map) bool {
    const e = environ orelse return false;
    const v = e.get(env_var) orelse return false;
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes");
}

/// One timed span. `end` and `mark` are no-ops for a disabled span.
pub const Span = struct {
    trace: ?*Trace = null,
    name: []const u8 = "",
    start: std.Io.Timestamp = .zero,

    pub fn end(self: *Span) void {
        const t = self.trace orelse return;
        self.trace = null; // idempotent: a second end() writes nothing
        const now = std.Io.Timestamp.now(t.io, .awake);
        write(t, self.name, self.start.durationTo(now), now);
    }

    /// Print an intermediate mark without ending the span (e.g. time to
    /// first token inside a streaming request).
    pub fn mark(self: *const Span, name: []const u8) void {
        const t = self.trace orelse return;
        const now = std.Io.Timestamp.now(t.io, .awake);
        write(t, name, self.start.durationTo(now), now);
    }

    /// Milliseconds since the span started; 0 for a disabled span (no clock
    /// read). Used to sum per-round times into a per-turn total.
    pub fn elapsedMs(self: *const Span) f64 {
        const t = self.trace orelse return 0;
        const now = std.Io.Timestamp.now(t.io, .awake);
        return millis(self.start.durationTo(now));
    }
};

/// Start a span, or a no-op span when tracing is off.
pub fn start(trace: ?*Trace, name: []const u8) Span {
    const t = trace orelse return .{};
    if (!t.enabled) return .{};
    return .{ .trace = t, .name = name, .start = std.Io.Timestamp.now(t.io, .awake) };
}

/// Start a span whose duration is measured from the trace baseline
/// (process start) rather than from now — used for "startup to first paint".
pub fn startFromOrigin(trace: ?*Trace, name: []const u8) Span {
    const t = trace orelse return .{};
    if (!t.enabled) return .{};
    return .{ .trace = t, .name = name, .start = t.t0 };
}

/// Print a free-form note (memoisation hits, totals). No-op when off.
pub fn note(trace: ?*Trace, text: []const u8) void {
    const t = trace orelse return;
    if (!t.enabled) return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[trace] note: {s}\n", .{text}) catch return;
    std.Io.File.stderr().writeStreamingAll(t.io, line) catch {};
}

fn write(t: *Trace, name: []const u8, duration: std.Io.Duration, now: std.Io.Timestamp) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[trace] +{d:.2}ms {s} {d:.3}ms\n", .{
        millis(t.t0.durationTo(now)),
        name,
        millis(duration),
    }) catch return;
    std.Io.File.stderr().writeStreamingAll(t.io, line) catch {};
}

fn millis(d: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_ms;
}

// ---------------------------------------------------------------- tests

fn envWith(value: []const u8) std.process.Environ.Map {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    env.put(env_var, value) catch {};
    return env;
}

test "tracing is off unless the env var is set" {
    const io = std.testing.io;
    var empty = std.process.Environ.Map.init(std.testing.allocator);
    defer empty.deinit();
    var off = Trace.init(io, &empty);
    try std.testing.expect(!off.isOn());
    // A disabled span carries no trace: ending it cannot read a clock or
    // write anything.
    var span = start(&off, "should.not.print");
    try std.testing.expect(span.trace == null);
    span.end();
    span.mark("still.nothing");
    note(null, "nothing");

    var zero = envWith("0");
    defer zero.deinit();
    try std.testing.expect(!Trace.init(io, &zero).isOn());
    try std.testing.expect(!Trace.init(io, null).isOn());
}

test "tracing is on for 1/true/yes" {
    const io = std.testing.io;
    for ([_][]const u8{ "1", "true", "YES" }) |value| {
        var env = envWith(value);
        defer env.deinit();
        var trace = Trace.init(io, &env);
        try std.testing.expect(trace.isOn());
        var span = start(&trace, "test.span");
        try std.testing.expect(span.trace != null);
        try std.testing.expect(span.elapsedMs() >= 0);
        // Verified live; do not write to stderr from the test suite.
        span.trace = null;
    }
}
