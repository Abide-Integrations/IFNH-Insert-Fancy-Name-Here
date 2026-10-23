//! HTTP transport policy shared by provider adapters.
//!
//! Adapters use this module to open connections with a shared connect policy
//! and bounded idle timeouts, classify thrown transport errors into provider
//! failures, and parse `Retry-After` response headers. Keeping the policy here
//! avoids duplicating it in each adapter.

const std = @import("std");
const builtin = @import("builtin");
const core_types = @import("../core/types.zig");

pub const Limits = struct {
    /// TCP/TLS connection setup deadline forwarded to `std.http`.
    /// Zig 0.16 currently ignores this option inside `connectTcpOptions`;
    /// keep it set so the policy is correct once std honors it.
    connect_s: u32 = 10,
    /// Socket read/write idle deadline. Zero disables it.
    idle_s: u32 = 120,
};

pub const default_limits: Limits = .{};

/// Open a connection for `uri` with the shared transport policy. The caller
/// owns the returned connection; releasing it through `Request.deinit` (or
/// `Client.connection_pool.release` on a request-construction failure) is
/// required. `connect_s` is forwarded to `std.http`; idle read/write
/// deadlines are applied to the socket.
pub fn openConnection(
    client: *std.http.Client,
    uri: std.Uri,
    limits: Limits,
) !*std.http.Client.Connection {
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse
        return error.UnsupportedUriScheme;
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    const connection = try client.connectTcpOptions(.{
        .host = host,
        .port = port,
        .protocol = protocol,
        .timeout = timeoutFromSeconds(limits.connect_s),
    });
    applyIdleTimeout(connection, limits.idle_s);
    return connection;
}

fn timeoutFromSeconds(seconds: u32) std.Io.Timeout {
    if (seconds == 0) return .none;
    return .{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(seconds)),
        .clock = .real,
    } };
}

/// Set SO_RCVTIMEO/SO_SNDTIMEO on the connected socket so a stalled peer
/// cannot hold a stream open forever. Unsupported platforms are left to the
/// caller's cancellation policy.
fn applyIdleTimeout(connection: *std.http.Client.Connection, seconds: u32) void {
    if (seconds == 0) return;
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            const tv: std.posix.timeval = .{
                .sec = @intCast(seconds),
                .usec = 0,
            };
            const handle = connection.stream_reader.stream.socket.handle;
            std.posix.setsockopt(
                handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
            std.posix.setsockopt(
                handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.SNDTIMEO,
                std.mem.asBytes(&tv),
            ) catch {};
        },
    }
}

/// Classify an error thrown by `std.http` or the socket layer. `ReadFailed`
/// and `WriteFailed` are wrappers: pass them through `failureFor` when a
/// connection is available so the underlying cause can be reported.
pub fn failureKindForError(err: anyerror) core_types.ProviderFailureKind {
    return switch (err) {
        error.Canceled => .cancelled,
        error.Timeout, error.WouldBlock => .timeout,
        error.UnsupportedUriScheme => .invalid_request,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => .network,
        error.StreamTooLong, error.OutOfMemory => .other,
        else => .other,
    };
}

/// Build a failure event for a thrown transport error, unwrapping the
/// socket-layer cause carried by `error.ReadFailed`/`error.WriteFailed`.
pub fn failureFor(
    err: anyerror,
    connection: ?*std.http.Client.Connection,
) core_types.ProviderFailure {
    var cause = err;
    if (err == error.ReadFailed) {
        if (connection) |conn| {
            if (conn.getReadError()) |read_err| cause = read_err;
        }
    } else if (err == error.WriteFailed) {
        if (connection) |conn| {
            if (conn.stream_writer.err) |write_err| cause = write_err;
        }
    }
    return .{
        .kind = failureKindForError(cause),
        .message = if (cause == error.WouldBlock) "request timed out" else @errorName(cause),
    };
}

/// Read the `Retry-After` header from a response head. Accepts either
/// delta-seconds or an HTTP-date and returns seconds from `now_unix_s`.
pub fn retryAfterFromHead(
    head: std.http.Client.Response.Head,
    now_unix_s: i64,
) ?u32 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            return parseRetryAfter(header.value, now_unix_s);
        }
    }
    return null;
}

/// Parse a `Retry-After` value. `now_unix_s` is only used for HTTP-date
/// values; delta-seconds are returned unchanged. Invalid values return null.
/// A date in the past yields zero. Large deltas saturate at `u32` max.
pub fn parseRetryAfter(value: []const u8, now_unix_s: i64) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.fmt.parseInt(u64, trimmed, 10)) |seconds| {
        return @intCast(@min(seconds, std.math.maxInt(u32)));
    } else |_| {}

    const unix_seconds = parseHttpDate(trimmed) orelse return null;
    const delta = unix_seconds - now_unix_s;
    if (delta <= 0) return 0;
    return @intCast(@min(@as(u64, @intCast(delta)), std.math.maxInt(u32)));
}

fn parseHttpDate(value: []const u8) ?i64 {
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT
    if (std.mem.findScalar(u8, value, ',')) |comma| {
        const rest = std.mem.trim(u8, value[comma + 1 ..], " \t");
        if (std.mem.findScalar(u8, rest, '-') != null) {
            // RFC 850: Sunday, 06-Nov-94 08:49:37 GMT
            var tokens = std.mem.tokenizeAny(u8, rest, " -");
            const day = parseIntToken(tokens.next()) orelse return null;
            const month = parseMonth(tokens.next()) orelse return null;
            var year = parseIntToken(tokens.next()) orelse return null;
            const clock = parseClock(tokens.next()) orelse return null;
            _ = tokens.next(); // GMT
            if (year < 100) year += if (year >= 70) 1900 else 2000;
            return dateToUnix(year, month, day, clock);
        }

        // IMF-fixdate.
        var tokens = std.mem.tokenizeAny(u8, rest, " \t");
        const day = parseIntToken(tokens.next()) orelse return null;
        const month = parseMonth(tokens.next()) orelse return null;
        const year = parseIntToken(tokens.next()) orelse return null;
        const clock = parseClock(tokens.next()) orelse return null;
        _ = tokens.next(); // GMT
        return dateToUnix(year, month, day, clock);
    }

    // asctime: Sun Nov  6 08:49:37 1994
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    _ = tokens.next(); // weekday
    const month = parseMonth(tokens.next()) orelse return null;
    const day = parseIntToken(tokens.next()) orelse return null;
    const clock = parseClock(tokens.next()) orelse return null;
    const year = parseIntToken(tokens.next()) orelse return null;
    return dateToUnix(year, month, day, clock);
}

const Clock = struct {
    hour: u32,
    minute: u32,
    second: u32,
};

fn parseClock(token: ?[]const u8) ?Clock {
    const text = token orelse return null;
    var parts = std.mem.splitScalar(u8, text, ':');
    const hour = parseIntToken(parts.next()) orelse return null;
    const minute = parseIntToken(parts.next()) orelse return null;
    const second = parseIntToken(parts.next()) orelse return null;
    if (parts.next() != null) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return .{ .hour = hour, .minute = minute, .second = second };
}

fn parseIntToken(token: ?[]const u8) ?u32 {
    const text = token orelse return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn parseMonth(token: ?[]const u8) ?u32 {
    const text = token orelse return null;
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 1..) |name, i| {
        if (std.ascii.eqlIgnoreCase(text, name)) return @intCast(i);
    }
    return null;
}

fn dateToUnix(year: u32, month: u32, day: u32, clock: Clock) ?i64 {
    if (year < 1970 or month < 1 or month > 12 or day < 1) return null;
    const max_day: u32 = switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    if (day > max_day) return null;
    const days = daysFromCivil(@intCast(year), month, day);
    return days * 86_400 + @as(i64, clock.hour) * 3600 +
        @as(i64, clock.minute) * 60 + @as(i64, clock.second);
}

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`, handles leap years without a table).
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = (month + 9) % 12; // March = 0
    const doy = @divFloor(153 * @as(i64, mp) + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// ---------------------------------------------------------------- tests

test "Retry-After delta seconds" {
    try std.testing.expectEqual(@as(?u32, 5), parseRetryAfter("5", 1_000_000));
    try std.testing.expectEqual(@as(?u32, 0), parseRetryAfter("  0\t", 1_000_000));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), parseRetryAfter("999999999999", 0));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("later", 0));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("", 0));
}

test "Retry-After IMF-fixdate" {
    // Sun, 06 Nov 1994 08:49:37 GMT == 784111777
    try std.testing.expectEqual(
        @as(?u32, 30),
        parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111747),
    );
    try std.testing.expectEqual(
        @as(?u32, 0),
        parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111777),
    );
    try std.testing.expectEqual(
        @as(?u32, 0),
        parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111800),
    );
    // Leap day.
    try std.testing.expectEqual(
        @as(?u32, 60),
        parseRetryAfter("Tue, 29 Feb 2000 12:00:00 GMT", 951_825_540),
    );
}

test "Retry-After legacy dates" {
    // RFC 850 and asctime spellings of the same instant.
    try std.testing.expectEqual(
        @as(?u32, 10),
        parseRetryAfter("Sunday, 06-Nov-94 08:49:37 GMT", 784111767),
    );
    try std.testing.expectEqual(
        @as(?u32, 10),
        parseRetryAfter("Sun Nov  6 08:49:37 1994", 784111767),
    );
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("Sun, 32 Nov 1994 08:49:37 GMT", 0));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("Sun, 31 Feb 1994 08:49:37 GMT", 0));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter("Sun, 06 Foo 1994 08:49:37 GMT", 0));
}

test "transport error classification" {
    try std.testing.expectEqual(
        core_types.ProviderFailureKind.timeout,
        failureKindForError(error.Timeout),
    );
    try std.testing.expectEqual(
        core_types.ProviderFailureKind.network,
        failureKindForError(error.ConnectionRefused),
    );
    try std.testing.expectEqual(
        core_types.ProviderFailureKind.cancelled,
        failureKindForError(error.Canceled),
    );
    const failure = failureFor(error.ConnectionRefused, null);
    try std.testing.expectEqual(core_types.ProviderFailureKind.network, failure.kind);
    try std.testing.expectEqualStrings("ConnectionRefused", failure.message);
}
