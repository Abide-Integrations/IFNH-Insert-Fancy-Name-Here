//! Interactive streaming REPL (DESIGN §6, DECISIONS section R).
//!
//! Line-oriented inline streaming UI: works on a TTY, over SSH, and with
//! piped stdin/stdout. Slash commands are built-in; disk-backed commands
//! load from `.ifnh/commands/*.md`. Approvals are interactive prompts that
//! can grant session-scoped permission patterns.

const std = @import("std");
const fsutil = @import("../core/fsutil.zig");
const config_mod = @import("../core/config/config.zig");
const keys_mod = @import("../core/config/keys.zig");
const session_mod = @import("../core/session/store.zig");
const engine_mod = @import("../core/permissions/engine.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const subagent_mod = @import("../core/agent/subagent.zig");
const session_runtime = @import("../core/agent/session_runtime.zig");
const git_mod = @import("../core/git.zig");
const compaction_mod = @import("../core/compaction.zig");
const lifecycle_mod = @import("../core/lifecycle.zig");
const style_mod = @import("../ui/style.zig");
const secret_mod = @import("../ui/secret.zig");
const models_mod = @import("../providers/models.zig");
const tool_mod = @import("../tools/tool.zig");
const openai = @import("../providers/openai.zig");
const anthropic = @import("../providers/anthropic.zig");
const trace_mod = @import("../core/trace.zig");
const turn_cache_mod = @import("../core/turn_cache.zig");
const budget_mod = @import("../core/budget.zig");
const footer_mod = @import("../ui/footer.zig");
const line_editor = @import("../ui/line_editor.zig");
const interrupt_mod = @import("../core/interrupt.zig");
const pricing = @import("../providers/pricing.zig");
const local_grants_mod = @import("../core/permissions/local_grants.zig");

const max_output_bytes: usize = 256 * 1024;

pub const Options = struct {
    resume_id: ?[]const u8 = null,
    json: bool = false,
    no_color: bool = false,
    /// Startup trace owned by main, measured from process start (B-01).
    trace: ?*trace_mod.Trace = null,
};

/// Terminal-facing state for the REPL: the palette, the streams and the
/// event sink the session runtime reports through. Owned by `run`; nothing
/// here is file-scope state.
const Ui = struct {
    io: std.Io,
    palette: style_mod.Palette,
    /// Status line on stderr (C-04); every writer below clears it first.
    footer: footer_mod.Footer,
    /// Prompt + output tokens of the last request, for the footer's ctx %.
    ctx_used: u64 = 0,

    fn footerStats(self: *const Ui, rt: *const session_runtime.SessionRuntime, cfg: *const config_mod.Store) footer_mod.Stats {
        const model = cfg.getString("model.model", "");
        return .{
            .model = model,
            .tokens_in = rt.usage_total.input_tokens,
            .tokens_out = rt.usage_total.output_tokens,
            .cache_read = rt.usage_total.cache_read_tokens,
            .cache_write = rt.usage_total.cache_write_tokens,
            .ctx_used = self.ctx_used,
            .window = if (cfg.getOptionalU32("context.max_context_tokens")) |w| w else null,
            .cost_usd = rt.spent_usd,
            .priced = pricing.lookup(model) != null,
            .turn_index = rt.turns_run + 1,
        };
    }

    fn beginTurn(self: *Ui, rt: *const session_runtime.SessionRuntime, cfg: *const config_mod.Store) void {
        self.footer.beginTurn(self.footerStats(rt, cfg));
    }

    fn endTurn(self: *Ui, rt: *const session_runtime.SessionRuntime, cfg: *const config_mod.Store, res: session_runtime.TurnOutcome) void {
        if (!res.ran) return self.footer.abandon();
        const anthropic_wire = std.mem.eql(u8, cfg.getString("model.provider", "openai"), "anthropic");
        self.ctx_used = footer_mod.contextTokens(res.last_round, anthropic_wire);
        self.footer.finish(self.footerStats(rt, cfg));
    }

    fn events(self: *Ui) session_runtime.Events {
        return .{
            .ctx = @ptrCast(self),
            .on_text = onText,
            .on_status = onStatus,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
            .on_assistant_message = onAssistantMessage,
            .on_approval = promptApproval,
        };
    }

    /// Assistant text deltas go straight to stdout, byte for byte.
    fn onText(ctx: *anyopaque, text: []const u8) void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        std.Io.File.stdout().writeStreamingAll(self.io, text) catch {};
    }

    fn onStatus(ctx: *anyopaque, level: session_runtime.Level, text: []const u8) void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        switch (level) {
            .plain => out(self.io, "{s}", .{text}) catch {},
            .warn => out(self.io, "{s}", .{self.palette.warn(text, std.heap.page_allocator)}) catch {},
            .err => out(self.io, "{s}", .{self.palette.err(text, std.heap.page_allocator)}) catch {},
        }
    }

    fn onToolStart(ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void {
        _ = call_id;
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        out(self.io, "\n[tool] {s} {s}\n", .{ name, arguments_json }) catch {};
    }

    fn onToolResult(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        _ = call_id;
        _ = name;
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        const max_show: usize = 400;
        const shown = if (output.len > max_show) output[0..max_show] else output;
        var scratch: [64]u8 = undefined;
        const tag = std.fmt.bufPrint(&scratch, "[{s}]", .{@tagName(status)}) catch "[?]";
        const pa: style_mod.Palette = self.palette;
        const colored = switch (status) {
            .ok => pa.green(tag, std.heap.page_allocator),
            .denied => pa.yellow(tag, std.heap.page_allocator),
            else => pa.red(tag, std.heap.page_allocator),
        };
        out(self.io, "{s} {s}{s}\n", .{ colored, shown, if (output.len > max_show) "..." else "" }) catch {};
        self.footer.tick();
    }

    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        out(self.io, "! {s}\n", .{text}) catch {};
    }

    /// Persistence happens in the runtime; the REPL has nothing to add.
    fn onAssistantMessage(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
        _ = ctx;
        _ = content;
        _ = tool_calls_json;
    }

    /// Interactive approval prompt. Session and project grants are applied
    /// by the runtime. `p` (always for this project) is offered for file
    /// writes only; typing it for anything else denies.
    fn promptApproval(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Ui = @ptrCast(@alignCast(ctx));
        self.footer.clear();
        const offer_project = req.grant == .path_write;
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("\n{s}approval needed:{s} {s}\n  {s}\n", .{ self.palette.warn("", std.heap.page_allocator), "\x1b[0m", req.title, req.detail }) catch return .denied;
        writePreview(w, self.palette, req.preview) catch return .denied;
        if (offer_project) {
            w.print("  (p saves this grant to {s})\n[y] once  [s] session  [p] always for this project  [n] no: ", .{local_grants_mod.path}) catch return .denied;
        } else {
            w.writeAll("[y] once  [s] session  [n] no: ") catch return .denied;
        }
        std.Io.File.stdout().writeStreamingAll(self.io, aw.written()) catch return .denied;
        var buf: [64]u8 = undefined;
        var stdin_r = std.Io.File.stdin().reader(self.io, &buf);
        const line = stdin_r.interface.takeDelimiterInclusive('\n') catch return .denied;
        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(answer, "y")) {
            return .approved_once;
        } else if (std.ascii.eqlIgnoreCase(answer, "s")) {
            return .approved_session;
        } else if (offer_project and std.ascii.eqlIgnoreCase(answer, "p")) {
            return .approved_project;
        }
        return .denied;
    }
};

/// Print a unified diff indented and dimmed. File content is untrusted, so
/// control bytes (escape sequences, a bare CR) are shown as visible marks.
fn writePreview(w: *std.Io.Writer, palette: style_mod.Palette, preview: []const u8) !void {
    if (preview.len == 0) return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, preview, "\n"), '\n');
    while (lines.next()) |line| {
        try w.writeAll(if (palette.enabled) "    \x1b[2m" else "    ");
        for (line) |c| {
            switch (c) {
                '\r' => try w.writeAll("\u{240D}"),
                '\t' => try w.writeByte(c),
                0...8, 10...12, 14...31, 127 => try w.writeByte('?'),
                else => try w.writeByte(c),
            }
        }
        try w.writeAll(if (palette.enabled) "\x1b[0m\n" else "\n");
    }
}

/// The footer draws escape codes on stderr: only for a real, non-dumb terminal.
fn footerEnabled(io: std.Io, environ: *const std.process.Environ.Map, cfg: *const config_mod.Store) bool {
    if (!cfg.getBool("ui.footer", true)) return false;
    const term = environ.get("TERM") orelse return false;
    if (term.len == 0 or std.mem.eql(u8, term, "dumb")) return false;
    return std.Io.File.stderr().isTty(io) catch false;
}

/// Palette detection needs the merged environment (the user env file may set
/// NO_COLOR), so the lookup is inlined rather than kept in file-scope state.
fn detectPalette(io: std.Io, environ: *const std.process.Environ.Map, config_colors: bool, cli_no_color: bool) style_mod.Palette {
    if (cli_no_color) return .{ .enabled = false };
    if (environ.get("NO_COLOR") != null) return .{ .enabled = false };
    if (!config_colors) return .{ .enabled = false };
    const is_tty = std.Io.File.stdout().isTty(io) catch false;
    return .{ .enabled = is_tty };
}

pub fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    opts: Options,
) !void {
    const cwd = std.Io.Dir.cwd();

    // ---- configuration ----
    var config_span = trace_mod.Span.begin(opts.trace, "startup.config");
    var cfg = config_mod.load(arena, io, environ, cwd) catch |err| {
        config_span.end("error");
        return err;
    };
    config_span.end("");
    defer cfg.deinit();
    for (cfg.errors.items) |err| {
        try out(io, "config error [{s}]: {s}\n", .{ err.path, err.message });
    }
    if (cfg.errors.items.len > 0) return error.InvalidConfig;
    for (cfg.warnings.items) |w| try out(io, "config warning: {s}\n", .{w});

    // ---- session state (zero-config: lazily create .ifnh) ----
    ensureIfnh(io, cwd) catch {};
    const sessions_dir_name = sessionsDir(arena, &cfg);

    var rt = try session_runtime.SessionRuntime.init(io, arena, environ, &cfg, cwd, .{
        .sessions_dir = sessions_dir_name,
        .resume_id = opts.resume_id,
        .cwd_label = if (environ.get("PWD")) |pwd| pwd else ".",
        .trace = opts.trace,
    });
    defer rt.deinit();
    if (rt.local_grants_warning) |warning| try out(io, "{s}", .{warning});

    // The palette needs the merged environment (the user env file may set
    // NO_COLOR), so it is detected after the runtime exists.
    const palette0 = detectPalette(io, rt.environ, cfg.getBool("ui.colors", true), opts.no_color);
    var ui = Ui{
        .io = io,
        .palette = palette0,
        .footer = footer_mod.Footer.init(io, footerEnabled(io, rt.environ, &cfg), palette0),
    };
    const events = ui.events();
    const palette = ui.palette;

    // ---- first-run setup (interactive TTY only; skipped when piped) ----
    if (cfg.getString("model.model", "").len == 0 and
        (std.Io.File.stdin().isTty(io) catch false))
    {
        runFirstRunSetup(io, arena, &rt, &ui, &cfg) catch {};
    }

    if (opts.resume_id != null) try rt.rebuildHistory(arena, &events);

    // ---- provider ----
    const pcfg = rt.providerConfig(&cfg);
    const provider_name = cfg.getString("model.provider", "openai");

    // ---- instructions ----
    const builtin_prompt = system_prompt.system_prompt;
    var instructions_span = trace_mod.Span.begin(opts.trace, "startup.instructions");
    const instr = try instructions_mod.assemble(cwd, io, arena, builtin_prompt, &.{});
    instructions_span.end("");

    // ---- welcome ----
    {
        const provider_display = cfg.getOptionalString("model.provider_label") orelse provider_name;
        const key_note = if (pcfg.api_key.len == 0) blk: {
            const key_env = cfg.getOptionalString("model.api_key_env") orelse
                (if (std.mem.eql(u8, provider_name, "anthropic")) "ANTHROPIC_API_KEY" else "OPENAI_API_KEY");
            break :blk std.fmt.allocPrint(arena, " — {s}run /provider key {s} <value>{s}", .{ palette.warn("", arena), key_env, "\x1b[0m" }) catch ", no api key";
        } else "";
        try out(io, "{s}ifnh session{s} {s} ({s}{s} · {s}{s}){s}\n", .{
            palette.accent("", arena),
            "\x1b[0m",
            rt.store.manifest.id,
            palette.dim("", arena),
            provider_display,
            pcfg.model,
            "\x1b[0m",
            key_note,
        });
        try out(io, "{s}type a message, or /help for commands{s}\n", .{ palette.dim("", arena), "\x1b[0m" });
    }

    // First paint is measured from process start, not from REPL setup.
    if (opts.trace) |t| {
        const first_paint = trace_mod.Span{ .trace = t, .name = "startup.first_paint", .start = t.t0 };
        first_paint.end("");
    }

    // ---- input loop ----
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);

    // The line editor (C-03) only on a real terminal; piped input keeps the
    // plain line reader below, byte for byte.
    var editor: ?line_editor.Editor = null;
    if (line_editor.usable(io, rt.environ)) {
        const history_path = if (config_mod.userStateDir(arena, rt.process_environ)) |dir|
            std.fmt.allocPrint(arena, "{s}/history", .{dir}) catch null
        else
            null;
        editor = line_editor.Editor.init(io, arena, history_path, .{ .commands = &commands });
    }
    defer if (editor) |*ed| ed.deinit();

    while (true) {
        var line_raw: []const u8 = undefined;
        if (editor) |*ed| {
            line_raw = (ed.readLine("> ") catch break) orelse break;
        } else {
            try out(io, "> ", .{});
            line_raw = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    try out(io, "\n", .{});
                    break;
                },
                else => break,
            };
        }
        var line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        // `!cmd` runs locally and never reaches the model (editor only).
        if (editor != null) {
            if (line_editor.parseShellEscape(line)) |shell_cmd| {
                runShellEscape(io, arena, cwd, &rt, &cfg, shell_cmd);
                continue;
            }
        }

        if (line[0] == '/') {
            const cmd_end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const cmd = line[1..cmd_end];
            const rest = if (cmd_end < line.len) std.mem.trim(u8, line[cmd_end + 1 ..], " \t") else "";
            const action = handleCommand(io, arena, cwd, &rt, &ui, &events, &cfg, cmd, rest, instr);
            switch (action) {
                .quit => break,
                .submit => |prompt| {
                    ui.beginTurn(&rt, &cfg);
                    const res = try rt.submitTurn(arena, &cfg, rt.providerConfig(&cfg), instr.text, instr.stable_len, prompt, cwd, &events);
                    try renderTurn(io, arena, &ui, res);
                    ui.endTurn(&rt, &cfg, res);
                },
                .none => {},
            }
            continue;
        }

        // `@path` mentions become attached file blocks (editor only).
        if (editor != null) {
            const max_attach = cfg.getU32("context.max_file_read_bytes", 262144);
            switch (try line_editor.expandAtMentions(arena, io, cwd, line, max_attach)) {
                .ok => |expanded| line = expanded,
                .failed => |f| {
                    try out(io, "cannot attach {s}: {s}\n", .{ f.path, f.reason });
                    continue;
                },
            }
        }

        // ---- policy boundary (D029): re-read disk config only when its
        // files changed (B-04); instructions, the skills catalog and the git
        // state are memoised per source by the turn cache ----
        if (rt.turn_cache.configChanged(cwd, config_mod.userConfigPath(arena, environ))) {
            if (rt.reloadConfig(arena, cwd)) |fresh| {
                cfg.deinit();
                cfg = fresh;
            } else rt.turn_cache.configInvalidate(); // retry next turn
        }
        const focus = instructions_mod.focusDirsFromHistory(arena, rt.history.items, 8);
        var turn_instructions_span = trace_mod.Span.begin(rt.trace, "turn.instructions");
        const turn_instr_lookup = rt.turn_cache.instructions(cwd, system_prompt.system_prompt, focus) catch turn_cache_mod.Lookup(instructions_mod.Assembled){ .value = instr, .hit = false };
        turn_instructions_span.end(if (turn_instr_lookup.hit) "cached" else "");
        const turn_instr = turn_instr_lookup.value;
        // Skills catalog appendix (budgeted, K148). It goes after the stable
        // prefix, so a cacheable prefix stays valid across turns (B-03).
        const Prompt = struct { text: []const u8, stable_len: usize };
        const skill_prompt = blk: {
            if (rt.skills) |catalog| {
                var skills_catalog_span = trace_mod.Span.begin(rt.trace, "turn.skills_catalog");
                const rendered_lookup = rt.turn_cache.skillsText(cwd, config_mod.userSkillsDir(arena, environ), catalog) catch turn_cache_mod.Lookup([]const u8){ .value = "", .hit = false };
                skills_catalog_span.end(if (rendered_lookup.hit) "cached" else "");
                const rendered = rendered_lookup.value;
                if (rendered.len > 0) {
                    const text = std.fmt.allocPrint(arena, "{s}\n\nAvailable skills (load with the skill tool):\n{s}", .{ turn_instr.text, rendered }) catch turn_instr.text;
                    break :blk Prompt{ .text = text, .stable_len = turn_instr.stable_len };
                }
            }
            break :blk Prompt{ .text = turn_instr.text, .stable_len = turn_instr.stable_len };
        };

        ui.beginTurn(&rt, &cfg);
        const res = try rt.submitTurn(arena, &cfg, rt.providerConfig(&cfg), skill_prompt.text, skill_prompt.stable_len, line, cwd, &events);
        try renderTurn(io, arena, &ui, res);
        ui.endTurn(&rt, &cfg, res);
    }
}

/// `!cmd`: run a shell command for the human, in the workspace, under the
/// bash tool's timeout and Ctrl-C handling. No approval, no model, no session event.
fn runShellEscape(io: std.Io, arena: std.mem.Allocator, cwd: std.Io.Dir, rt: *session_runtime.SessionRuntime, cfg: *const config_mod.Store, command: []const u8) void {
    if (command.len == 0) {
        out(io, "usage: !<shell command>\n", .{}) catch {};
        return;
    }
    const Deny = struct {
        fn approve(_: *anyopaque, _: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
            return .denied;
        }
    };
    var cancel = std.atomic.Value(bool).init(false);
    interrupt_mod.install(&cancel);
    defer interrupt_mod.uninstall();
    var unused: u8 = 0;
    var ctx = tool_mod.ToolContext{
        .io = io,
        .arena = arena,
        .workspace = cwd,
        .engine = &rt.engine,
        .journal = null,
        .max_file_read_bytes = cfg.getU32("context.max_file_read_bytes", 262144),
        .approval_ctx = &unused,
        .approval_fn = Deny.approve,
        .cancel = &cancel,
        .timeout_s = cfg.getU32("agents.timeout_tool_s", 120),
    };
    const res = tool_mod.runShell(&ctx, command);
    var lines = std.mem.splitScalar(u8, res.output, '\n');
    while (lines.next()) |l| {
        // The capture wraps streams in tags for the model; a person does not need them.
        if (std.mem.eql(u8, l, "<stdout>") or std.mem.eql(u8, l, "</stdout>") or
            std.mem.eql(u8, l, "<stderr>") or std.mem.eql(u8, l, "</stderr>")) continue;
        if (l.len == 0 and (lines.peek() == null or std.mem.startsWith(u8, lines.peek().?, "</std"))) continue;
        out(io, "{s}\n", .{l}) catch {};
    }
    if (res.status == .ok) out(io, "[exit 0]\n", .{}) catch {} else out(io, "[{s}]\n", .{@tagName(res.status)}) catch {};
}

/// Render what the runtime reports after a turn. The runtime never touches
/// the terminal; everything user-visible is drawn here.
fn renderTurn(io: std.Io, arena: std.mem.Allocator, ui: *const Ui, res: session_runtime.TurnOutcome) !void {
    if (!res.ran) return;
    try out(io, "\n", .{});
    switch (res.status) {
        .completed => {},
        .failed => {
            const line = try std.fmt.allocPrint(arena, "provider error: {s}", .{res.error_message});
            try out(io, "{s}\n", .{ui.palette.err(line, arena)});
            if (@import("../providers/probe.zig").looksLikeToolRejection(res.error_message)) {
                try out(io, "{s}\n", .{ui.palette.warn("hint: this model may not support tool calling. Set it up as chat-only with /provider tools off", arena)});
            }
        },
        .cancelled => try out(io, "(interrupted)\n", .{}),
    }
    if (res.usage.input_tokens > 0 or res.usage.output_tokens > 0) {
        try out(io, "[tokens: {d} in / {d} out, {d} tool calls]\n", .{ res.usage.input_tokens, res.usage.output_tokens, res.tool_calls });
        // Prompt-cache counters, shown only when the provider reports them
        // (B-03).
        if (res.usage.cache_read_tokens > 0 or res.usage.cache_write_tokens > 0) {
            try out(io, "[cache: {d} read / {d} written]\n", .{ res.usage.cache_read_tokens, res.usage.cache_write_tokens });
        }
    }
}

/// Persist provider settings into .ifnh/config.json (developer action,
/// not an agent write): read -> set paths -> atomic write.
fn persistProjectConfig(
    io: std.Io,
    arena: std.mem.Allocator,
    cfg: *config_mod.Store,
    prov: []const u8,
    model_name: []const u8,
    base_url: ?[]const u8,
    key_env: ?[]const u8,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var root: std.json.Value = blk: {
        const text = fsutil.readSmallFile(cwd, io, arena, ".ifnh/config.json", config_mod.max_config_bytes) catch
            break :blk .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
    };
    var tmp_store = try config_mod.Store.init(arena);
    defer tmp_store.deinit();
    tmp_store.value = root;
    try tmp_store.setPath("model.provider", .{ .string = prov });
    try tmp_store.setPath("model.model", .{ .string = model_name });
    if (base_url) |b| try tmp_store.setPath("model.base_url", .{ .string = b });
    if (key_env) |k| try tmp_store.setPath("model.api_key_env", .{ .string = k });
    root = tmp_store.value;

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = aw.written() });

    // Live-apply to this session too.
    try cfg.applyOverride("model.provider", try std.fmt.allocPrint(arena, "\"{s}\"", .{prov}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    try cfg.applyOverride("model.model", try std.fmt.allocPrint(arena, "\"{s}\"", .{model_name}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    if (base_url) |b| {
        try cfg.applyOverride("model.base_url", try std.fmt.allocPrint(arena, "\"{s}\"", .{b}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    }
    if (key_env) |k| {
        try cfg.applyOverride("model.api_key_env", try std.fmt.allocPrint(arena, "\"{s}\"", .{k}), .{ .layer = .project, .origin = ".ifnh/config.json" });
    }
    return "saved .ifnh/config.json — applied to this session";
}

// -------------------------------------------------------------- first-run setup

pub const ProviderPreset = struct {
    /// Wire protocol: "openai" (any OpenAI-compatible endpoint) | "anthropic".
    id: []const u8,
    /// Human-readable provider name (display only).
    label: []const u8,
    base_url: []const u8,
    key_env: []const u8,
    default_model: []const u8,
    needs_key: bool,
    /// Ask for base_url + key env + model manually.
    custom: bool = false,
};

pub const presets = [_]ProviderPreset{
    .{ .id = "openai", .label = "OpenRouter", .base_url = "https://openrouter.ai/api/v1", .key_env = "OPENROUTER_API_KEY", .default_model = "openrouter/auto", .needs_key = true },
    .{ .id = "anthropic", .label = "Anthropic", .base_url = "https://api.anthropic.com", .key_env = "ANTHROPIC_API_KEY", .default_model = "claude-sonnet-4-6", .needs_key = true },
    .{ .id = "openai", .label = "OpenAI", .base_url = "https://api.openai.com/v1", .key_env = "OPENAI_API_KEY", .default_model = "gpt-5.1", .needs_key = true },
    .{ .id = "openai", .label = "xAI (Grok)", .base_url = "https://api.x.ai/v1", .key_env = "XAI_API_KEY", .default_model = "grok-4", .needs_key = true },
    .{ .id = "openai", .label = "Groq", .base_url = "https://api.groq.com/openai/v1", .key_env = "GROQ_API_KEY", .default_model = "llama-3.3-70b-versatile", .needs_key = true },
    .{ .id = "openai", .label = "DeepSeek", .base_url = "https://api.deepseek.com/v1", .key_env = "DEEPSEEK_API_KEY", .default_model = "deepseek-chat", .needs_key = true },
    .{ .id = "openai", .label = "Mistral", .base_url = "https://api.mistral.ai/v1", .key_env = "MISTRAL_API_KEY", .default_model = "mistral-large-latest", .needs_key = true },
    .{ .id = "openai", .label = "Z.AI (GLM)", .base_url = "https://api.z.ai/api/paas/v4", .key_env = "ZAI_API_KEY", .default_model = "glm-4.6", .needs_key = true },
    .{ .id = "openai", .label = "Together", .base_url = "https://api.together.xyz/v1", .key_env = "TOGETHER_API_KEY", .default_model = "moonshotai/Kimi-K2-Instruct", .needs_key = true },
    .{ .id = "openai", .label = "Fireworks", .base_url = "https://api.fireworks.ai/inference/v1", .key_env = "FIREWORKS_API_KEY", .default_model = "accounts/fireworks/models/kimi-k2-instruct", .needs_key = true },
    .{ .id = "openai", .label = "Ollama (local)", .base_url = "http://localhost:11434/v1", .key_env = "", .default_model = "qwen3-coder", .needs_key = false },
    .{ .id = "openai", .label = "LM Studio (local)", .base_url = "http://localhost:1234/v1", .key_env = "", .default_model = "", .needs_key = false },
    .{ .id = "openai", .label = "Custom OpenAI-compatible endpoint", .base_url = "", .key_env = "", .default_model = "", .needs_key = true, .custom = true },
};

/// A model id must not look like a credential: rejects API-key shapes
/// (the `sk-or-v1-... is not a valid model ID` bug class), overlong
/// strings, and multi-token values.
pub fn validModelId(s: []const u8) bool {
    if (s.len == 0 or s.len > 100) return false;
    if (std.mem.startsWith(u8, s, "sk-")) return false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '=' or c == '"') return false;
    }
    return true;
}

pub fn presetForChoice(choice: u8) ?ProviderPreset {
    if (choice == 0 or choice > presets.len) return null;
    return presets[choice - 1];
}

/// Guided first-run setup. Only invoked when stdin is a TTY and no model
/// is configured. Flow: provider -> API key (noecho) -> live model list
/// picker (or typed fallback) -> persist to USER config so every project
/// inherits it.
fn runFirstRunSetup(
    io: std.Io,
    arena: std.mem.Allocator,
    rt: *session_runtime.SessionRuntime,
    ui: *const Ui,
    cfg: *config_mod.Store,
) !void {
    const palette = ui.palette;
    try out(io, "{s}", .{palette.heading("\nfirst-run setup: no model is configured yet.", arena)});
    try out(io, "\npick a provider (enter a number, or press enter to skip and configure later with /provider):\n", .{});
    for (presets, 0..) |p, i| {
        try out(io, "  {d}) {s}\n", .{ i + 1, p.label });
    }
    try out(io, "choice: ", .{});

    var stdin_buf: [256]u8 = undefined;
    var stdin_r = std.Io.File.stdin().reader(io, &stdin_buf);
    const line_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
    const line = try arena.dupe(u8, std.mem.trim(u8, line_raw, " \t\r\n"));
    if (line.len == 0) {
        try out(io, "{s}(skipped — configure later with /provider set ...)\n", .{palette.dim("", arena)});
        return;
    }
    const choice = std.fmt.parseInt(u8, line, 10) catch return error.SetupAborted;
    const preset = presetForChoice(choice) orelse return error.SetupAborted;

    // Custom endpoint: ask for the details.
    var base_url = preset.base_url;
    var key_env = preset.key_env;
    if (preset.custom) {
        try out(io, "base URL (OpenAI-compatible, e.g. https://api.example.com/v1): ", .{});
        const url_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
        base_url = try arena.dupe(u8, std.mem.trim(u8, url_raw, " \t\r\n"));
        if (base_url.len == 0 or !std.mem.startsWith(u8, base_url, "http")) {
            try out(io, "{s}invalid base url{s}\n", .{ palette.err("", arena), "\x1b[0m" });
            return error.SetupAborted;
        }
        try out(io, "API key env var name (enter to skip if none): ", .{});
        const env_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
        key_env = try arena.dupe(u8, std.mem.trim(u8, env_raw, " \t\r\n"));
    }

    // API key first (noecho, never echoed back).
    var key_value: []const u8 = "";
    if (preset.needs_key) {
        if (key_env.len == 0) {
            try out(io, "API key env var name: ", .{});
            const env_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
            key_env = try arena.dupe(u8, std.mem.trim(u8, env_raw, " \t\r\n"));
            if (key_env.len == 0) key_env = "API_KEY";
        }
        try out(io, "{s}\n", .{palette.info(key_env, arena)});
        try out(io, "paste your API key (input hidden): ", .{});
        key_value = secret_mod.readSecret(io, arena) catch "";
        if (key_value.len == 0) {
            try out(io, "{s}no key entered — continuing; set it later with /provider key {s} <value>{s}\n", .{
                palette.warn("", arena), key_env, "\x1b[0m",
            });
        }
    }

    // Live model list; typed fallback when unavailable.
    var model_name: []const u8 = preset.default_model;
    const models_res = models_mod.fetchModels(arena, io, base_url, key_value, std.mem.eql(u8, preset.id, "anthropic"));
    switch (models_res) {
        .models => |list| {
            try out(io, "{s}({d} models available — enter a number, or type a model id){s}\n", .{
                palette.dim("", arena), list.len, "\x1b[0m",
            });
            const shown = @min(list.len, 30);
            for (list[0..shown], 0..) |m, i| {
                try out(io, "  {d}) {s}\n", .{ i + 1, m.id });
            }
            if (list.len > shown) {
                try out(io, "  {s}...and {d} more — type the exact model id{s}\n", .{ palette.dim("", arena), list.len - shown, "\x1b[0m" });
            }
            try out(io, "model: ", .{});
            const pick_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
            const pick = try arena.dupe(u8, std.mem.trim(u8, pick_raw, " \t\r\n"));
            if (pick.len > 0) {
                if (std.fmt.parseInt(usize, pick, 10)) |n| {
                    if (n >= 1 and n <= list.len) {
                        model_name = list[n - 1].id;
                    } else {
                        try out(io, "{s}number not in list; using default {s}{s}\n", .{ palette.warn("", arena), preset.default_model, "\x1b[0m" });
                    }
                } else |_| {
                    if (validModelId(pick)) {
                        model_name = pick;
                    } else {
                        try out(io, "{s}that does not look like a model id; using default {s}{s}\n", .{ palette.warn("", arena), preset.default_model, "\x1b[0m" });
                    }
                }
            }
        },
        .failure => |why| {
            try out(io, "{s}could not fetch models ({s}) — type the model id manually.{s}\n", .{ palette.warn("", arena), why, "\x1b[0m" });
            try out(io, "model [{s}]: ", .{preset.default_model});
            const pick_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
            const pick = try arena.dupe(u8, std.mem.trim(u8, pick_raw, " \t\r\n"));
            if (pick.len > 0 and validModelId(pick)) model_name = pick;
        },
    }

    // Capability probe: one tiny tool-call request. Chat-only models are
    // detected here instead of failing mid-session.
    var tools_enabled = true;
    var context_window: ?u64 = null;
    {
        try out(io, "testing tool support ({s})... ", .{model_name});
        const probe = @import("../providers/probe.zig").probeToolSupport(arena, io, if (std.mem.eql(u8, preset.id, "anthropic")) anthropic.instance else openai.instance, base_url, key_value, model_name);
        switch (probe) {
            .supported => {
                try out(io, "{s}ok — tool calling works{s}\n", .{ palette.success("", arena), "\x1b[0m" });
            },
            .unsupported => |why| {
                try out(io, "{s}no tool calls detected ({s}){s}\n", .{ palette.warn("", arena), why, "\x1b[0m" });
                try out(io, "use as chat-only (no file edits/commands)? [Y/n]: ", .{});
                const ans_raw = stdin_r.interface.takeDelimiterInclusive('\n') catch return error.SetupAborted;
                const ans = std.mem.trim(u8, ans_raw, " \t\r\n");
                if (ans.len == 0 or std.ascii.eqlIgnoreCase(ans, "y")) {
                    tools_enabled = false;
                    try out(io, "{s}chat-only mode enabled{s}\n", .{ palette.info("", arena), "\x1b[0m" });
                }
            },
            .error_ => |why| {
                try out(io, "{s}probe failed ({s}) — continuing{s}\n", .{ palette.warn("", arena), why, "\x1b[0m" });
            },
        }
    }

    // Context window from the fetched list (when the provider advertises
    // it); small windows scale the compaction threshold automatically.
    if (models_res == .models) {
        for (models_res.models) |entry| {
            if (std.mem.eql(u8, entry.id, model_name)) {
                context_window = entry.context_length;
                break;
            }
        }
        if (context_window) |w| {
            try out(io, "{s}context window: {d} tokens{s}\n", .{ palette.dim("", arena), w, "\x1b[0m" });
            if (w < 32_000) {
                try out(io, "{s}small context window — compaction will run aggressively{s}\n", .{ palette.warn("", arena), "\x1b[0m" });
            }
        }
    }

    // Persist to USER config (applies to all projects).
    const user_cfg_path = config_mod.userConfigPath(arena, rt.process_environ) orelse return error.SetupAborted;
    const cwd = std.Io.Dir.cwd();
    var root: std.json.Value = blk: {
        const text = fsutil.readSmallFile(cwd, io, arena, user_cfg_path, config_mod.max_config_bytes) catch
            break :blk .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
    };
    var tmp_store = try config_mod.Store.init(arena);
    defer tmp_store.deinit();
    tmp_store.value = root;
    try tmp_store.setPath("model.provider", .{ .string = preset.id });
    try tmp_store.setPath("model.model", .{ .string = model_name });
    try tmp_store.setPath("model.base_url", .{ .string = base_url });
    if (key_env.len > 0) {
        try tmp_store.setPath("model.api_key_env", .{ .string = key_env });
    }
    if (!std.mem.eql(u8, preset.id, preset.label)) {
        try tmp_store.setPath("model.provider_label", .{ .string = preset.label });
    }
    try tmp_store.setPath("model.tools_enabled", .{ .bool = tools_enabled });
    if (context_window) |w| {
        const scaled: u64 = @max(w * 3 / 4, 4096);
        try tmp_store.setPath("context.max_context_tokens", .{ .integer = @intCast(scaled) });
    }
    root = tmp_store.value;
    if (std.mem.lastIndexOfScalar(u8, user_cfg_path, '/')) |slash| {
        try cwd.createDirPath(io, user_cfg_path[0..slash]);
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = user_cfg_path, .data = aw.written() });

    // Store the key.
    if (key_value.len > 0 and key_env.len > 0) {
        try rt.user_keys.store(io, arena, rt.process_environ, key_env, key_value);
        rt.environ.put(key_env, key_value) catch {};
    }

    // Live-apply.
    try cfg.applyOverride("model.provider", try std.fmt.allocPrint(arena, "\"{s}\"", .{preset.id}), .{ .layer = .user, .origin = user_cfg_path });
    try cfg.applyOverride("model.model", try std.fmt.allocPrint(arena, "\"{s}\"", .{model_name}), .{ .layer = .user, .origin = user_cfg_path });
    try cfg.applyOverride("model.base_url", try std.fmt.allocPrint(arena, "\"{s}\"", .{base_url}), .{ .layer = .user, .origin = user_cfg_path });
    if (key_env.len > 0) {
        try cfg.applyOverride("model.api_key_env", try std.fmt.allocPrint(arena, "\"{s}\"", .{key_env}), .{ .layer = .user, .origin = user_cfg_path });
    }
    try cfg.applyOverride("model.provider_label", try std.fmt.allocPrint(arena, "\"{s}\"", .{preset.label}), .{ .layer = .user, .origin = user_cfg_path });
    try cfg.applyOverride("model.tools_enabled", (if (tools_enabled) "true" else "false"), .{ .layer = .user, .origin = user_cfg_path });
    if (context_window) |w| {
        const scaled: u64 = @max(w * 3 / 4, 4096);
        try cfg.applyOverride("context.max_context_tokens", try std.fmt.allocPrint(arena, "{d}", .{scaled}), .{ .layer = .user, .origin = user_cfg_path });
    }

    try out(io, "\n{s}setup complete{s} — {s} · {s}\nsaved to {s}\n", .{
        palette.success("", arena), "\x1b[0m", preset.label, model_name, user_cfg_path,
    });
    if (key_value.len > 0) {
        try out(io, "{s}key stored ({s}){s}\n", .{ palette.dim("", arena), secret_mod.masked(arena, key_value), "\x1b[0m" });
    }
}

/// Resolve `sessions.dir` (A-T07). "project" is the zero-config location;
/// any other value is used as given (relative to the workspace or absolute).
fn sessionsDir(arena: std.mem.Allocator, cfg: *const config_mod.Store) []const u8 {
    _ = arena;
    const v = cfg.getString("sessions.dir", "project");
    if (v.len == 0 or std.mem.eql(u8, v, "project")) return ".ifnh/sessions";
    return v;
}

fn ensureIfnh(io: std.Io, cwd: std.Io.Dir) !void {
    const dirs = [_][]const u8{ ".ifnh", ".ifnh/sessions", ".ifnh/plans" };
    for (dirs) |d| try cwd.createDirPath(io, d);
    // The grants file is per-user state, never shared through the repository.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const current: ?[]const u8 = if (isFile(cwd, io, ".ifnh/.gitignore"))
        try fsutil.readSmallFile(cwd, io, arena, ".ifnh/.gitignore", 64 * 1024)
    else
        null;
    if (try local_grants_mod.gitignoreUpdate(arena, current, "sessions/\ncache/\ndebug/\nreports/\n")) |text| {
        try fsutil.atomicWriteFile(cwd, io, arena, ".ifnh/.gitignore", text);
    }
}

fn isFile(cwd: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const st = cwd.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

// ---------------------------------------------------------------- slash commands

const CommandAction = union(enum) { none, quit, submit: []const u8 };

/// Built-in slash commands, for Tab completion. Every name must be handled in
/// `handleCommand` (a test checks the source); disk commands in
/// `.ifnh/commands/` are not listed.
pub const commands = [_][]const u8{
    "help",      "quit",      "model", "config",  "context",  "undo",
    "redo",      "diff",      "plan",  "agents",  "mcp",      "exec",
    "review",    "reconcile", "usage", "compact", "sessions", "provider",
    "lifecycle", "skills",
};

fn handleCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    cwd: std.Io.Dir,
    rt: *session_runtime.SessionRuntime,
    ui: *const Ui,
    events: *const session_runtime.Events,
    cfg: *config_mod.Store,
    cmd: []const u8,
    rest: []const u8,
    instr: instructions_mod.Assembled,
) CommandAction {
    const palette = ui.palette;
    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) {
        return .quit;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
        out(io,
            \\commands:
            \\  /help                 this text
            \\  /quit                 exit ifnh
            \\  /model <name>         switch model for this session
            \\  /config               show resolved configuration
            \\  /context              show assembled system prompt sources
            \\  /undo                 undo last file-mutation group
            \\  /redo                 redo
            \\  /diff                 show git diff of the working tree
            \\  /plan <title>         create a plan artifact in .ifnh/plans/
            \\  /agents               list subagent reports
            \\  /mcp                  list MCP servers/tools
            \\  /exec                 list background executions
            \\  /review override <r>  override last blocked review (audited)
            \\  /reconcile <path>     spawn reconciliation agent for a path
            \\  /usage                session token usage
            \\  /compact              compact the conversation context
            \\  /sessions             list sessions (use `ifnh resume <id>`)
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "model")) {
        if (rest.len > 0) {
            if (!validModelId(rest)) {
                out(io, "{s}'{s}' does not look like a model id (api keys are not model ids){s}\n", .{ palette.warn("", arena), rest, "\x1b[0m" }) catch {};
                return .none;
            }
            const json = std.fmt.allocPrint(arena, "\"{s}\"", .{rest}) catch return .none;
            cfg.applyOverride("model.model", json, .{ .layer = .session, .origin = "session" }) catch {
                out(io, "invalid model value\n", .{}) catch {};
                return .none;
            };
            rt.overrides.append(arena, .{ .path = "model.model", .json = json }) catch {};
            out(io, "model set to {s} for this session\n", .{rest}) catch {};
        } else {
            out(io, "usage: /model <name>\n", .{}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "config")) {
        out(io, "model: {s} / {s}\n", .{ cfg.getString("model.provider", ""), cfg.getString("model.model", "") }) catch {};
        out(io, "permissions.default_mode: {s}\n", .{cfg.getString("permissions.default_mode", "")}) catch {};
        out(io, "agents.max_depth: {d}\n", .{cfg.getU32("agents.max_depth", 1)}) catch {};
    } else if (std.mem.eql(u8, cmd, "context")) {
        out(io, "assembled context ({d} sources):\n", .{instr.sources.len}) catch {};
        for (instr.sources) |s| out(io, "  [{s}] {s}\n", .{ s.layer, s.path }) catch {};
    } else if (std.mem.eql(u8, cmd, "undo")) {
        if (rt.journal.undo() catch null) |gid| {
            out(io, "undone group {d}\n", .{gid}) catch {};
        } else out(io, "nothing to undo\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "redo")) {
        if (rt.journal.redo() catch null) |gid| {
            out(io, "redone group {d}\n", .{gid}) catch {};
        } else out(io, "nothing to redo\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "diff")) {
        const diff_result = std.process.run(arena, io, .{
            .argv = &.{ "git", "diff" },
            .stdout_limit = .limited(max_output_bytes),
        }) catch {
            out(io, "git diff failed (is this a git repository?)\n", .{}) catch {};
            return .none;
        };
        if (diff_result.stdout.len == 0) out(io, "(no unstaged changes)\n", .{}) catch {};
        out(io, "{s}", .{diff_result.stdout}) catch {};
    } else if (std.mem.eql(u8, cmd, "plan")) {
        createPlan(io, cwd, arena, rest) catch |err| {
            out(io, "plan creation failed: {s}\n", .{@errorName(err)}) catch {};
        };
    } else if (std.mem.eql(u8, cmd, "lifecycle")) {
        if (!std.mem.startsWith(u8, rest, "run ")) {
            out(io, "usage: /lifecycle run <file.json>\n", .{}) catch {};
            return .none;
        }
        var file_part = std.mem.trim(u8, rest[4..], " \t");
        var start_stage: usize = 0;
        if (std.mem.indexOf(u8, file_part, "--from ")) |pos| {
            const stage_name = std.mem.trim(u8, file_part[pos + 7 ..], " \t");
            file_part = std.mem.trim(u8, file_part[0..pos], " \t");
            start_stage = std.fmt.parseInt(usize, stage_name, 10) catch 0;
        }
        const text = fsutil.readSmallFile(cwd, io, arena, file_part, 256 * 1024) catch {
            out(io, "cannot read {s}\n", .{file_part}) catch {};
            return .none;
        };
        const lc = lifecycle_mod.parse(arena, text) catch {
            out(io, "invalid lifecycle file {s}\n", .{file_part}) catch {};
            return .none;
        };
        out(io, "running lifecycle '{s}' ({d} stages, from {d})\n", .{ lc.name, lc.stages.len, start_stage }) catch {};

        // Build a host for lifecycle children (reuses the turn host pieces).
        var cancel2 = std.atomic.Value(bool).init(false);
        var gate2 = session_runtime.Gate.init(rt, events);
        var host2 = subagent_mod.Host{
            .io = io,
            .workspace = cwd,
            .base_system = instr.text,
            .provider = rt.providerConfig(cfg).provider,
            .base_url = rt.providerConfig(cfg).base_url,
            .api_key = rt.providerConfig(cfg).api_key,
            .default_model = rt.providerConfig(cfg).model,
            .client = &rt.http,
            .mode = rt.engine.mode,
            .read_globs = rt.engine.read_globs,
            .write_globs = rt.engine.write_globs,
            .command_allow = rt.engine.command_allow,
            .command_deny = rt.engine.command_deny,
            .env_allow = rt.engine.env_allow,
            .git_commits = rt.engine.git_commits,
            .git_push = rt.engine.git_push,
            .git_force_push = rt.engine.git_force_push,
            .read_dotenv = rt.engine.read_dotenv,
            .use_external_tools = cfg.getBool("tools.external", true),
            .timeout_tool_s = cfg.getU32("agents.timeout_tool_s", 120),
            .journal = &rt.journal,
            .approval_ctx = &gate2,
            .approval_fn = session_runtime.Gate.approve,
            .max_depth = cfg.getU32("agents.max_depth", 1),
            .max_concurrent = cfg.getU32("agents.max_concurrent", 4),
            .max_rounds = cfg.getU32("agents.max_tool_rounds", 25),
            .redactions = &.{},
            .cancel = &cancel2,
            .git = if (git_mod.discover(io, arena, cwd)) |ws| ws.git else null,
            .worktree_root = blk: {
                const state_root = config_mod.userStateDir(arena, rt.process_environ) orelse break :blk null;
                const root2 = std.fmt.allocPrint(arena, "{s}/worktrees", .{state_root}) catch break :blk null;
                cwd.createDirPath(io, root2) catch {};
                break :blk root2;
            },
            .session_hint = rt.store.manifest.id,
        };
        const outcomes = lifecycle_mod.run(arena, io, &host2, lc, start_stage, .{
            .ctx = io.userdata.?,
            .on_stage_start = struct {
                fn f(_: *anyopaque, stage: []const u8, role: []const u8) void {
                    _ = stage;
                    _ = role;
                }
            }.f,
            .on_stage_done = struct {
                fn f(_: *anyopaque, o: lifecycle_mod.StageOutcome) void {
                    _ = o;
                }
            }.f,
            .approve = struct {
                fn f(_: *anyopaque, stage: []const u8, summary: []const u8) bool {
                    _ = stage;
                    _ = summary;
                    return true; // approval surfaces via child reports in M1
                }
            }.f,
        }) catch |err| {
            out(io, "lifecycle failed: {s}\n", .{@errorName(err)}) catch {};
            return .none;
        };
        for (outcomes) |o| {
            out(io, "  [{s}] {s}{s}\n", .{
                @tagName(o.status),
                o.stage,
                if (o.blockers > 0) " (blockers)" else "",
            }) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "exec")) {
        if (rt.executions) |reg| {
            _ = reg.reap();
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (&reg.slots) |*s| {
                if (!s.used) continue;
                buf.print(arena, "  exec {d}: {s} [{s}]\n", .{ s.id, s.command[0..s.command_len], @tagName(session_runtime.u8ToState(s.state.load(.acquire))) }) catch {};
            }
            if (buf.items.len == 0) out(io, "no background executions\n", .{}) catch {} else out(io, "{s}", .{buf.items}) catch {};
        } else out(io, "background executions unavailable\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "provider")) {
        const pcfg_now = rt.providerConfig(cfg);
        if (rest.len == 0 or std.mem.eql(u8, rest, "show")) {
            const key_state = if (pcfg_now.api_key.len > 0)
                palette.success("found", arena)
            else
                palette.warn("MISSING", arena);
            const show_label = cfg.getOptionalString("model.provider_label") orelse cfg.getString("model.provider", "openai");
            const tools_state = if (cfg.getBool("model.tools_enabled", true))
                palette.success("on", arena)
            else
                palette.warn("off (chat-only)", arena);
            const cw = cfg.getOptionalU32("context.max_context_tokens");
            out(io, "provider: {s}\nmodel: {s}\nbase_url: {s}\nkey env: {s} ({s})\ntools: {s}{s}\n", .{
                show_label,
                pcfg_now.model,
                pcfg_now.base_url,
                cfg.getOptionalString("model.api_key_env") orelse "(default)",
                key_state,
                tools_state,
                if (cw != null) std.fmt.allocPrint(arena, ", compaction threshold {d} tokens", .{cw.?}) catch "" else "",
            }) catch {};
            if (rest.len == 0) out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n       /provider key <ENV_NAME> <value>\n", .{}) catch {};
        } else if (std.mem.startsWith(u8, rest, "set ")) {
            var toks = std.mem.tokenizeAny(u8, rest[4..], " ");
            const prov = toks.next() orelse {
                out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n", .{}) catch {};
                return .none;
            };
            const model_name = toks.next() orelse {
                out(io, "usage: /provider set <provider> <model> [base_url] [key_env]\n", .{}) catch {};
                return .none;
            };
            if (!validModelId(model_name)) {
                out(io, "{s}'{s}' does not look like a model id (api keys are not model ids){s}\n", .{ palette.warn("", arena), model_name, "\x1b[0m" }) catch {};
                return .none;
            }
            const base = toks.next();
            const key_env = toks.next();
            if (persistProjectConfig(io, arena, cfg, prov, model_name, base, key_env)) |msg| {
                out(io, "{s}\n", .{msg}) catch {};
            } else |err| {
                out(io, "failed to write .ifnh/config.json: {s}\n", .{@errorName(err)}) catch {};
            }
        } else if (std.mem.startsWith(u8, rest, "key ")) {
            var toks = std.mem.tokenizeAny(u8, rest[4..], " ");
            const name = toks.next() orelse {
                out(io, "usage: /provider key <ENV_NAME> [value]  (value prompted hidden if omitted)\n", .{}) catch {};
                return .none;
            };
            var value = toks.next();
            if (value != null and std.mem.indexOfScalar(u8, value.?, ' ') != null) {
                out(io, "key values must not contain spaces\n", .{}) catch {};
                return .none;
            }
            if (value == null) {
                // Secure entry: no echo, nothing in scrollback or args.
                out(io, "value for {s} (input hidden): ", .{name}) catch {};
                value = secret_mod.readSecret(io, arena) catch null;
                if (value == null or value.?.len == 0) {
                    out(io, "no key entered\n", .{}) catch {};
                    return .none;
                }
            }
            rt.user_keys.store(io, arena, rt.process_environ, name, value.?) catch |err| {
                out(io, "failed to store key: {s}\n", .{@errorName(err)}) catch {};
                return .none;
            };
            // Visible for the rest of this session immediately.
            rt.environ.put(name, value.?) catch {};
            const stored_at = keys_mod.Keys.path(arena, rt.process_environ) orelse "the user env file";
            out(io, "{s}stored {s} in {s} (0600); takes effect immediately{s}\n", .{
                palette.success("", arena), name, stored_at, "\x1b[0m",
            }) catch {};
        } else if (std.mem.startsWith(u8, rest, "tools ")) {
            const mode = std.mem.trim(u8, rest[6..], " \t");
            if (std.mem.eql(u8, mode, "off")) {
                cfg.applyOverride("model.tools_enabled", "false", .{ .layer = .session, .origin = "session" }) catch {};
                rt.overrides.append(arena, .{ .path = "model.tools_enabled", .json = "false" }) catch {};
                out(io, "{s}tools disabled — chat-only mode (persists this session; use /provider tools on to re-enable){s}\n", .{ palette.warn("", arena), "\x1b[0m" }) catch {};
            } else if (std.mem.eql(u8, mode, "on")) {
                cfg.applyOverride("model.tools_enabled", "true", .{ .layer = .session, .origin = "session" }) catch {};
                rt.overrides.append(arena, .{ .path = "model.tools_enabled", .json = "true" }) catch {};
                out(io, "{s}tools enabled{s}\n", .{ palette.success("", arena), "\x1b[0m" }) catch {};
            } else {
                out(io, "usage: /provider tools <on|off>\n", .{}) catch {};
            }
        } else {
            out(io, "usage: /provider [show|set <provider> <model> [base_url] [key_env]|key <ENV_NAME> <value>|tools <on|off>]\n", .{}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "review")) {
        // M2-T03 (G96/97): developer-only override of the last blocked review.
        if (!std.mem.startsWith(u8, rest, "override ")) {
            out(io, "usage: /review override <reason>\n", .{}) catch {};
            return .none;
        }
        const reason = std.mem.trim(u8, rest[9..], " \t");
        if (reason.len == 0) {
            out(io, "a reason is required for audit purposes\n", .{}) catch {};
            return .none;
        }
        const stage = rt.last_blocked_stage orelse {
            out(io, "no blocked review in this session to override\n", .{}) catch {};
            return .none;
        };
        cwd.createDirPath(io, ".ifnh/reports") catch {};
        const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
        const audit_path = std.fmt.allocPrint(arena, ".ifnh/reports/override-{d}.md", .{ts_ms}) catch return .none;
        const audit = std.fmt.allocPrint(arena,
            \\# Review Override
            \\
            \\- stage: {s}
            \\- ts_ms: {d}
            \\- decided_by: developer (only a human may override a review)
            \\- reason: {s}
            \\
            \\The blocked review for this stage was explicitly overridden by the
            \\developer. This record is the durable audit trail (G97).
            \\
        , .{ stage, ts_ms, reason }) catch return .none;
        fsutil.atomicWriteFile(cwd, io, arena, audit_path, audit) catch {};
        rt.last_blocked_stage = null;
        out(io, "review for '{s}' overridden; audit: {s}\n", .{ stage, audit_path }) catch {};
        out(io, "resume with /lifecycle run <file> --from <n>\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "reconcile")) {
        // M2-T04 (D045/046): reconciliation agent for conflicting edits.
        const rpath = std.mem.trim(u8, rest, " \t");
        if (rpath.len == 0) {
            out(io, "usage: /reconcile <path>\n", .{}) catch {};
            return .none;
        }
        const versions = rt.journal.versionsForPath(arena, rpath) catch &.{};
        if (versions.len < 2) {
            out(io, "no conflicting versions of '{s}' in the journal\n", .{rpath}) catch {};
            return .none;
        }
        out(io, "reconciling '{s}': {d} competing versions found\n", .{ rpath, versions.len }) catch {};
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        payload.print(arena,
            \\Reconcile conflicting implementations of '{s}'. Below are the
            \\competing versions recorded in the undo journal. Produce a combined
            \\solution that preserves the intent of both, then verify it compiles
            \\and tests pass. The result goes through normal review and approval.
            \\
            \\
        , .{rpath}) catch return .none;
        for (versions, 0..) |v, i| {
            payload.print(arena, "\n## Version {d}\n```\n{s}\n```\n", .{ i + 1, v }) catch {};
        }
        return .{ .submit = payload.items };
    } else if (std.mem.eql(u8, cmd, "usage")) {
        const raw = fsutil.readSmallFile(rt.store.dir, io, arena, "usage.jsonl", 1024 * 1024) catch "";
        const text = budget_mod.formatSummary(arena, budget_mod.summarize(arena, raw), cfg.getOptionalF64("agents.budget_usd")) catch "usage unavailable\n";
        out(io, "{s}", .{text}) catch {};
    } else if (std.mem.eql(u8, cmd, "compact")) {
        const pcfg2 = rt.providerConfig(cfg);
        out(io, "[compacting context...]\n", .{}) catch {};
        const res_opt: ?compaction_mod.Result = blk: {
            break :blk compaction_mod.compact(arena, io, pcfg2, &rt.history, &.{}) catch |err| {
                out(io, "compaction failed: {s}\n", .{@errorName(err)}) catch {};
                break :blk null;
            };
        };
        if (res_opt) |res| {
            rt.history.clearRetainingCapacity();
            rt.history.appendSlice(arena, res.history) catch {};
            _ = rt.store.append(.{ .note = .{ .text = "manual compaction" } }) catch {};
            out(io, "[compacted: {d} -> {d} tokens]\n", .{ res.tokens_before, res.tokens_after }) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "skills")) {
        if (rt.skills) |catalog| {
            if (catalog.skills.len == 0) {
                if (config_mod.userSkillsDir(arena, rt.process_environ)) |user_skills| {
                    out(io, "no skills installed (.ifnh/skills/, {s}/)\n", .{user_skills}) catch {};
                } else out(io, "no skills installed (.ifnh/skills/)\n", .{}) catch {};
            }
            for (catalog.skills) |s| {
                out(io, "  [{s}] {s}: {s}\n", .{ s.scope, s.name, s.description }) catch {};
            }
        } else out(io, "skills unavailable\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        if (rt.mcp_registry) |reg| {
            if (reg.configs.len == 0) {
                out(io, "no MCP servers configured (mcp_servers in config)\n", .{}) catch {};
            }
            for (reg.configs) |c| {
                out(io, "  {s}: {s}\n", .{ c.name, c.command }) catch {};
            }
            out(io, "{s}", .{rt.mcpListText(arena)}) catch {};
        } else out(io, "MCP not available\n", .{}) catch {};
    } else if (std.mem.eql(u8, cmd, "agents")) {
        out(io, "subagents run inline during turns; reports:\n", .{}) catch {};
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (cwd.openDir(io, ".ifnh/reports", .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                names.append(arena, arena.dupe(u8, entry.name) catch continue) catch {};
            }
        } else |_| {}
        if (names.items.len == 0) {
            out(io, "no agent reports\n", .{}) catch {};
        } else {
            std.mem.sort([]const u8, names.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (names.items) |n| out(io, "  .ifnh/reports/{s}\n", .{n}) catch {};
        }
    } else if (std.mem.eql(u8, cmd, "sessions")) {
        const summaries = session_mod.list(cwd, io, arena, sessionsDir(arena, cfg)) catch &.{};
        if (summaries.len == 0) {
            out(io, "no sessions\n", .{}) catch {};
        }
        for (summaries) |s| {
            out(io, "  {s}  {d}  {s}\n", .{ s.id, s.created_ms, s.cwd }) catch {};
        }
    } else if (loadDiskCommand(io, arena, cwd, cmd, rest)) |prompt| {
        return .{ .submit = prompt };
    } else {
        out(io, "unknown command /{s} (try /help)\n", .{cmd}) catch {};
    }
    return .none;
}

/// Disk-backed slash command (D030, M0-T37): `.ifnh/commands/<name>.md`
/// with optional frontmatter; `$ARGS` in the body is replaced by the
/// command arguments. The body is submitted as the user's prompt.
fn loadDiskCommand(io: std.Io, arena: std.mem.Allocator, cwd: std.Io.Dir, cmd: []const u8, args: []const u8) ?[]const u8 {
    var name_buf: [128]u8 = undefined;
    if (cmd.len == 0 or cmd.len > 64) return null;
    for (cmd) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
    }
    const rel = std.fmt.bufPrint(&name_buf, ".ifnh/commands/{s}.md", .{cmd}) catch return null;
    const raw = fsutil.readSmallFile(cwd, io, arena, rel, 64 * 1024) catch return null;

    // Strip YAML-ish frontmatter (--- ... ---) if present.
    var body = raw;
    if (std.mem.startsWith(u8, body, "---")) {
        if (std.mem.indexOfPos(u8, body, 3, "\n---")) |end| {
            const after = body[end + 4 ..];
            body = if (after.len > 0 and after[0] == '\n') after[1..] else after;
        }
    }
    if (std.mem.indexOf(u8, body, "$ARGS")) |pos| {
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ body[0..pos], args, body[pos + "$ARGS".len ..] }) catch null;
    }
    if (args.len > 0) {
        return std.fmt.allocPrint(arena, "{s}\n\nArguments: {s}", .{ body, args }) catch null;
    }
    return body;
}

fn createPlan(io: std.Io, cwd: std.Io.Dir, arena: std.mem.Allocator, title: []const u8) !void {
    try cwd.createDirPath(io, ".ifnh/plans");
    const ts_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const id = std.fmt.allocPrint(arena, "plan-{d}", .{ts_ms}) catch return error.OutOfMemory;
    const path = std.fmt.allocPrint(arena, ".ifnh/plans/{s}.md", .{id}) catch return error.OutOfMemory;
    const content = std.fmt.allocPrint(arena,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: draft
        \\created_ms: {d}
        \\---
        \\
        \\# Plan: {s}
        \\
        \\## Goal
        \\
        \\## Approach
        \\
        \\## Steps
        \\
        \\1.
        \\
        \\## Verification
        \\
        \\
    , .{ id, if (title.len > 0) title else "untitled", ts_ms, if (title.len > 0) title else "untitled" }) catch return error.OutOfMemory;
    try cwd.writeFile(io, .{ .sub_path = path, .data = content });
    out(io, "created {s}\n", .{path}) catch {};
}

fn out(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

// ---------------------------------------------------------------- tests

test "every completable command is dispatched by handleCommand" {
    const source = @embedFile("repl.zig");
    for (commands) |name| {
        const needle = std.fmt.allocPrint(std.testing.allocator, "std.mem.eql(u8, cmd, \"{s}\")", .{name}) catch return error.OutOfMemory;
        defer std.testing.allocator.free(needle);
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("command '{s}' is listed in `commands` but not dispatched\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "default config denies git push and gates dotenv" {
    var cfg = try config_mod.Store.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.validate();
    try std.testing.expect(cfg.errors.items.len == 0);

    var e = session_runtime.engineFromConfig(std.testing.allocator, &cfg);
    defer e.deinit();
    try std.testing.expectEqual(engine_mod.Decision.deny, e.decideCommand("git push origin main"));
    try std.testing.expectEqual(engine_mod.Decision.deny, e.decideCommand("git push --force origin main"));
    try std.testing.expectEqual(engine_mod.Decision.ask, e.decideCommand("git commit -m x"));
    try std.testing.expect(!e.read_dotenv);

    // Lowering the ceilings through config is honored.
    try cfg.applyOverride("git.push", "\"auto\"", .{ .layer = .project, .origin = "test" });
    try cfg.applyOverride("permissions.read_dotenv", "true", .{ .layer = .project, .origin = "test" });
    var e2 = session_runtime.engineFromConfig(std.testing.allocator, &cfg);
    defer e2.deinit();
    try std.testing.expectEqual(engine_mod.Decision.allow, e2.decideCommand("git push origin main"));
    try std.testing.expect(e2.read_dotenv);
    // Unknown policy values fall back to the fail-closed default.
    try cfg.applyOverride("git.force_push", "\"sometimes\"", .{ .layer = .project, .origin = "test" });
    var e3 = session_runtime.engineFromConfig(std.testing.allocator, &cfg);
    defer e3.deinit();
    try std.testing.expectEqual(engine_mod.Decision.deny, e3.decideCommand("git push --force origin main"));
}
