//! Offline engine benchmark (B-09, DESIGN §7).
//!
//! Drives the real `runTurn` loop with the scripted fake provider, so the
//! numbers cover request prologue work (tool schemas, collector, history)
//! without a network or API key. Live time-to-first-token needs a real
//! endpoint; this harness reports the offline lower bound only.
//!
//! Run with `zig build bench` or via `scripts/bench.sh`.

const std = @import("std");
const core_types = @import("core/types.zig");
const engine = @import("core/agent/engine.zig");
const fake_provider = @import("core/agent/testing.zig");
const permissions = @import("core/permissions/engine.zig");
const tool_mod = @import("tools/tool.zig");

const runs: usize = 500;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var fake = fake_provider.Fake{ .script = &.{
        &.{.{ .text = "benchmark reply" }},
    } };
    var perm_engine = permissions.Engine.init(arena, .auto);
    var tool_ctx: tool_mod.ToolContext = .{
        .io = io,
        .arena = arena,
        .workspace = std.Io.Dir.cwd(),
        .engine = &perm_engine,
        .journal = null,
        .max_file_read_bytes = 64 * 1024,
        .approval_ctx = undefined,
        .approval_fn = denyApproval,
    };

    var history: std.ArrayListUnmanaged(core_types.ChatMessage) = .empty;
    var cancel = std.atomic.Value(bool).init(false);
    const round_ns = try arena.alloc(u64, runs);
    const ttft_ns = try arena.alloc(u64, runs);

    var clock = TextClock{ .io = io };
    const callbacks = engine.Callbacks{
        .ctx = &clock,
        .on_text = TextClock.onText,
        .on_tool_start = noopToolStart,
        .on_tool_result = noopToolResult,
        .on_notice = noopNotice,
    };

    for (round_ns, ttft_ns) |*round, *ttft| {
        fake.call_index = 0;
        history.clearRetainingCapacity();
        try history.append(arena, .{ .role = .user, .content = "offline benchmark prompt" });

        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        clock.start = start;
        clock.first = 0;
        const outcome = try engine.runTurn(.{
            .io = io,
            .arena = arena,
            .pcfg = .{ .provider = fake.provider(), .model = "fake", .base_url = "", .api_key = "" },
            .system = "offline benchmark system prompt",
            .history = &history,
            .tool_ctx = &tool_ctx,
            .callbacks = callbacks,
            .cancel = &cancel,
        });
        const end = std.Io.Timestamp.now(io, .awake).nanoseconds;

        if (outcome.status != .completed) {
            std.debug.print("bench: fake provider failed: {s}\n", .{outcome.error_message});
            return error.BenchmarkProviderFailed;
        }
        if (clock.first == 0) return error.MissingFirstToken;

        round.* = @intCast(end - start);
        ttft.* = @intCast(clock.first - start);
    }

    std.mem.sort(u64, round_ns, {}, lessThan);
    std.mem.sort(u64, ttft_ns, {}, lessThan);

    try writeOut(io, "metric                                  value\n", .{});
    try writeOut(io, "--------------------------------------- ----------------\n", .{});
    try writeOut(io, "engine round overhead (median)          {d:.1} us\n", .{micros(round_ns[runs / 2])});
    try writeOut(io, "engine round overhead (p95)             {d:.1} us\n", .{micros(round_ns[runs * 95 / 100])});
    try writeOut(io, "offline TTFT (median)                   {d:.1} us\n", .{micros(ttft_ns[runs / 2])});
    try writeOut(io, "runs                                    {d}\n", .{runs});
    try writeOut(io, "live TTFT                              needs a live model endpoint/API key\n", .{});
}

const TextClock = struct {
    io: std.Io,
    start: i96 = 0,
    first: i96 = 0,

    fn onText(ctx: *anyopaque, text: []const u8) void {
        _ = text;
        const self: *TextClock = @ptrCast(@alignCast(ctx));
        if (self.first == 0) self.first = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }
};

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn denyApproval(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
    return .denied;
}

fn noopToolStart(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopToolResult(_: *anyopaque, _: []const u8, _: tool_mod.Status, _: []const u8) void {}
fn noopNotice(_: *anyopaque, _: []const u8) void {}

fn writeOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(io, text);
}
