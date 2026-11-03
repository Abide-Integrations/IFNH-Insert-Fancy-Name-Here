//! CLI argument parsing (pure, table-driven, fully testable — no I/O).
//!
//! Grammar: `ifnh [global-flags] <subcommand> [subcommand-args...]`
//! Flags are kebab-case (fx convention). Unknown flags are errors, not
//! silently ignored values.

const std = @import("std");
const config_mod = @import("../core/config/config.zig");

pub const LogLevel = enum { err, info, debug, trace };

/// Per-key config flags. `cli` may import `core`; the value kind decides
/// whether the text is JSON, a string, or a fixed `false`.
pub const Override = config_mod.CliOverride;
pub const max_overrides = 8;

pub const GlobalFlags = struct {
    json: bool = false,
    no_color: bool = false,
    log_level: LogLevel = .info,
    help: bool = false,
    version: bool = false,
    /// `-p "<prompt>"` before the subcommand: headless one-shot prompt,
    /// the same thing as `ifnh ask -p "<prompt>"` (C-02).
    prompt: ?[]const u8 = null,
    /// `--profile <name>`: merge `profiles.<name>` over the loaded config
    /// and append its `prompt` fragment (D-03).
    profile: ?[]const u8 = null,
    /// `--trace <path>`: NDJSON wire log of provider requests/responses (D-09).
    trace: ?[]const u8 = null,
    /// Per-key config flags (`--model`, `--temperature`, ...), applied after
    /// `--profile` as the `.cli` layer (D-06).
    overrides: [max_overrides]Override = undefined,
    override_count: usize = 0,

    pub fn overrideList(self: *const GlobalFlags) []const Override {
        return self.overrides[0..self.override_count];
    }

    fn addOverride(self: *GlobalFlags, o: Override) ParseError!void {
        if (self.override_count >= max_overrides) return error.TooManyArguments;
        self.overrides[self.override_count] = o;
        self.override_count += 1;
    }
};

/// Table of per-key config flags: flag name, dotted config key, value kind.
/// Adding a flag is a one-line change here (D-06).
const key_flag_table = [_]struct { name: []const u8, path: []const u8, kind: config_mod.CliValueKind }{
    .{ .name = "--model", .path = "model.model", .kind = .string },
    .{ .name = "--provider", .path = "model.provider", .kind = .string },
    .{ .name = "--base-url", .path = "model.base_url", .kind = .string },
    .{ .name = "--temperature", .path = "model.temperature", .kind = .raw_json },
    .{ .name = "--max-output-tokens", .path = "model.max_output_tokens", .kind = .raw_json },
    .{ .name = "--context-tokens", .path = "context.max_context_tokens", .kind = .raw_json },
    .{ .name = "--permission-mode", .path = "permissions.default_mode", .kind = .string },
    .{ .name = "--no-footer", .path = "ui.footer", .kind = .boolean_false },
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
    /// `ifnh debug-bundle [--out <path>]` (D-09).
    @"debug-bundle",
    /// `ifnh session export <id>` (D-09).
    session,
    /// `ifnh replay <file>` (D-09).
    replay,
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
    /// `--image <path>` (repeatable, up to `max_images`), in command-line order.
    image_paths: [max_images][]const u8 = undefined,
    image_count: usize = 0,

    pub fn images(self: *const AskArgs) []const []const u8 {
        return self.image_paths[0..self.image_count];
    }
};

/// Most images one `ask` may attach.
pub const max_images: usize = 8;

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
    } else if (std.mem.eql(u8, arg, "--profile")) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        result.flags.profile = argv[i.*];
    } else if (std.mem.eql(u8, arg, "--trace")) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        result.flags.trace = argv[i.*];
    } else if (std.mem.eql(u8, arg, "-p")) {
        i.* += 1;
        if (i.* >= argv.len) return error.MissingFlagValue;
        result.flags.prompt = argv[i.*];
    } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        result.flags.help = true;
    } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
        result.flags.version = true;
    } else {
        for (key_flag_table) |entry| {
            if (!std.mem.eql(u8, entry.name, arg)) continue;
            if (entry.kind == .boolean_false) {
                try result.flags.addOverride(.{ .path = entry.path, .kind = .boolean_false, .origin = entry.name });
                return;
            }
            i.* += 1;
            if (i.* >= argv.len) return error.MissingFlagValue;
            const value = argv[i.*];
            if (entry.kind == .raw_json) {
                // `--temperature warm` is a usage error, not a config error.
                _ = std.fmt.parseFloat(f64, value) catch return error.InvalidFlagValue;
            }
            try result.flags.addOverride(.{ .path = entry.path, .value = value, .kind = entry.kind, .origin = entry.name });
            return;
        }
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
    else if (std.mem.eql(u8, cmd_name, "debug-bundle"))
        .@"debug-bundle"
    else if (std.mem.eql(u8, cmd_name, "session"))
        .session
    else if (std.mem.eql(u8, cmd_name, "replay"))
        .replay
    else if (std.mem.eql(u8, cmd_name, "ask"))
        .ask
    else
        .unknown;

    result.args = argv[i..];
    return result;
}

const AskFlag = enum { json, yes, deny_all, policy, prompt, image };

const ask_flag_table = [_]struct { name: []const u8, flag: AskFlag }{
    .{ .name = "--json", .flag = .json },
    .{ .name = "--yes", .flag = .yes },
    .{ .name = "--deny-all", .flag = .deny_all },
    .{ .name = "--policy", .flag = .policy },
    .{ .name = "-p", .flag = .prompt },
    .{ .name = "--image", .flag = .image },
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
                .image => {
                    i += 1;
                    if (i >= args.len) return error.MissingFlagValue;
                    if (out.image_count >= max_images) return error.TooManyArguments;
                    out.image_paths[out.image_count] = args[i];
                    out.image_count += 1;
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

test "parse --profile before the subcommand" {
    const p = try parse(&.{ "--profile", "fast", "-p", "hi" });
    try std.testing.expectEqualStrings("fast", p.flags.profile.?);
    try std.testing.expectEqualStrings("hi", p.flags.prompt.?);
    try std.testing.expectEqual(Subcommand.none, p.subcommand);

    const ask = try parse(&.{ "--profile", "fast", "ask", "-p", "hi" });
    try std.testing.expectEqualStrings("fast", ask.flags.profile.?);
    try std.testing.expectEqual(Subcommand.ask, ask.subcommand);
    try std.testing.expect((try parse(&.{})).flags.profile == null);
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--profile"}));
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

test "ask --image parses, repeats in order and is capped" {
    const a = try parseAsk(&.{ "--image", "a.png", "describe", "--image", "b.jpg" });
    try std.testing.expectEqual(@as(usize, 2), a.images().len);
    try std.testing.expectEqualStrings("a.png", a.images()[0]);
    try std.testing.expectEqualStrings("b.jpg", a.images()[1]);
    try std.testing.expectEqualStrings("describe", a.prompt.?);
    try std.testing.expectEqual(@as(usize, 0), (try parseAsk(&.{"hi"})).images().len);
    try std.testing.expectError(error.MissingFlagValue, parseAsk(&.{"--image"}));

    const nine = [_][]const u8{ "--image", "1.png", "--image", "2.png", "--image", "3.png", "--image", "4.png", "--image", "5.png", "--image", "6.png", "--image", "7.png", "--image", "8.png" };
    try std.testing.expectEqual(@as(usize, 8), (try parseAsk(&nine)).images().len);
    try std.testing.expectError(error.TooManyArguments, parseAsk(&(nine ++ [_][]const u8{ "--image", "9.png" })));
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

test "cli per-key flags populate typed overrides in order" {
    const p = try parse(&.{
        "--model",             "gpt-5",
        "--provider",          "anthropic",
        "--base-url",          "http://localhost:8080/v1",
        "--temperature",       "0.3",
        "--max-output-tokens", "2048",
        "--context-tokens",    "200000",
        "--permission-mode",   "auto",
        "--no-footer",
    });
    try std.testing.expectEqual(@as(usize, 0), p.args.len);
    const list = p.flags.overrideList();
    try std.testing.expectEqual(@as(usize, 8), list.len);
    try std.testing.expectEqualStrings("model.model", list[0].path);
    try std.testing.expectEqualStrings("gpt-5", list[0].value);
    try std.testing.expectEqual(config_mod.CliValueKind.string, list[0].kind);
    try std.testing.expectEqualStrings("--model", list[0].origin);
    try std.testing.expectEqualStrings("model.temperature", list[3].path);
    try std.testing.expectEqual(config_mod.CliValueKind.raw_json, list[3].kind);
    try std.testing.expectEqualStrings("0.3", list[3].value);
    try std.testing.expectEqualStrings("permissions.default_mode", list[6].path);
    try std.testing.expectEqual(config_mod.CliValueKind.boolean_false, list[7].kind);
    try std.testing.expectEqualStrings("ui.footer", list[7].path);
}

test "cli per-key flags reject bad numbers and missing values" {
    try std.testing.expectError(error.InvalidFlagValue, parse(&.{ "--temperature", "warm" }));
    try std.testing.expectError(error.InvalidFlagValue, parse(&.{ "--max-output-tokens", "many" }));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--model"}));
    // `--no-footer` takes no value, so it is never a missing-value error.
    try std.testing.expect((try parse(&.{"--no-footer"})).flags.override_count == 1);
}

test "cli per-key flags stop at the subcommand and apply as the cli layer" {
    const p = try parse(&.{ "--model", "m", "ask", "--json", "hi" });
    try std.testing.expectEqual(config_mod.CliValueKind.string, p.flags.overrideList()[0].kind);
    try std.testing.expectEqual(@as(usize, 1), p.flags.override_count);
    try std.testing.expectEqual(Subcommand.ask, p.subcommand);
    // An apply-only helper: the flags become the cli layer, nothing else moves.
    var store = try config_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyCliOverrides(p.flags.overrideList());
    try std.testing.expectEqualStrings("m", store.getString("model.model", ""));
    try std.testing.expectEqual(config_mod.Layer.cli, store.getSource("model.model").?.layer);
}

test "cli trace flag takes a path before the subcommand" {
    const p = try parse(&.{ "--trace", "/tmp/w.ndjson", "ask", "hi" });
    try std.testing.expectEqualStrings("/tmp/w.ndjson", p.flags.trace.?);
    try std.testing.expectEqual(Subcommand.ask, p.subcommand);
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--trace"}));
    try std.testing.expectEqual(Subcommand.replay, (try parse(&.{ "replay", "f" })).subcommand);
    try std.testing.expectEqual(Subcommand.@"debug-bundle", (try parse(&.{"debug-bundle"})).subcommand);
}
