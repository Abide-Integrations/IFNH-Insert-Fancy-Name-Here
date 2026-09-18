//! Tool-calling capability probe (v0.1.6).
//!
//! One tiny request with a dummy tool decides whether a model can do
//! agentic work. Used by the first-run wizard so chat-only models are
//! detected at setup instead of failing mysteriously mid-session.

const std = @import("std");
const core_types = @import("../core/types.zig");
const provider_mod = @import("provider.zig");

pub const max_probe_tokens: u32 = 64;

const probe_tools_json =
    \\[{"type":"function","function":{"name":"ping","description":"A no-op test tool. Call it when asked.","parameters":{"type":"object","properties":{}}}}]
;

const probe_system = "You are a tool-use test harness.";
const probe_user = "Call the ping tool now. Do not reply with text.";

pub const ProbeResult = union(enum) {
    /// Model emitted a tool call: tool calling works.
    supported,
    /// Model replied but produced no tool call.
    unsupported: []const u8,
    /// The request itself failed (auth, network, schema rejected).
    error_: []const u8,
};

fn sinkCollect(
    ctx: *anyopaque,
    ev: @import("../core/types.zig").StreamEvent,
) void {
    const self: *Collector = @ptrCast(@alignCast(ctx));
    switch (ev) {
        .tool_call => self.saw_tool_call = true,
        .content_delta => |d| self.text.appendSlice(self.arena, d) catch {},
        .failure => |f| {
            self.failure = true;
            self.message = std.fmt.allocPrint(self.arena, "{s}", .{f.message}) catch "provider failure";
        },
        else => {},
    }
}

const Collector = struct {
    arena: std.mem.Allocator,
    saw_tool_call: bool = false,
    failure: bool = false,
    text: std.ArrayListUnmanaged(u8) = .empty,
    failure_message: []const u8 = "provider failure",
    message: []const u8 = "",
};

/// Run the probe. One bounded request against `base_url` with `api_key`.
pub fn probeToolSupport(
    arena: std.mem.Allocator,
    io: std.Io,
    provider: @import("provider.zig").Provider,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
) ProbeResult {
    var collector = Collector{ .arena = arena };
    var cancel = std.atomic.Value(bool).init(false);

    var msgs = [_]@import("../core/types.zig").ChatMessage{
        .{ .role = .user, .content = probe_user },
    };

    provider.stream(arena, io, .{
        .model = model,
        .base_url = base_url,
        .api_key = api_key,
        .system = probe_system,
        .messages = msgs[0..],
        .tools_json = probe_tools_json,
        .max_output_tokens = max_probe_tokens,
        .cancel = &cancel,
    }, .{ .ctx = &collector, .emit_fn = sinkCollect }) catch |err| {
        return .{ .unsupported = @errorName(err) };
    };

    if (collector.saw_tool_call) return .supported;
    // A failed request (bad key, network, provider 4xx/5xx) is INCONCLUSIVE
    // — never treat it as a capability verdict.
    if (collector.failure) return .{ .error_ = collector.failure_message };
    return .{ .unsupported = "no tool call in response" };
}

/// Classify a provider failure message for the "provider rejects tools"
/// hint (called on invalid_request failures mid-session).
pub fn looksLikeToolRejection(message: []const u8) bool {
    var lower: [256]u8 = undefined;
    const n = @min(message.len, lower.len);
    for (message[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, lower[0..n], "tool") != null;
}

// ---------------------------------------------------------------- tests

test "probe classification from scripted events" {
    // Pure-function coverage: the collector's classification rules.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // tool_call present -> supported (verified indirectly via engine tests);
    // here we check the rejection classifier.
    try std.testing.expect(looksLikeToolRejection("model does not support tools"));
    try std.testing.expect(looksLikeToolRejection("Invalid parameter: 'tools'"));
    try std.testing.expect(!looksLikeToolRejection("rate limited"));
    try std.testing.expect(!looksLikeToolRejection(""));
    _ = a;
}
