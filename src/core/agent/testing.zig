//! Scripted fake provider for deterministic agent-loop tests (DESIGN §8,
//! DECISIONS U286/287). No network, no threads: each `stream` call consumes
//! the next script entry (looping on the last one).

const std = @import("std");
const core_types = @import("../types.zig");
const provider_mod = @import("../../providers/provider.zig");

pub const Action = union(enum) {
    text: []const u8,
    tool_call: struct { id: []const u8, name: []const u8, arguments_json: []const u8 },
    usage: core_types.Usage,
    failure: core_types.ProviderFailure,
};

pub const Script = []const []const Action;

pub const Fake = struct {
    script: Script,
    call_index: usize = 0,
    cancel_flag: std.atomic.Value(bool) = .init(false),

    pub fn provider(self: *Fake) provider_mod.Provider {
        return .{ .ctx = self, .stream_fn = streamFn };
    }
};

fn streamFn(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    io: std.Io,
    req: provider_mod.ModelRequest,
    sink: provider_mod.Sink,
) anyerror!void {
    _ = io;
    const self: *Fake = @ptrCast(@alignCast(ctx));
    if (self.call_index >= self.script.len) {
        sink.emit(.{ .failure = .{ .kind = .other, .message = "fake provider: script exhausted" } });
        return;
    }
    const actions = self.script[self.call_index];
    self.call_index += 1;

    for (actions) |action| {
        if (req.cancel.load(.acquire)) {
            sink.emit(.{ .failure = .{ .kind = .cancelled, .message = "cancelled" } });
            return;
        }
        switch (action) {
            .text => |t| {
                const duped = try alloc.dupe(u8, t);
                sink.emit(.{ .content_delta = duped });
            },
            .tool_call => |tc| sink.emit(.{ .tool_call = .{
                .id = tc.id,
                .name = tc.name,
                .arguments_json = tc.arguments_json,
            } }),
            .usage => |u| sink.emit(.{ .usage = u }),
            .failure => |f| sink.emit(.{ .failure = f }),
        }
    }
    sink.emit(.done);
}

test "fake provider streams its script" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake = Fake{
        .script = &.{
            &.{
                .{ .text = "hello " }, // first call: text only
            },
            &.{ .{ .tool_call = .{ .id = "t1", .name = "read", .arguments_json = "{\"path\":\"x\"}" } }, .{ .usage = .{ .input_tokens = 3, .output_tokens = 4 } } },
        },
    };
    const p = fake.provider();

    var sink_events: usize = 0;
    const SinkCtx = struct {
        count: *usize,
        fn emit(ctx: *anyopaque, ev: core_types.StreamEvent) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.count.* += 1;
            _ = ev;
        }
    };
    var sctx = SinkCtx{ .count = &sink_events };
    var cancel = std.atomic.Value(bool).init(false);

    try p.stream(arena_state.allocator(), std.testing.io, .{
        .model = "fake",
        .base_url = "",
        .api_key = "",
        .system = "",
        .messages = &.{},
        .cancel = &cancel,
    }, .{ .ctx = &sctx, .emit_fn = SinkCtx.emit });
    try std.testing.expect(fake.call_index == 1);
    try std.testing.expect(sink_events >= 2); // content_delta + done
}
