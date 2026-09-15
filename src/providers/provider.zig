//! Provider contract (DESIGN §3.1, DECISIONS D39-D41).
//!
//! A provider translates the generic model request into a wire protocol,
//! streams it over HTTP, and emits normalized StreamEvents through a Sink.
//! Plain function-pointer struct — no vtables. Provider-specific features
//! travel in `provider_options` (opaque JSON), never in this interface.

const std = @import("std");
const core_types = @import("../core/types.zig");

pub const StreamEvent = core_types.StreamEvent;

/// Callback sink receiving normalized stream events.
pub const Sink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, ev: StreamEvent) void,

    pub fn emit(self: Sink, ev: StreamEvent) void {
        self.emit_fn(self.ctx, ev);
    }
};

/// One streaming model request. All slices are borrowed for the duration
/// of the call. `api_key` is a credential lease: adapters must not copy it
/// into retained memory (DECISIONS H110).
pub const ModelRequest = struct {
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    system: []const u8,
    messages: []const core_types.ChatMessage,
    /// Tool schemas as a JSON array string (already rendered).
    tools_json: []const u8 = "[]",
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    /// Opaque provider-specific options (JSON object text) or "".
    provider_options: []const u8 = "",
    cancel: *std.atomic.Value(bool),
};

pub const Capabilities = struct {
    streaming: bool = true,
    tool_use: bool = true,
    reasoning: bool = false,
};

/// The provider interface: a stream function plus a capability descriptor.
pub const Provider = struct {
    ctx: *anyopaque,
    stream_fn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, req: ModelRequest, sink: Sink) anyerror!void,
    capabilities_fn: *const fn () Capabilities = defaultCapabilities,

    pub fn stream(
        self: Provider,
        alloc: std.mem.Allocator,
        io: std.Io,
        req: ModelRequest,
        sink: Sink,
    ) anyerror!void {
        return self.stream_fn(self.ctx, alloc, io, req, sink);
    }

    pub fn capabilities(self: Provider) Capabilities {
        return self.capabilities_fn();
    }

    fn defaultCapabilities() Capabilities {
        return .{};
    }
};

/// Map an HTTP status to a provider failure kind (DECISIONS D47/48).
pub fn failureKindForStatus(status: u16) core_types.ProviderFailureKind {
    return switch (status) {
        400 => .invalid_request,
        401 => .unauthorized,
        403 => .forbidden,
        404 => .invalid_request,
        408 => .timeout,
        413 => .request_too_large,
        429 => .rate_limited,
        500...599 => .server_error,
        else => .other,
    };
}

test "failure kind mapping" {
    try std.testing.expectEqual(core_types.ProviderFailureKind.rate_limited, failureKindForStatus(429));
    try std.testing.expectEqual(core_types.ProviderFailureKind.unauthorized, failureKindForStatus(401));
    try std.testing.expectEqual(core_types.ProviderFailureKind.server_error, failureKindForStatus(503));
    try std.testing.expect(core_types.isRetryable(failureKindForStatus(503)));
    try std.testing.expect(!core_types.isRetryable(failureKindForStatus(401)));
}
