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
    /// `-p "<prompt>"` before the subcommand: headless one-shot prompt,
    /// the same thing as `ifnh ask -p "<prompt>"` (C-02).
    prompt: ?[]const u8 = null,
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
    /// `ifnh ask "<prompt>"`: headless one-shot turn (C-02).
    ask,
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
    InvalidFlagValue,
    ConflictingFlags,
    TooManyArguments,
};

/// Default decision for headless permission asks (`ifnh ask --policy`).
pub const ApprovalPolicy = enum { ask, allow, deny };

/// `ifnh ask` flags. Pure data: the headless driver owns the I/O.
pub const AskArgs = struct {
    /// The prompt; null means "read stdin until EOF" (also spelled `-`).
    prompt: ?[]const u8 = null,
    /// The prompt was explicitly `-`, so a global `-p` must not override it.
    stdin: bool = false,
    /// NDJSON events on stdout instead of plain assistant text.
    json: bool = false,
    /// Auto-approve every permission ask (approved_once semantics).
    yes: bool = false,
    /// Auto-deny every permission ask.
    deny_all: bool = false,
    /// Explicit `--policy`; null means the default (`ask`).
    policy: ?ApprovalPolicy = null,
};

fn parseGlobal(argv: []const []const u8, i: *usize, result: *Parsed) ParseError!void {
    const arg = argv[i.*];
    if (std.mem.eql(u8, arg, "--json")) {
        result.flags.json = true;
    } else if (std.mem.eql(u8, arg, "--no-color")) {
        result.flags.no_color = true;
    } else if (std.mem.eql(u8, arg, "--log-level")) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        result.flags.log_level = std.meta.stringToEnum(LogLevel, argv[i.*]) orelse
            return error.UnknownFlag;
    } else if (std.mem.eql(u8, arg, "-p")) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        result.flags.prompt = argv[i.*];
    } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        result.flags.help = true;
    } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
        result.flags.version = true;
    } else {
        return error.UnknownFlag;
    }
}

pub fn parse(argv: []const []const u8) ParseError!Parsed {
    var result = Parsed{};
    var i: usize = 0;

    // Global flags may appear before the subcommand.
    while (i < argv.len) : (i += 1) {
        if (!std.mem.startsWith(u8, argv[i], "-")) break;
        if (std.mem.eql(u8, argv[i], "--")) {
            i += 1;
            break;
        }
        try parseGlobal(argv, &i, &result);
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
    else if (std.mem.eql(u8, cmd_name, "ask"))
        .ask
    else
        .unknown;

    result.args = argv[i..];
    return result;
}

const AskFlag = enum { json, yes, deny_all, policy, prompt };

const ask_flag_table = [_]struct { name: []const u8, flag: AskFlag }{
    .{ .name = "--json", .flag = .json },
    .{ .name = "--yes", .flag = .yes },
    .{ .name = "--deny-all", .flag = .deny_all },
    .{ .name = "--policy", .flag = .policy },
    .{ .name = "-p", .flag = .prompt },
};

/// Parse the flags and prompt of `ifnh ask`. Exactly one prompt may be given:
/// a positional argument, `-p <prompt>`, or neither (stdin). `--yes`,
/// `--deny-all` and `--policy` are mutually exclusive.
pub fn parseAsk(args: []const []const u8) ParseError!AskArgs {
    var out = AskArgs{};
    var positional: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // A lone "-" is the stdin prompt, not a flag.
        if (arg.len > 1 and arg[0] == '-') {
            const flag = for (ask_flag_table) |entry| {
                if (std.mem.eql(u8, entry.name, arg)) break entry.flag;
            } else return error.UnknownFlag;
            switch (flag) {
                .json => out.json = true,
                .yes => out.yes = true,
                .deny_all => out.deny_all = true,
                .policy => {
                    i += 1;
                    if (i >= args.len) return error.MissingFlagValue;
                    out.policy = std.meta.stringToEnum(ApprovalPolicy, args[i]) orelse
                        return error.InvalidFlagValue;
                },
                .prompt => {
                    i += 1;
                    if (i >= args.len) return error.MissingFlagValue;
                    if (out.prompt != null) return error.TooManyArguments;
                    out.prompt = args[i];
                },
            }
            continue;
        }
        if (positional != null) return error.TooManyArguments;
        positional = arg;
    }
    if (positional) |p| {
        if (out.prompt != null) return error.TooManyArguments;
        out.prompt = p;
    }
    // A literal "-" (or no prompt at all) means the prompt arrives on stdin.
    if (out.prompt) |p| {
        if (std.mem.eql(u8, p, "-")) {
            out.prompt = null;
            out.stdin = true;
        }
    }
    const approval_flags = @as(u8, @intFromBool(out.yes)) +
        @as(u8, @intFromBool(out.deny_all)) +
        @as(u8, @intFromBool(out.policy != null));
    if (approval_flags > 1) return error.ConflictingFlags;
    return out;
}

/// Resolve the effective `ask` prompt: a subcommand prompt wins, an explicit
/// `-` suppresses the global `-p`, and otherwise the global shorthand applies.
pub fn resolveAskPrompt(global: ?[]const u8, ask: AskArgs) ?[]const u8 {
    if (ask.prompt) |p| return p;
    if (ask.stdin) return null;
    const g = global orelse return null;
    if (std.mem.eql(u8, g, "-")) return null;
    return g;
}

test "parse bare invocation" {
    const p = try parse(&.{});
    try std.testing.expectEqual(Subcommand.none, p.subcommand);
    try std.testing.expect(!p.flags.json);
    try std.testing.expect(p.flags.prompt == null);
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
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"-p"}));
}

test "unknown subcommand captures args" {
    const p = try parse(&.{ "frobnicate", "a", "b" });
    try std.testing.expectEqual(Subcommand.unknown, p.subcommand);
    try std.testing.expectEqual(@as(usize, 2), p.args.len);
}

test "ask subcommand takes a positional prompt" {
    const p = try parse(&.{ "ask", "summarise this" });
    try std.testing.expectEqual(Subcommand.ask, p.subcommand);
    const a = try parseAsk(p.args);
    try std.testing.expectEqualStrings("summarise this", a.prompt.?);
    try std.testing.expect(!a.json and !a.yes and !a.deny_all);
    try std.testing.expect(a.policy == null);
}

test "-p is accepted before and after the subcommand" {
    const before = try parse(&.{ "-p", "hi" });
    try std.testing.expectEqual(Subcommand.none, before.subcommand);
    try std.testing.expectEqualStrings("hi", before.flags.prompt.?);

    const after = try parse(&.{ "ask", "-p", "hi" });
    try std.testing.expectEqual(Subcommand.ask, after.subcommand);
    try std.testing.expectEqualStrings("hi", (try parseAsk(after.args)).prompt.?);
}

test "ask --json after the subcommand" {
    const p = try parse(&.{ "ask", "--json", "hi" });
    const a = try parseAsk(p.args);
    try std.testing.expect(a.json);
    try std.testing.expectEqualStrings("hi", a.prompt.?);

    // The global flag still works in either position.
    try std.testing.expect((try parse(&.{ "--json", "ask", "hi" })).flags.json);
    try std.testing.expect((try parseAsk(&.{"--json"})).json);
}

test "each ask flag parses" {
    try std.testing.expect((try parseAsk(&.{"--yes"})).yes);
    try std.testing.expect((try parseAsk(&.{"--deny-all"})).deny_all);
    try std.testing.expectEqual(ApprovalPolicy.ask, (try parseAsk(&.{ "--policy", "ask" })).policy.?);
    try std.testing.expectEqual(ApprovalPolicy.allow, (try parseAsk(&.{ "--policy", "allow" })).policy.?);
    try std.testing.expectEqual(ApprovalPolicy.deny, (try parseAsk(&.{ "--policy", "deny" })).policy.?);
}

test "ask flag errors" {
    try std.testing.expectError(error.MissingFlagValue, parseAsk(&.{"--policy"}));
    try std.testing.expectError(error.InvalidFlagValue, parseAsk(&.{ "--policy", "maybe" }));
    try std.testing.expectError(error.ConflictingFlags, parseAsk(&.{ "--yes", "--deny-all" }));
    try std.testing.expectError(error.ConflictingFlags, parseAsk(&.{ "--yes", "--policy", "ask" }));
    try std.testing.expectError(error.ConflictingFlags, parseAsk(&.{ "--deny-all", "--policy", "deny" }));
    try std.testing.expectError(error.UnknownFlag, parseAsk(&.{"--bogus"}));
    try std.testing.expectError(error.MissingFlagValue, parseAsk(&.{"-p"}));
    try std.testing.expectError(error.TooManyArguments, parseAsk(&.{ "one", "two" }));
    try std.testing.expectError(error.TooManyArguments, parseAsk(&.{ "-p", "one", "two" }));
}

test "no prompt and '-' both mean stdin" {
    try std.testing.expect((try parseAsk(&.{})).prompt == null);
    try std.testing.expect((try parseAsk(&.{"-"})).prompt == null);
    try std.testing.expect((try parseAsk(&.{ "-p", "-" })).prompt == null);
    try std.testing.expect((try parseAsk(&.{"-"})).stdin);
    try std.testing.expect((try parseAsk(&.{ "-p", "-" })).stdin);
}

test "global -p applies unless ask names stdin" {
    try std.testing.expectEqualStrings("hi", resolveAskPrompt("hi", try parseAsk(&.{"--json"})).?);
    try std.testing.expect(resolveAskPrompt("hi", try parseAsk(&.{"-"})) == null);
    try std.testing.expect(resolveAskPrompt("hi", try parseAsk(&.{ "-p", "-" })) == null);
    try std.testing.expect(resolveAskPrompt("-", try parseAsk(&.{})) == null);
}
