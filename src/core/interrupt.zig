//! Ctrl-C cancellation (A-06, F-A06).
//!
//! While a turn runs, SIGINT sets the turn's cancel flag and every blocking
//! loop (SSE reads, captured commands) notices it within a slice. A second
//! Ctrl-C hard-exits with the conventional 130. Outside a turn the default
//! action is restored, so Ctrl-C at the prompt behaves normally.
//!
//! Esc-to-stop needs raw-mode key handling and belongs to the TUI work.

const std = @import("std");
const builtin = @import("builtin");

var active: ?*std.atomic.Value(bool) = null;
var presses = std.atomic.Value(u32).init(0);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (active) |cancel| cancel.store(true, .release);
    // Async-signal-safe: a syscall, no allocation, no locks.
    if (presses.fetchAdd(1, .acq_rel) + 1 >= 2) std.process.exit(130);
}

/// Route SIGINT to `cancel` until `uninstall` is called. No-op on Windows
/// (console control handlers are a separate port).
pub fn install(cancel: *std.atomic.Value(bool)) void {
    if (builtin.os.tag == .windows) return;
    active = cancel;
    presses.store(0, .release);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
}

/// Restore the default SIGINT action (SIG_DFL).
pub fn uninstall() void {
    if (builtin.os.tag == .windows) return;
    active = null;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
}

test "install and uninstall do not trap" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cancel = std.atomic.Value(bool).init(false);
    install(&cancel);
    uninstall();
    try std.testing.expect(!cancel.load(.acquire));
    // The default action is back; the flag is no longer routed.
    try std.testing.expect(active == null);
}
