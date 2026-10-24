//! Opt-in timing spans for startup and turn prologues (B-01).
//!
//! Spans are free unless `IFNH_TRACE_STARTUP` is `1`, `true`, or `yes`:
//! disabled spans never read a clock and never allocate. Enabled spans write
//! exactly one line per span to stderr. Trace state is owned by the caller
//! (main for startup, the REPL session for turns); there are no globals.

const std = @import("std");

pub const env_var = "IFNH_TRACE_STARTUP";

pub fn enabledIn(environ: ?*const std.process.Environ.Map) bool {
    const env = environ orelse return false;
    const raw = env.get(env_var) orelse return false;
    return std.ascii.eqlIgnoreCase(raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes");
}

pub const Trace = struct {
    io: std.Io,
    enabled: bool = false,
    t0: std.Io.Timestamp = .zero,
    /// Test seam: when set, lines go here instead of stderr. Production
    /// callers leave this null.
    sink: ?*std.Io.Writer = null,

    pub fn init(io: std.Io, environ: ?*const std.process.Environ.Map) Trace {
        if (!enabledIn(environ)) return .{ .io = io };
        return .{ .io = io, .enabled = true, .t0 = std.Io.Timestamp.now(io, .awake) };
    }

    /// Emit a standalone note with no duration (for aggregate totals).
    pub fn note(self: *Trace, name: []const u8, text: []const u8) void {
        if (!self.enabled) return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[trace] {s} {s}\n", .{ name, text }) catch return;
        self.write(line);
    }

    fn write(self: *Trace, line: []const u8) void {
        if (self.sink) |s| {
            s.writeAll(line) catch {};
            return;
        }
        std.Io.File.stderr().writeStreamingAll(self.io, line) catch {};
    }
};

pub const Span = struct {
    trace: ?*Trace = null,
    name: []const u8 = "",
    start: std.Io.Timestamp = .zero,

    pub fn begin(trace: ?*Trace, name: []const u8) Span {
        const t = trace orelse return .{ .name = name };
        if (!t.enabled) return .{ .trace = t, .name = name };
        return .{ .trace = t, .name = name, .start = std.Io.Timestamp.now(t.io, .awake) };
    }

    /// End the span and write its single line. `note` appends extra detail.
    pub fn end(self: Span, note_text: []const u8) void {
        const t = self.trace orelse return;
        if (!t.enabled) return;
        const elapsed = std.Io.Timestamp.durationTo(self.start, std.Io.Timestamp.now(t.io, .awake));
        const us = elapsed.toMicroseconds();
        var buf: [512]u8 = undefined;
        const line = if (note_text.len == 0)
            std.fmt.bufPrint(&buf, "[trace] {s} {d}.{d:0>3}ms\n", .{ self.name, @divTrunc(us, 1000), @mod(us, 1000) }) catch return
        else
            std.fmt.bufPrint(&buf, "[trace] {s} {d}.{d:0>3}ms {s}\n", .{ self.name, @divTrunc(us, 1000), @mod(us, 1000), note_text }) catch return;
        t.write(line);
    }
};

// ---------------------------------------------------------------- tests

test "trace enable parsing accepts 1 true yes case-insensitively" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(!enabledIn(&env));
    try env.put(env_var, "0");
    try std.testing.expect(!enabledIn(&env));
    try env.put(env_var, "TRUE");
    try std.testing.expect(enabledIn(&env));
    try env.put(env_var, "Yes");
    try std.testing.expect(enabledIn(&env));
    try env.put(env_var, "1");
    try std.testing.expect(enabledIn(&env));
}

test "disabled span is a no-op and reads no clock" {
    const io = std.testing.io;
    var trace = Trace{ .io = io };
    var span = Span.begin(&trace, "disabled");
    span.end("ignored");
    try std.testing.expect(!trace.enabled);
    try std.testing.expectEqual(@as(i96, 0), span.start.nanoseconds);

    // A null trace is equally inert.
    var null_span = Span.begin(null, "null");
    null_span.end("");
    try std.testing.expect(null_span.trace == null);
}

test "enabled span emits exactly one line" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var trace = Trace{ .io = io, .enabled = true, .t0 = std.Io.Timestamp.zero, .sink = &aw.writer };

    Span.begin(&trace, "startup.config").end("files=2");
    trace.note("turn.total.tools", "12.000ms");

    const lines = aw.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, lines, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, lines, "[trace] startup.config "));
    try std.testing.expect(std.mem.indexOf(u8, lines, "turn.total.tools") != null);
}
