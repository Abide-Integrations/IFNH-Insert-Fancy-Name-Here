//! `ifnh update` (F-04): a deliberate refusal. IFNH never replaces its own
//! binary; the package manager (or install.sh) owns upgrades and removal.
//!
//! Reads nothing but the executable path: no network, no writes, no config.

const std = @import("std");

const Route = enum { homebrew, snap, nix, system, installer };

fn routeFor(exe_path: []const u8) Route {
    const has = std.mem.indexOf;
    if (has(u8, exe_path, "/Cellar/") != null or has(u8, exe_path, "/homebrew/") != null) return .homebrew;
    if (has(u8, exe_path, "/snap/") != null) return .snap;
    if (has(u8, exe_path, "/nix/store/") != null) return .nix;
    if (std.mem.startsWith(u8, exe_path, "/usr/bin/") or std.mem.startsWith(u8, exe_path, "/bin/")) return .system;
    return .installer;
}

/// Print the refusal to `err` and return the process exit code (always 1).
/// `exe_path` is only inspected to pick the upgrade route to name.
pub fn run(err: *std.Io.Writer, exe_path: []const u8) u8 {
    const route: []const u8 = switch (routeFor(exe_path)) {
        .homebrew => "brew upgrade ifnh",
        .snap => "sudo snap refresh ifnh",
        .nix => "your Nix profile (for example: nix profile upgrade)",
        .system => "your system package manager (apt, dnf, pacman)",
        .installer => "re-run install.sh, or download the latest release from GitHub",
    };
    err.print("ifnh: update is disabled; IFNH does not self-update.\nupgrade with: {s}\n", .{route}) catch {};
    return 1;
}

test "refusal names the route for the binary location and exits 1" {
    const cases = [_]struct { path: []const u8, route: []const u8 }{
        .{ .path = "/opt/homebrew/Cellar/ifnh/0.1.7/bin/ifnh", .route = "brew upgrade ifnh" },
        .{ .path = "/snap/ifnh/current/bin/ifnh", .route = "sudo snap refresh ifnh" },
        .{ .path = "/nix/store/abc-ifnh/bin/ifnh", .route = "your Nix profile (for example: nix profile upgrade)" },
        .{ .path = "/usr/bin/ifnh", .route = "your system package manager (apt, dnf, pacman)" },
        .{ .path = "/home/u/.local/bin/ifnh", .route = "re-run install.sh, or download the latest release from GitHub" },
        .{ .path = "", .route = "re-run install.sh, or download the latest release from GitHub" },
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.testing.expectEqual(@as(u8, 1), run(&w, c.path));
        var want: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&want, "ifnh: update is disabled; IFNH does not self-update.\nupgrade with: {s}\n", .{c.route});
        try std.testing.expectEqualStrings(text, w.buffered());
    }
}
