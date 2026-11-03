//! Live model-list fetching for the first-run wizard (GET /models).
//!
//! OpenAI-compatible endpoints: `GET {base}/models` → `{"data":[{"id":..}]}`
//! (OpenRouter, OpenAI, Ollama's OpenAI endpoint, vLLM all share this
//! shape). Anthropic: `GET {base}/v1/models?limit=100` (same response
//! shape). Gemini: `GET {base}/models?pageSize=100` with `x-goog-api-key`,
//! `{"models":[{"name":"models/<id>"}],"nextPageToken":..}`, followed through
//! `pageToken` up to `max_pages`. Bounded: 1 MiB body per page, max 200 ids.

const std = @import("std");

pub const max_models: usize = 200;
pub const max_body_bytes: usize = 1024 * 1024;

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

/// Endpoint dialect: header style, URL and response shape.
pub const Style = enum { openai, anthropic, gemini };

/// Pages fetched at most for a paginated list (Gemini `pageToken`).
pub const max_pages: usize = 10;

/// Fetch the model list. Gemini lists are paginated; the others are one page.
pub fn fetchModels(
    arena: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    api_key: []const u8,
    style: Style,
) Result {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    if (style != .gemini) {
        const body = switch (fetchPage(arena, &client, modelListUrl(arena, base_url, style), api_key, style)) {
            .body => |b| b,
            .failure => |f| return .{ .failure = f },
        };
        return parseModelsResponse(arena, body);
    }

    var all: std.ArrayListUnmanaged(ModelEntry) = .empty;
    var token: ?[]const u8 = null;
    var page: usize = 0;
    while (page < max_pages and all.items.len < max_models) : (page += 1) {
        const base = modelListUrl(arena, base_url, style);
        const url = if (token) |t|
            std.fmt.allocPrint(arena, "{s}&pageToken={s}", .{ base, t }) catch return .{ .failure = "out of memory" }
        else
            base;
        const body = switch (fetchPage(arena, &client, url, api_key, style)) {
            .body => |b| b,
            .failure => |f| return .{ .failure = f },
        };
        const next = parseGeminiPage(arena, body, &all) catch |err| return .{ .failure = @errorName(err) };
        token = next;
        if (token == null) break;
    }
    if (all.items.len == 0) return .{ .failure = "provider returned no models" };
    return .{ .models = all.items };
}

const Page = union(enum) { body: []const u8, failure: []const u8 };

fn fetchPage(arena: std.mem.Allocator, client: *std.http.Client, url: []const u8, api_key: []const u8, style: Style) Page {
    const uri = std.Uri.parse(url) catch
        return .{ .failure = "invalid base URL" };

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    switch (style) {
        .anthropic => {
            extra[0] = .{ .name = "x-api-key", .value = api_key };
            extra[1] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            extra_len = 2;
        },
        .gemini => {
            if (api_key.len > 0) {
                extra[0] = .{ .name = "x-goog-api-key", .value = api_key };
                extra_len = 1;
            }
        },
        .openai => if (api_key.len > 0) {
            extra[0] = .{ .name = "authorization", .value = std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}) catch return .{ .failure = "out of memory" } };
            extra_len = 1;
        },
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
        return .{ .failure = std.fmt.allocPrint(arena, "HTTP {d}", .{@backingInt(response.head.status)}) catch "HTTP error" };
    }

    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    const body = reader.allocRemaining(arena, .limited(max_body_bytes)) catch
        return .{ .failure = "response too large" };
    return .{ .body = body };
}

fn modelListUrl(arena: std.mem.Allocator, base_url: []const u8, style: Style) []const u8 {
    const base = if (std.mem.endsWith(u8, base_url, "/")) base_url[0 .. base_url.len - 1] else base_url;
    return switch (style) {
        .anthropic => std.fmt.allocPrint(arena, "{s}/v1/models?limit=100", .{base}) catch "",
        .gemini => std.fmt.allocPrint(arena, "{s}/models?pageSize=100", .{base}) catch "",
        .openai => std.fmt.allocPrint(arena, "{s}/models", .{base}) catch "",
    };
}

/// Parse one Gemini page `{"models":[{"name":"models/x",...}],"nextPageToken":".."}`
/// into `out` (capped at `max_models`) and return the next page token. Models
/// that declare `supportedGenerationMethods` without `generateContent`
/// (embedding models) are skipped.
fn parseGeminiPage(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayListUnmanaged(ModelEntry)) !?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidJson;
    if (v != .object) return error.UnexpectedShape;
    if (v.object.get("models")) |list| {
        if (list != .array) return error.UnexpectedShape;
        for (list.array.items) |item| {
            if (out.items.len >= max_models) break;
            if (item != .object) continue;
            const name = item.object.get("name") orelse continue;
            if (name != .string) continue;
            const id = if (std.mem.startsWith(u8, name.string, "models/")) name.string["models/".len..] else name.string;
            if (id.len == 0) continue;
            if (item.object.get("supportedGenerationMethods")) |methods| {
                if (methods == .array) {
                    var generates = false;
                    for (methods.array.items) |m| {
                        if (m == .string and std.mem.eql(u8, m.string, "generateContent")) generates = true;
                    }
                    if (!generates) continue;
                }
            }
            var entry = ModelEntry{ .id = try arena.dupe(u8, id) };
            if (item.object.get("inputTokenLimit")) |limit| {
                if (limit == .integer and limit.integer > 0) entry.context_length = @intCast(limit.integer);
            }
            try out.append(arena, entry);
        }
    }
    const next = v.object.get("nextPageToken") orelse return null;
    if (next != .string or next.string.len == 0) return null;
    return next.string;
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

    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/models", modelListUrl(a, "https://openrouter.ai/api/v1", .openai));
    try std.testing.expectEqualStrings("http://localhost:11434/v1/models", modelListUrl(a, "http://localhost:11434/v1/", .openai));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/models?limit=100", modelListUrl(a, "https://api.anthropic.com", .anthropic));
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models?pageSize=100", modelListUrl(a, "https://generativelanguage.googleapis.com/v1beta/", .gemini));
}

test "parse Gemini model pages: strip the models/ prefix, skip embedders, follow the token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: std.ArrayListUnmanaged(ModelEntry) = .empty;
    const t1 = try parseGeminiPage(a,
        \\{"models":[{"name":"models/gemini-2.5-pro","inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"p2"}
    , &out);
    try std.testing.expectEqualStrings("p2", t1.?);
    const t2 = try parseGeminiPage(a, "{\"models\":[{\"name\":\"models/gemini-2.5-flash\"}]}", &out);
    try std.testing.expect(t2 == null);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("gemini-2.5-pro", out.items[0].id);
    try std.testing.expectEqual(@as(u64, 1048576), out.items[0].context_length.?);
    try std.testing.expectEqualStrings("gemini-2.5-flash", out.items[1].id);

    try std.testing.expectError(error.InvalidJson, parseGeminiPage(a, "nope", &out));
    try std.testing.expectError(error.UnexpectedShape, parseGeminiPage(a, "{\"models\":3}", &out));
}
