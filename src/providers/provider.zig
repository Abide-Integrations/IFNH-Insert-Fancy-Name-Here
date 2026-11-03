//! Provider contract (DESIGN §3.1, DECISIONS D39-D41).
//!
//! A provider translates the generic model request into a wire protocol,
//! streams it over HTTP, and emits normalized StreamEvents through a Sink.
//! Plain function-pointer struct — no vtables. Provider-specific features
//! travel in `provider_options` (opaque JSON), never in this interface.

const std = @import("std");
const core_types = @import("../core/types.zig");
const trace_mod = @import("../core/trace.zig");
const wire_log = @import("../core/wire_log.zig");

pub const StreamEvent = core_types.StreamEvent;

/// Callback sink receiving normalized stream events.
pub const Sink = struct {
    ctx: *anyopaque,
    emit_fn: *const fn (ctx: *anyopaque, ev: StreamEvent) void,

    pub fn emit(self: Sink, ev: StreamEvent) void {
        self.emit_fn(self.ctx, ev);
    }
};

/// How `ModelRequest.api_key` is presented to the endpoint. Only the Gemini
/// adapter reads it: `.oauth` sends the key as a Bearer token (a Google OAuth
/// access token) instead of `x-goog-api-key`.
pub const Auth = enum { api_key, oauth };

/// One streaming model request. All slices are borrowed for the duration
/// of the call. `api_key` is a credential lease: adapters must not copy it
/// into retained memory (DECISIONS H110).
pub const ModelRequest = struct {
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    auth: Auth = .api_key,
    system: []const u8,
    /// Byte length of the byte-stable prefix of `system` (B-03). Adapters
    /// that support prompt caching may split there and mark the prefix
    /// cacheable; 0 (or the whole string) means "no split".
    system_stable_len: usize = 0,
    messages: []const core_types.ChatMessage,
    /// Neutral tool specs; adapters serialize them for their wire format.
    tools: []const core_types.ToolSpec = &.{},
    temperature: ?f64 = null,
    max_output_tokens: ?u32 = null,
    /// Opaque provider-specific options (JSON object text) or "".
    provider_options: []const u8 = "",
    /// Optional timing trace owned by the session (B-01).
    trace: ?*trace_mod.Trace = null,
    /// Session-owned HTTP client; adapters fall back to a per-request
    /// client when null and never deinit a caller-supplied one (B-02).
    client: ?*std.http.Client = null,
    /// Optional wire log (`--trace`, D-09); adapters log the request they
    /// send, `Provider.stream` logs the accumulated response or error.
    wire: ?*wire_log.WireLog = null,
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
        const wire = req.wire orelse return self.stream_fn(self.ctx, alloc, io, req, sink);
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        var tap = WireTap{ .acc = .{ .arena = arena_state.allocator() }, .inner = sink };
        wire.begin(req.model);
        self.stream_fn(self.ctx, alloc, io, req, .{ .ctx = &tap, .emit_fn = WireTap.emit }) catch |err| {
            wire.failure(@errorName(err), req.api_key);
            return err;
        };
        if (tap.acc.failure_message) |m| {
            wire.failure(m, req.api_key);
        } else {
            wire.response(&tap.acc, req.api_key);
        }
    }

    pub fn capabilities(self: Provider) Capabilities {
        return self.capabilities_fn();
    }

    fn defaultCapabilities() Capabilities {
        return .{};
    }
};

/// Forwards events unchanged while accumulating them for the wire log.
const WireTap = struct {
    acc: wire_log.Accumulator,
    inner: Sink,

    fn emit(ctx: *anyopaque, ev: StreamEvent) void {
        const self: *WireTap = @ptrCast(@alignCast(ctx));
        self.acc.add(ev);
        self.inner.emit(ev);
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

const TapFake = struct {
    fail: bool,

    fn stream(ctx: *anyopaque, _: std.mem.Allocator, _: std.Io, req: ModelRequest, sink: Sink) anyerror!void {
        const self: *TapFake = @ptrCast(@alignCast(ctx));
        if (req.wire) |w| w.request("openai", "https://h/v1/chat", &.{}, "{\"n\":1}", req.api_key);
        if (self.fail) return error.ConnectionRefused;
        sink.emit(.{ .content_delta = "hello " });
        sink.emit(.{ .content_delta = "ghp_abcdefghijklmnopqrstuvwxyz0123456789" });
        sink.emit(.{ .usage = .{ .input_tokens = 3, .output_tokens = 4 } });
        sink.emit(.done);
    }
};

const CountSink = struct {
    events: usize = 0,
    fn emit(ctx: *anyopaque, _: StreamEvent) void {
        const self: *CountSink = @ptrCast(@alignCast(ctx));
        self.events += 1;
    }
};

test "trace provider stream logs request, accumulated response and thrown errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/w.ndjson", .{tmp.sub_path});
    var log = try wire_log.WireLog.open(std.testing.io, std.testing.allocator, path, &.{});
    defer log.close();

    var cancel = std.atomic.Value(bool).init(false);
    var counter = CountSink{};
    const sink = Sink{ .ctx = &counter, .emit_fn = CountSink.emit };
    const req = ModelRequest{ .model = "m", .base_url = "https://h", .api_key = "k", .system = "", .messages = &.{}, .wire = &log, .cancel = &cancel };

    var ok = TapFake{ .fail = false };
    const p_ok = Provider{ .ctx = &ok, .stream_fn = TapFake.stream };
    try p_ok.stream(a, std.testing.io, req, sink);
    try std.testing.expectEqual(@as(usize, 4), counter.events); // events pass through unchanged

    var bad = TapFake{ .fail = true };
    const p_bad = Provider{ .ctx = &bad, .stream_fn = TapFake.stream };
    try std.testing.expectError(error.ConnectionRefused, p_bad.stream(a, std.testing.io, req, sink));

    const text = try tmp.dir.readFileAlloc(std.testing.io, "w.ndjson", a, .limited(1 << 16));
    var kinds: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| : (n += 1) {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        kinds[n] = v.object.get("kind").?.string;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("request", kinds[0]);
    try std.testing.expectEqualStrings("response", kinds[1]);
    try std.testing.expectEqualStrings("request", kinds[2]);
    try std.testing.expectEqualStrings("error", kinds[3]);
    try std.testing.expect(std.mem.indexOf(u8, text, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"round\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ConnectionRefused") != null);
}
