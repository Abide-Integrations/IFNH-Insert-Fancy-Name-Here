//! Single source of truth for the IFNH application version.
//! Keep this the only place the release version appears.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const version = "0.1.7";

pub const user_agent = "ifnh/" ++ version;

/// Short git commit the binary was built from (`-Dcommit=<sha>` overrides
/// the `git rev-parse` done by build.zig); `unknown` without a checkout.
pub const commit: []const u8 = build_options.commit;

/// `<arch>-<os>[-<abi>]`, e.g. `x86_64-linux-musl`, `aarch64-macos`.
pub const target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++
    (if (builtin.abi == .none) "" else "-" ++ @tagName(builtin.abi));

/// `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`.
pub const mode = @tagName(builtin.mode);

/// The `ifnh version --verbose` text. Caller owns the result.
pub fn verbose(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return formatVerbose(allocator, commit, target, mode);
}

fn formatVerbose(allocator: std.mem.Allocator, c: []const u8, t: []const u8, m: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "ifnh {s}\ncommit: {s}\ntarget: {s}\nmode: {s}\n", .{ version, c, t, m });
}

test "verbose formatter prints the four documented lines" {
    const text = try formatVerbose(std.testing.allocator, "abc1234", "x86_64-linux-musl", "ReleaseSafe");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ifnh " ++ version ++ "\ncommit: abc1234\ntarget: x86_64-linux-musl\nmode: ReleaseSafe\n", text);
}

test "build-derived fields are non-empty and well formed" {
    const text = try verbose(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(commit.len > 0);
    try std.testing.expect(std.mem.count(u8, target, "-") >= 1);
    try std.testing.expect(std.mem.indexOf(u8, text, "mode: " ++ mode ++ "\n") != null);
}
