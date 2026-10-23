//! Model price table and cost estimation (C-06, DECISIONS D51).
//!
//! Prices are data, not policy: the table is loaded from a JSON file at
//! runtime. Resolution order is `$IFNH_PRICING_FILE`, then
//! `$XDG_CONFIG_HOME/ifnh/pricing.json`, then `.ifnh/pricing.json`, then the
//! table shipped with the binary (`pricing.json` beside this file).
//!
//! Rates are USD per million tokens. `fallback` applies to models the table
//! does not name; without it an unknown model has no estimate (cost `null`),
//! never a guessed zero.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const config_mod = @import("../config/config.zig");
const core_types = @import("../types.zig");

pub const max_pricing_bytes: usize = 256 * 1024;

pub const Rates = struct {
    input_per_mtok: f64 = 0,
    output_per_mtok: f64 = 0,
    cache_read_per_mtok: f64 = 0,
    cache_write_per_mtok: f64 = 0,
};

pub const Table = struct {
    models: std.StringHashMapUnmanaged(Rates) = .empty,
    fallback: ?Rates = null,

    /// Rates for `model`, or the configured fallback, or null when neither
    /// exists (unknown model).
    pub fn ratesFor(self: *const Table, model: []const u8) ?Rates {
        return self.models.get(model) orelse self.fallback;
    }

    /// Estimated USD for one usage record. Returns null for an unknown model
    /// without a fallback; the token counts are still valid.
    pub fn estimateUsd(self: *const Table, model: []const u8, usage: core_types.Usage) ?f64 {
        const r = self.ratesFor(model) orelse return null;
        const input: f64 = @floatFromInt(usage.input_tokens);
        const output: f64 = @floatFromInt(usage.output_tokens);
        const cache_read: f64 = @floatFromInt(usage.cache_read_tokens);
        const cache_write: f64 = @floatFromInt(usage.cache_write_tokens);
        return (input * r.input_per_mtok +
            output * r.output_per_mtok +
            cache_read * r.cache_read_per_mtok +
            cache_write * r.cache_write_per_mtok) / 1_000_000.0;
    }

    pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Table {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{});
        if (root != .object) return error.InvalidPricing;
        const models_v = root.object.get("models") orelse return error.InvalidPricing;
        if (models_v != .object) return error.InvalidPricing;

        var table = Table{};
        var it = models_v.object.iterator();
        while (it.next()) |entry| {
            try table.models.put(
                alloc,
                try alloc.dupe(u8, entry.key_ptr.*),
                try parseRates(entry.value_ptr.*),
            );
        }
        if (root.object.get("fallback")) |v| {
            if (v != .null) table.fallback = try parseRates(v);
        }
        return table;
    }

    /// Load a table from an explicit file path.
    pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Table {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_pricing_bytes));
        return parse(alloc, text);
    }

    /// Load the table shipped with the binary.
    pub fn loadDefault(alloc: std.mem.Allocator) !Table {
        return parse(alloc, @embedFile("pricing.json"));
    }

    /// Load the first available table for this workspace. A malformed
    /// explicit file is an error; a malformed optional layer is not silently
    /// replaced, so the caller can warn and decide.
    pub fn loadForWorkspace(
        alloc: std.mem.Allocator,
        io: std.Io,
        environ: ?*const std.process.Environ.Map,
        project_dir: ?std.Io.Dir,
    ) !Table {
        if (environ) |e| {
            if (e.get("IFNH_PRICING_FILE")) |path| {
                if (path.len > 0) return loadFile(alloc, io, path);
            }
        }
        if (config_mod.userConfigDir(alloc, environ)) |dir| {
            const path = try std.fmt.allocPrint(alloc, "{s}/pricing.json", .{dir});
            if (fsutil.fileExists(std.Io.Dir.cwd(), io, path)) return loadFile(alloc, io, path);
        }
        if (project_dir) |dir| {
            if (fsutil.fileExists(dir, io, ".ifnh/pricing.json")) {
                return loadFromDir(alloc, io, dir, ".ifnh/pricing.json");
            }
        }
        return loadDefault(alloc);
    }

    fn loadFromDir(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !Table {
        const text = try dir.readFileAlloc(io, sub_path, alloc, .limited(max_pricing_bytes));
        return parse(alloc, text);
    }
};

fn parseRates(v: std.json.Value) !Rates {
    if (v != .object) return error.InvalidPricing;
    const o = v.object;
    const rates = Rates{
        .input_per_mtok = try rate(o.get("input_per_mtok")),
        .output_per_mtok = try rate(o.get("output_per_mtok")),
        .cache_read_per_mtok = try rate(o.get("cache_read_per_mtok")),
        .cache_write_per_mtok = try rate(o.get("cache_write_per_mtok")),
    };
    return rates;
}

fn rate(v: ?std.json.Value) !f64 {
    const value = v orelse return 0;
    const n: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidPricing,
    };
    if (n < 0 or !std.math.isFinite(n)) return error.InvalidPricing;
    return n;
}

// ---------------------------------------------------------------- tests

test "price lookup, unknown-model fallback, and per-million math" {
    const json =
        \\{
        \\  "models": {
        \\    "priced-model": {
        \\      "input_per_mtok": 3,
        \\      "output_per_mtok": 15,
        \\      "cache_read_per_mtok": 0.3,
        \\      "cache_write_per_mtok": 3.75
        \\    }
        \\  },
        \\  "fallback": {
        \\    "input_per_mtok": 1,
        \\    "output_per_mtok": 2,
        \\    "cache_read_per_mtok": 0.1,
        \\    "cache_write_per_mtok": 0.2
        \\  }
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try Table.parse(arena, json);
    const priced = table.ratesFor("priced-model").?;
    try std.testing.expectEqual(@as(f64, 3), priced.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 15), priced.output_per_mtok);
    try std.testing.expectEqual(@as(f64, 0.3), priced.cache_read_per_mtok);
    try std.testing.expectEqual(@as(f64, 3.75), priced.cache_write_per_mtok);

    const unknown = table.ratesFor("not-in-the-table").?;
    try std.testing.expectEqual(@as(f64, 1), unknown.input_per_mtok);
    try std.testing.expectEqual(@as(f64, 2), unknown.output_per_mtok);

    const usage: core_types.Usage = .{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cache_read_tokens = 1_000_000,
        .cache_write_tokens = 1_000_000,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 22.05), table.estimateUsd("priced-model", usage).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), table.estimateUsd("other", usage).?, 0.000001);
}

test "unknown model without fallback has no cost estimate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table = try Table.parse(arena,
        \\{ "models": { "known": { "input_per_mtok": 1, "output_per_mtok": 1 } } }
    );
    try std.testing.expect(table.ratesFor("unknown") == null);
    try std.testing.expect(table.estimateUsd("unknown", .{ .input_tokens = 100 }) == null);
    try std.testing.expectEqual(@as(f64, 0.0001), table.estimateUsd("known", .{ .input_tokens = 100 }).?);
}

test "price table loads from a JSON data file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pricing.json", .data =
        \\{ "models": { "file-model": { "input_per_mtok": 5, "output_per_mtok": 7 } } }
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try tmp.dir.readFileAlloc(io, "pricing.json", arena, .limited(max_pricing_bytes));
    const table = try Table.parse(arena, text);
    try std.testing.expectEqual(@as(f64, 5), table.ratesFor("file-model").?.input_per_mtok);
    try std.testing.expect(table.ratesFor("missing") == null);
}

test "bad pricing data is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidPricing, Table.parse(arena, "[]"));
    try std.testing.expectError(error.InvalidPricing, Table.parse(arena, "{\"models\":{\"m\":{\"input_per_mtok\":-1}}}"));
}
