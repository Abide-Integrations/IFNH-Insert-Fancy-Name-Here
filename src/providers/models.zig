//! Live model-list fetching for the first-run wizard (GET /models).
//!
//! OpenAI-compatible endpoints: `GET {base}/models` → `{"data":[{"id":..}]}`
//! (OpenRouter, OpenAI, Ollama's OpenAI endpoint, vLLM all share this
//! shape). Anthropic: `GET {base}/v1/models?limit=100` (same response
//! shape). Bounded: 1 MiB body, 10 s timeout, max 200 ids.

const std = @import("std");

pub const max_models: usize = 200;
pub const max_body_bytes: usize = 1024 * 1024;

/// Wire protocol family for output-token defaults.
const Wire = enum { anthropic, openai };

const OutputLimit = struct {
    tokens: u32,
    /// Newer OpenAI reasoning models reject `max_tokens`; use
    /// `max_completion_tokens` instead.
    max_completion_tokens: bool = false,
};

/// Anthropic requires `max_tokens`; use this when the model is not in the
/// table (new/self-hosted ids) instead of the old hard-coded 4096.
const anthropic_fallback_output_tokens: u32 = 8192;

const OutputLimitRow = struct {
    /// Matched as a substring so vendor-prefixed ids
    /// (e.g. `anthropic/claude-sonnet-4-6`) resolve too.
    pattern: []const u8,
    limit: OutputLimit,
};

// Ordered most-specific first. Values are each family's documented output
// ceiling (Anthropic Messages API, OpenAI Chat Completions).
const anthropic_output_limits = [_]OutputLimitRow{
    .{ .pattern = "claude-opus-4-5", .limit = .{ .tokens = 64_000 } },
    .{ .pattern = "claude-opus-4-1", .limit = .{ .tokens = 32_000 } },
    .{ .pattern = "claude-opus-4", .limit = .{ .tokens = 32_000 } },
    .{ .pattern = "claude-sonnet-4", .limit = .{ .tokens = 64_000 } },
    .{ .pattern = "claude-haiku-4", .limit = .{ .tokens = 64_000 } },
    .{ .pattern = "claude-3-7-sonnet", .limit = .{ .tokens = 64_000 } },
    .{ .pattern = "claude-3-5-sonnet", .limit = .{ .tokens = 8_192 } },
    .{ .pattern = "claude-3-5-haiku", .limit = .{ .tokens = 8_192 } },
    .{ .pattern = "claude-3-opus", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "claude-3-sonnet", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "claude-3-haiku", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "claude-2", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "claude-instant", .limit = .{ .tokens = 4_096 } },
};

const openai_output_limits = [_]OutputLimitRow{
    .{ .pattern = "gpt-5", .limit = .{ .tokens = 128_000, .max_completion_tokens = true } },
    .{ .pattern = "o1", .limit = .{ .tokens = 100_000, .max_completion_tokens = true } },
    .{ .pattern = "o3", .limit = .{ .tokens = 100_000, .max_completion_tokens = true } },
    .{ .pattern = "o4", .limit = .{ .tokens = 100_000, .max_completion_tokens = true } },
    .{ .pattern = "gpt-4.1", .limit = .{ .tokens = 32_768 } },
    .{ .pattern = "gpt-4o", .limit = .{ .tokens = 16_384 } },
    .{ .pattern = "gpt-4-turbo", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "gpt-4", .limit = .{ .tokens = 4_096 } },
    .{ .pattern = "gpt-3.5-turbo", .limit = .{ .tokens = 4_096 } },
};

/// Per-model output-token default. Null means "not in the table": for
/// OpenAI-compatible endpoints the request simply omits the limit, which
/// keeps local/self-hosted servers on their own default.
fn defaultOutputLimit(wire: Wire, model: []const u8) ?OutputLimit {
    const rows = switch (wire) {
        .anthropic => &anthropic_output_limits,
        .openai => &openai_output_limits,
    };
    for (rows) |row| {
        if (std.mem.indexOf(u8, model, row.pattern) != null) return row.limit;
    }
    return null;
}

/// Exposed for the golden body tests: config overrides still use the
/// model family's parameter name.
pub fn usesMaxCompletionTokens(model: []const u8) bool {
    const limit = defaultOutputLimit(.openai, model) orelse return false;
    return limit.max_completion_tokens;
}

pub fn anthropicOutputTokens(model: []const u8) u32 {
    const limit = defaultOutputLimit(.anthropic, model) orelse return anthropic_fallback_output_tokens;
    return limit.tokens;
}

/// Null for unknown OpenAI-compatible models: leave the server default alone.
pub fn openaiOutputTokens(model: []const u8) ?u32 {
    const limit = defaultOutputLimit(.openai, model) orelse return null;
    return limit.tokens;
}

pub const ModelEntry = struct {
    id: []const u8,
    /// Context window in tokens when the provider advertises it
    /// (OpenRouter: `context_length`). Null = unknown.
    context_length: ?u64 = null,
};

pub const Result = union(enum) {
    models: []ModelEntry,
    failure: []const u8,
};

/// Fetch the model list. `is_anthropic` selects header style.
pub fn fetchModels(
    arena: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    api_key: []const u8,
    is_anthropic: bool,
) Result {
    const url = modelListUrl(arena, base_url, is_anthropic);
    const uri = std.Uri.parse(url) catch
        return .{ .failure = "invalid base URL" };

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (is_anthropic) {
        extra[0] = .{ .name = "x-api-key", .value = api_key };
        extra[1] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        extra_len = 2;
    } else if (api_key.len > 0) {
        extra[0] = .{ .name = "authorization", .value = std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}) catch return .{ .failure = "out of memory" } };
        extra_len = 1;
    }

    var req = client.request(.GET, uri, .{
        .headers = .{
            .authorization = .omit,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra[0..extra_len],
        .redirect_behavior = .unhandled,
    }) catch |err| {
        return .{ .failure = @errorName(err) };
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        return .{ .failure = @errorName(err) };
    };
    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        return .{ .failure = @errorName(err) };
    };
    if (response.head.status.class() != .success) {
        return .{ .failure = std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(response.head.status)}) catch "HTTP error" };
    }

    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    const body = reader.allocRemaining(arena, .limited(max_body_bytes)) catch
        return .{ .failure = "response too large" };

    return parseModelsResponse(arena, body);
}

fn modelListUrl(arena: std.mem.Allocator, base_url: []const u8, is_anthropic: bool) []const u8 {
    const base = if (std.mem.endsWith(u8, base_url, "/")) base_url[0 .. base_url.len - 1] else base_url;
    if (is_anthropic) {
        return std.fmt.allocPrint(arena, "{s}/v1/models?limit=100", .{base}) catch "";
    }
    return std.fmt.allocPrint(arena, "{s}/models", .{base}) catch "";
}

/// Parse `{"data":[{"id":"..."}, ...]}`.
pub fn parseModelsResponse(arena: std.mem.Allocator, body: []const u8) Result {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return .{ .failure = "invalid JSON" };
    if (v != .object) return .{ .failure = "unexpected response shape" };
    const data = v.object.get("data") orelse return .{ .failure = "no model list in response" };
    if (data != .array) return .{ .failure = "unexpected response shape" };

    var out: std.ArrayListUnmanaged(ModelEntry) = .empty;
    for (data.array.items) |item| {
        if (out.items.len >= max_models) break;
        if (item != .object) continue;
        const id = item.object.get("id") orelse continue;
        if (id != .string or id.string.len == 0) continue;
        var entry = ModelEntry{ .id = arena.dupe(u8, id.string) catch continue };
        // Context window: OpenRouter exposes context_length; tolerate
        // common aliases.
        inline for (.{ "context_length", "context_window", "max_context_length" }) |field| {
            if (entry.context_length == null) {
                if (item.object.get(field)) |cl| {
                    if (cl == .integer and cl.integer > 0) entry.context_length = @intCast(cl.integer);
                }
            }
        }
        out.append(arena, entry) catch continue;
    }
    if (out.items.len == 0) return .{ .failure = "provider returned no models" };
    return .{ .models = out.items };
}

// ---------------------------------------------------------------- tests

test "parse OpenAI-shaped model list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = parseModelsResponse(a,
        \\{"data":[{"id":"openai/gpt-5"},{"id":"anthropic/claude-sonnet-4-6","context_length":200000},{"id":"z-ai/glm-4.6","context_window":131072}]}
    );
    const models = result.models;
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("openai/gpt-5", models[0].id);
    try std.testing.expectEqualStrings("z-ai/glm-4.6", models[2].id);
    try std.testing.expect(models[0].context_length == null);
    try std.testing.expectEqual(@as(u64, 200000), models[1].context_length.?);
    try std.testing.expectEqual(@as(u64, 131072), models[2].context_length.?);
}

test "parse failures are descriptive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("invalid JSON", parseModelsResponse(a, "nope").failure);
    try std.testing.expectEqualStrings("no model list in response", parseModelsResponse(a, "{}").failure);
    try std.testing.expectEqualStrings("provider returned no models", parseModelsResponse(a, "{\"data\":[]}").failure);
}

test "model list url construction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/models", modelListUrl(a, "https://openrouter.ai/api/v1", false));
    try std.testing.expectEqualStrings("http://localhost:11434/v1/models", modelListUrl(a, "http://localhost:11434/v1/", false));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/models?limit=100", modelListUrl(a, "https://api.anthropic.com", true));
}

test "per-model max_output_tokens defaults" {
    try std.testing.expectEqual(@as(u32, 64_000), defaultOutputLimit(.anthropic, "claude-sonnet-4-6").?.tokens);
    try std.testing.expectEqual(@as(u32, 64_000), defaultOutputLimit(.anthropic, "anthropic/claude-opus-4-5").?.tokens);
    try std.testing.expectEqual(@as(u32, 32_000), defaultOutputLimit(.anthropic, "claude-opus-4-1").?.tokens);
    try std.testing.expectEqual(@as(u32, 8_192), defaultOutputLimit(.anthropic, "claude-3-5-sonnet-20241022").?.tokens);
    try std.testing.expectEqual(@as(u32, 4_096), defaultOutputLimit(.anthropic, "claude-3-haiku-20240307").?.tokens);
    try std.testing.expect(defaultOutputLimit(.anthropic, "claude-new-family") == null);

    try std.testing.expectEqual(@as(u32, 128_000), defaultOutputLimit(.openai, "gpt-5.1").?.tokens);
    try std.testing.expect(usesMaxCompletionTokens("gpt-5.1"));
    try std.testing.expectEqual(@as(u32, 32_768), defaultOutputLimit(.openai, "gpt-4.1").?.tokens);
    try std.testing.expectEqual(@as(u32, 16_384), defaultOutputLimit(.openai, "gpt-4o-mini").?.tokens);
    try std.testing.expect(!usesMaxCompletionTokens("gpt-4o"));
    try std.testing.expect(defaultOutputLimit(.openai, "local-model") == null);
}
