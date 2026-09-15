//! Shell command classification (DECISIONS H103-H105, I120-I121).
//!
//! Pure and conservative: anything not confidently read-only is treated as
//! write-ish; anything in the destructive lexicon is destructive; compound
//! commands (pipes, redirects, lists, subshells) are classified as the
//! WORST effect among their components. Unknown programs are `unknown`,
//! which the permission engine maps to `ask`.

const std = @import("std");

pub const Effect = enum {
    read_only,
    write,
    destructive,
    unknown,

    pub fn worst(a: Effect, b: Effect) Effect {
        const rank = struct {
            fn r(e: Effect) u8 {
                return switch (e) {
                    .read_only => 0,
                    .unknown => 1,
                    .write => 2,
                    .destructive => 3,
                };
            }
        }.r;
        return if (rank(a) >= rank(b)) a else b;
    }
};

/// Programs confidently considered read-only (their non-flag args are read
/// targets). Git read subcommands are added separately.
const read_only_programs = [_][]const u8{
    "ls",   "cat", "head", "tail", "grep",  "rg",     "find", "stat",  "wc",
    "diff", "env", "pwd",  "echo", "which", "whoami", "date", "uname",
    "zig", // zig build test/version etc; subcommand checked below
    "true", "false", "test", "sleep", "printf", "sed", // sed writes only with -i; checked below
};

const destructive_patterns = [_][]const u8{
    "rm ",    "rmdir ",   "shred ", "mkfs",     "dd ",      "shred",
    "chmod ", "chown ",   "chgrp ", "kill ",    "killall ", "pkill ",
    "reboot", "shutdown", "halt",   "poweroff",
    "curl ",       "wget ", // network fetch is gated separately
    "sudo ",       "su ",
    "doas ",       "eval ",
    "exec ",       "source ",
    ". ",          "npm publish",
    "pip install", "curl|sh",
};

const git_write_subcommands = [_][]const u8{
    "add",    "commit", "checkout", "switch",    "restore", "rebase", "merge",
    "revert", "reset",  "stash",    "clean",     "apply",   "am",     "cherry-pick",
    "mv",     "rm",     "tag",      "branch -D",
};

const git_destructive_subcommands = [_][]const u8{
    "push --force", "push -f", "reset --hard", "clean -fd", "filter-branch",
};

/// Classify a full command line (as typed by the model).
pub fn classify(command: []const u8) Effect {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");
    if (trimmed.len == 0) return .read_only;

    // Compound detection: pipelines, lists, redirects, subshells, substitutions.
    if (containsAny(trimmed, &.{
        "|",
        "&&",
        "||",
        ";",
        ">",
        "<",
        "`",
        "$(",
    })) {
        // Compound commands: classify conservatively as unknown unless every
        // segment is read-only. M0 simplification: unknown → ask.
        var worst: Effect = .read_only;
        var it = std.mem.splitAny(u8, trimmed, "|;&");
        while (it.next()) |seg_raw| {
            const seg = std.mem.trim(u8, seg_raw, " \t\r\n()$`<>");
            if (seg.len == 0) continue;
            worst = Effect.worst(worst, classifySimple(seg));
        }
        if (containsAny(trimmed, &.{ ">", "<", "`", "$(" })) {
            worst = Effect.worst(worst, .write);
        }
        return worst;
    }
    return classifySimple(trimmed);
}

fn classifySimple(cmd: []const u8) Effect {
    // Destructive lexicon first (substring match on the head).
    for (destructive_patterns) |pat| {
        if (startsWithPat(cmd, pat)) return .destructive;
    }
    if (std.mem.indexOf(u8, cmd, "rm -") != null or std.mem.indexOf(u8, cmd, "rm ") != null) return .destructive;

    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const prog = it.next() orelse return .read_only;
    const base = std.fs.path.basename(prog);

    if (std.mem.eql(u8, base, "git")) {
        return classifyGit(cmd);
    }
    if (std.mem.eql(u8, base, "sed")) {
        if (containsFlag(cmd, "-i") or containsFlag(cmd, "--in-place")) return .write;
        return .read_only;
    }
    if (std.mem.eql(u8, base, "zig")) {
        // zig build/test/version/fmt --check are safe-ish; zig build writes to zig-cache.
        if (subcommandIs(cmd, "version") or subcommandIs(cmd, "env") or subcommandIs(cmd, "help")) return .read_only;
        if (subcommandIs(cmd, "fmt")) {
            if (containsFlag(cmd, "--check")) return .read_only;
            return .write;
        }
        if (subcommandIs(cmd, "build") or subcommandIs(cmd, "test")) return .write;
        return .unknown;
    }
    for (read_only_programs) |ro| {
        if (std.mem.eql(u8, base, ro)) return .read_only;
    }
    // touch/mkdir/cp/write-ish well-known
    if (std.mem.eql(u8, base, "mkdir") or std.mem.eql(u8, base, "touch") or
        std.mem.eql(u8, base, "cp") or std.mem.eql(u8, base, "mv") or
        std.mem.eql(u8, base, "tee") or std.mem.eql(u8, base, "ln"))
    {
        return .write;
    }
    return .unknown;
}

fn classifyGit(cmd: []const u8) Effect {
    for (git_destructive_subcommands) |d| {
        if (std.mem.indexOf(u8, cmd, d) != null) return .destructive;
    }
    for (git_write_subcommands) |w| {
        if (subcommandIs(cmd, w)) return .write;
    }
    // Read-only git subcommands.
    const ro = [_][]const u8{ "status", "diff", "log", "show", "branch", "worktree", "remote", "rev-parse", "ls-files", "cat-file", "config --get" };
    for (ro) |r| {
        if (subcommandIs(cmd, r)) return .read_only;
    }
    if (std.mem.indexOf(u8, cmd, "push") != null) return .write;
    return .unknown;
}

fn subcommandIs(cmd: []const u8, sub: []const u8) bool {
    // Find the subcommand token after the program name.
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    _ = it.next(); // program
    const first = it.next() orelse return false;
    if (std.mem.eql(u8, first, sub)) return true;
    // Multi-word subcommands ("branch -D", "config --get").
    if (std.mem.indexOfScalar(u8, sub, ' ') != null) {
        const rest_start = (it.index);
        _ = rest_start;
        return std.mem.indexOf(u8, cmd, sub) != null;
    }
    return false;
}

fn startsWithPat(cmd: []const u8, pat: []const u8) bool {
    // Destructive patterns include a trailing space where relevant; match
    // against the trimmed command with word boundaries.
    const pat_trim = std.mem.trimEnd(u8, pat, " ");
    if (!std.mem.startsWith(u8, cmd, pat_trim)) return false;
    if (pat.len > pat_trim.len) {
        // Trailing space in pattern requires a word boundary (or exact).
        if (cmd.len == pat_trim.len) return true;
        return cmd[pat_trim.len] == ' ' or cmd[pat_trim.len] == '\t';
    }
    return true;
}

fn containsFlag(cmd: []const u8, flag: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, flag)) return true;
        // Handle attached forms like -ri or -in for sed -i.
        if (flag.len == 2 and flag[0] == '-' and tok.len > 2 and tok[0] == '-' and tok[1] != '-') {
            if (std.mem.indexOfScalar(u8, tok[1..], flag[1]) != null) return true;
        }
    }
    return false;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

test "classify read-only programs" {
    try std.testing.expectEqual(Effect.read_only, classify("ls -la"));
    try std.testing.expectEqual(Effect.read_only, classify("cat foo.txt"));
    try std.testing.expectEqual(Effect.read_only, classify("grep -r pattern src/"));
    try std.testing.expectEqual(Effect.read_only, classify("git status --porcelain"));
    try std.testing.expectEqual(Effect.read_only, classify("git diff HEAD~1"));
    try std.testing.expectEqual(Effect.read_only, classify("sed 's/a/b/' in.txt"));
    try std.testing.expectEqual(Effect.read_only, classify(""));
}

test "classify write programs" {
    try std.testing.expectEqual(Effect.write, classify("mkdir -p build"));
    try std.testing.expectEqual(Effect.write, classify("cp a b"));
    try std.testing.expectEqual(Effect.write, classify("sed -i 's/a/b/' file.txt"));
    try std.testing.expectEqual(Effect.write, classify("git add ."));
    try std.testing.expectEqual(Effect.write, classify("git commit -m 'msg'"));
    try std.testing.expectEqual(Effect.write, classify("git push origin main"));
    try std.testing.expectEqual(Effect.write, classify("zig build"));
}

test "classify destructive" {
    try std.testing.expectEqual(Effect.destructive, classify("rm -rf /"));
    try std.testing.expectEqual(Effect.destructive, classify("git push --force origin main"));
    try std.testing.expectEqual(Effect.destructive, classify("git reset --hard HEAD~3"));
    try std.testing.expectEqual(Effect.destructive, classify("dd if=/dev/zero of=x"));
    try std.testing.expectEqual(Effect.destructive, classify("sudo apt install x"));
}

test "classify compound commands conservatively" {
    try std.testing.expectEqual(Effect.read_only, classify("cat a.txt | grep x"));
    try std.testing.expectEqual(Effect.write, classify("cat a.txt > b.txt"));
    try std.testing.expectEqual(Effect.destructive, classify("ls && rm -rf build"));
    try std.testing.expectEqual(Effect.unknown, classify("python3 script.py"));
    try std.testing.expectEqual(Effect.unknown, classify("cargo test"));
}
