//! Shared core types: the vocabulary used across providers, tools, agent
//! runtime, and sessions. Contracts here are stable from day one (DESIGN §3).

const std = @import("std");

pub const ChatRole = enum { system, user, assistant, tool };

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    /// JSON array of {id, name, arguments_json} for assistant tool calls.
    tool_calls_json: ?[]const u8 = null,
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
