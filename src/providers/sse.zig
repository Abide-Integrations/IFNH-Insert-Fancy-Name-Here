//! SSE (server-sent events) parsing over a std.Io.Reader (DECISIONS U278).
//!
//! Bounded: an event larger than `max_event_bytes` is an error; the caller
//! supplies the arena for the returned payload.

const std = @import("std");

pub const max_event_bytes_default: usize = 1024 * 1024;

pub const Error = error{
    StreamTooLong,
    ReadFailed,
    EndOfStream,
    OutOfMemory,
};

/// Stateful SSE parser wrapping a byte reader.
pub const Parser = struct {
    reader: *std.Io.Reader,
    max_event_bytes: usize = max_event_bytes_default,

    /// Returns the next event's data payload, or null at stream end.
    /// Comment lines (`:`), `event:`/`id:`/`retry:` fields are ignored for
    /// our use case (providers only use `data:`). Multi-line `data:` fields
    /// are joined with newlines. A torn tail (no final newline) still
    /// yields its data.
    pub fn next(self: *Parser, arena: std.mem.Allocator) Error!?[]const u8 {
        var data: std.ArrayListUnmanaged(u8) = .empty;

        while (true) {
            // Read one line, bounded.
            var line: std.ArrayListUnmanaged(u8) = .empty;
            var torn = false;
            while (true) {
                const b = self.reader.takeByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        torn = true;
                        break;
                    },
                    else => return error.ReadFailed,
                };
                if (b == '\n') break;
                if (line.items.len + data.items.len >= self.max_event_bytes) return error.StreamTooLong;
                line.append(arena, b) catch return error.OutOfMemory;
            }

            var l = line.items;
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];

            if (l.len == 0) {
                if (torn) {
                    if (data.items.len > 0) return try arena.dupe(u8, data.items);
                    return null;
                }
                // Empty line = event boundary.
                if (data.items.len > 0) return try arena.dupe(u8, data.items);
                continue; // stray boundary between events
            }

            if (l[0] == ':') {
                if (torn and data.items.len > 0) return try arena.dupe(u8, data.items);
                continue; // comment/keepalive
            }

            if (std.mem.startsWith(u8, l, "data:")) {
                var payload = l["data:".len..];
                if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
                if (data.items.len > 0) data.append(arena, '\n') catch return error.OutOfMemory;
                data.appendSlice(arena, payload) catch return error.OutOfMemory;
                if (data.items.len > self.max_event_bytes) return error.StreamTooLong;
            }
            // event:/id:/retry: fields ignored.

            if (torn) {
                if (data.items.len > 0) return try arena.dupe(u8, data.items);
                return null;
            }
        }
    }
};

// ---------------------------------------------------------------- tests

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "parses simple data events" {
    var stream = std.Io.Reader.fixed("data: hello\n\ndata: world\n\n");
    var p = Parser{ .reader = &stream };
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello", (try p.next(a)).?);
    try std.testing.expectEqualStrings("world", (try p.next(a)).?);
    try std.testing.expect(try p.next(a) == null);
}

test "parses CRLF and ignores comments and other fields" {
    var stream = std.Io.Reader.fixed(": keepalive\r\nevent: message\r\ndata: one\r\n\r\ndata: two\r\n\r\n");
    var p = Parser{ .reader = &stream };
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("one", (try p.next(a)).?);
    try std.testing.expectEqualStrings("two", (try p.next(a)).?);
    try std.testing.expect(try p.next(a) == null);
}

test "multi-line data joined with newline" {
    var stream = std.Io.Reader.fixed("data: a\ndata: b\n\n");
    var p = Parser{ .reader = &stream };
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\nb", (try p.next(a)).?);
}

test "event too large" {
    var stream = std.Io.Reader.fixed("data: " ++ "x" ** 32 ++ "\n\n");
    var p = Parser{ .reader = &stream, .max_event_bytes = 8 };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.StreamTooLong, p.next(arena_state.allocator()));
}

test "torn stream yields partial event" {
    var stream = std.Io.Reader.fixed("data: partial");
    var p = Parser{ .reader = &stream };
    var arena = testArena();
    defer arena.deinit();
    const e = try p.next(arena.allocator());
    try std.testing.expectEqualStrings("partial", e.?);
}
