//! Shared core types: the vocabulary used across providers, tools, agent
//! runtime, and sessions. Contracts here are stable from day one (DESIGN §3).

const std = @import("std");

pub const ChatRole = enum { system, user, assistant, tool };

/// A neutral multimodal content part. Adapters translate this into their
/// wire format; the core never assumes a provider-specific shape.
pub const ImageSource = struct {
    /// MIME type, e.g. "image/png".
    media_type: []const u8 = "image/png",
    /// Base64-encoded image bytes, or null when `url` is set.
    data: ?[]const u8 = null,
    /// Remote image URL, or null when `data` is set.
    url: ?[]const u8 = null,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    image: ImageSource,
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    /// JSON array of {id, name, arguments_json} for assistant tool calls.
    tool_calls_json: ?[]const u8 = null,
    /// Optional multimodal parts. When non-empty, adapters serialize these
    /// instead of the plain `content` string (which stays populated for
    /// text-only consumers such as session replay and compaction).
    blocks: []const ContentBlock = &.{},
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

pub const ProviderFailureKind = enum {
    invalid_request,
    unauthorized,
    forbidden,
    request_too_large,
    rate_limited,
    server_error,
    bad_gateway,
    unavailable,
    timeout,
    network,
    cancelled,
    other,
};

pub const ProviderFailure = struct {
    kind: ProviderFailureKind,
    message: []const u8,
    retry_after_s: ?u32 = null,
};

pub fn isRetryable(kind: ProviderFailureKind) bool {
    return switch (kind) {
        .rate_limited, .server_error, .bad_gateway, .unavailable, .timeout, .network => true,
        else => false,
    };
}

/// Streaming provider events (DECISIONS D39).
pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_call: ToolCall,
    usage: Usage,
    done,
    failure: ProviderFailure,
};

/// Session event log record variants (DESIGN §3.4).
pub const SessionEventKind = enum {
    user,
    assistant,
    tool_call,
    tool_result,
    context_checkpoint,
    lifecycle_state,
    fork_point,
    interrupted,
};

pub const ToolStatus = enum { ok, denied, failed, timeout };

test "retryable failure kinds cover transient classes only" {
    try std.testing.expect(isRetryable(.rate_limited));
    try std.testing.expect(isRetryable(.network));
    try std.testing.expect(!isRetryable(.unauthorized));
    try std.testing.expect(!isRetryable(.invalid_request));
}
