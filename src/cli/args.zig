//! CLI argument parsing (pure, table-driven, fully testable — no I/O).
//!
//! Grammar: `ifnh [global-flags] <subcommand> [subcommand-args...]`
//! Flags are kebab-case (fx convention). Unknown flags are errors, not
//! silently ignored values.

const std = @import("std");

pub const LogLevel = enum { err, info, debug, trace };

pub const GlobalFlags = struct {
    json: bool = false,
    no_color: bool = false,
    log_level: LogLevel = .info,
    help: bool = false,
    version: bool = false,
};

pub const Subcommand = enum {
    none,
    help,
    version,
    init,
    config,
    sessions,
    /// `resume` is a Zig keyword; quote the tag.
    @"resume",
    doctor,
    fork,
    cleanup,
    unknown,
};

pub const Parsed = struct {
    flags: GlobalFlags = .{},
    subcommand: Subcommand = .none,
    /// Raw arguments after the subcommand token; owned by the caller's
    /// backing memory (here: the caller-provided argv slice).
    args: []const []const u8 = &.{},
};

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
};

pub fn parse(argv: []const []const u8) ParseError!Parsed {
    var result = Parsed{};
    var i: usize = 0;

    // Global flags may appear before the subcommand.
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!std.mem.startsWith(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.flags.json = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            result.flags.no_color = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= argv.len) return error.MissingFlagValue;
            result.flags.log_level = std.meta.stringToEnum(LogLevel, argv[i]) orelse
                return error.UnknownFlag;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.flags.help = true;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            result.flags.version = true;
        } else {
            return error.UnknownFlag;
        }
    }

    if (i >= argv.len) return result;

    const cmd_name = argv[i];
    i += 1;

    result.subcommand = if (std.mem.eql(u8, cmd_name, "help"))
        .help
    else if (std.mem.eql(u8, cmd_name, "version"))
        .version
    else if (std.mem.eql(u8, cmd_name, "init"))
        .init
    else if (std.mem.eql(u8, cmd_name, "config"))
        .config
    else if (std.mem.eql(u8, cmd_name, "sessions"))
        .sessions
    else if (std.mem.eql(u8, cmd_name, "resume"))
        .@"resume"
    else if (std.mem.eql(u8, cmd_name, "doctor"))
        .doctor
    else if (std.mem.eql(u8, cmd_name, "fork"))
        .fork
    else if (std.mem.eql(u8, cmd_name, "cleanup"))
        .cleanup
    else
        .unknown;

    result.args = argv[i..];
    return result;
}

test "parse bare invocation" {
    const p = try parse(&.{});
    try std.testing.expectEqual(Subcommand.none, p.subcommand);
    try std.testing.expect(!p.flags.json);
}

test "parse global flags then subcommand with args" {
    const p = try parse(&.{ "--json", "--log-level", "debug", "config", "explain", "model" });
    try std.testing.expect(p.flags.json);
    try std.testing.expectEqual(LogLevel.debug, p.flags.log_level);
    try std.testing.expectEqual(Subcommand.config, p.subcommand);
    try std.testing.expectEqual(@as(usize, 2), p.args.len);
    try std.testing.expectEqualStrings("explain", p.args[0]);
}

test "parse -V and -h" {
    try std.testing.expectEqual(Subcommand.none, (try parse(&.{"-V"})).subcommand);
    try std.testing.expect((try parse(&.{"-V"})).flags.version);
    try std.testing.expect((try parse(&.{"-h"})).flags.help);
}

test "unknown flag is an error" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--bogus"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--log-level"}));
}

test "unknown subcommand captures args" {
    const p = try parse(&.{ "frobnicate", "a", "b" });
    try std.testing.expectEqual(Subcommand.unknown, p.subcommand);
    try std.testing.expectEqual(@as(usize, 2), p.args.len);
}
