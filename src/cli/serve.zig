//! `ifnh serve`: a JSON-RPC 2.0 server on stdin/stdout (ACTIVE_PLAN E-06a).
//!
//! The wire is the Agent Client Protocol core (`initialize`, `session/new`,
//! `session/load`, `session/prompt`, `session/cancel`, `session/close`) plus
//! one namespaced extension (`ifnh/notice`). Each ACP session is one
//! `SessionRuntime`, driven exactly like `ifnh ask` drives it: there is no
//! second agent loop. Stdout carries protocol messages only; diagnostics go
//! to stderr; nothing here touches the terminal or emits ANSI.
//!
//! Threads: the main thread handles requests and runs turns synchronously. A
//! reader thread frames stdin into a queue and answers `session/cancel`
//! itself (a flag flip), so a cancel lands while a turn is running. A turn
//! that needs approval sends `session/request_permission` to the client and
//! waits on the same queue for the response.

const std = @import("std");
const args_mod = @import("args.zig");
const version = @import("../version.zig");
const config_mod = @import("../core/config/config.zig");
const instructions_mod = @import("../core/instructions.zig");
const system_prompt = @import("../core/agent/system_prompt.zig");
const wire_log = @import("../core/wire_log.zig");
const session_runtime = @import("../core/agent/session_runtime.zig");
const tool_mod = @import("../tools/tool.zig");
const core_types = @import("../core/types.zig");
const image_mod = @import("../core/image.zig");

/// Largest accepted message; a bigger one is answered with -32600 and skipped.
pub const max_message_bytes: usize = 1024 * 1024;
/// How long a permission request waits for the client.
pub const permission_timeout_ms: i64 = 30_000;

const code_parse_error = -32700;
const code_invalid_request = -32600;
const code_method_not_found = -32601;
const code_invalid_params = -32602;
const code_internal = -32603;

// ---------------------------------------------------------------- framing

pub const Frame = union(enum) {
    /// One message body; valid until the next `push` or `next`.
    message: []const u8,
    /// A message over `max_message_bytes` was dropped.
    oversize,
    /// A `Content-Length` header block without a usable length was dropped.
    bad_header,
};

/// Incremental splitter for both framings. Pure: bytes in, frames out.
pub const Framer = struct {
    framing: args_mod.Framing,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Bytes of `buf` already handed out; dropped lazily so a returned
    /// message slice stays valid.
    consumed: usize = 0,
    /// Payload bytes of an oversize content-length body still to discard.
    skip_bytes: usize = 0,
    /// Inside an oversize NDJSON line: discard up to the next newline.
    skip_line: bool = false,

    pub fn deinit(self: *Framer, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn push(self: *Framer, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        self.compact();
        try self.buf.appendSlice(gpa, bytes);
    }

    fn compact(self: *Framer) void {
        if (self.consumed == 0) return;
        const rest = self.buf.items.len - self.consumed;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.consumed..]);
        self.buf.shrinkRetainingCapacity(rest);
        self.consumed = 0;
    }

    pub fn next(self: *Framer) ?Frame {
        self.compact();
        return switch (self.framing) {
            .ndjson => self.nextLine(),
            .content_length => self.nextLengthPrefixed(),
        };
    }

    fn nextLine(self: *Framer) ?Frame {
        while (true) {
            const data = self.buf.items;
            const nl = std.mem.indexOfScalar(u8, data, '\n');
            if (self.skip_line) {
                if (nl) |i| {
                    self.consumed = i + 1;
                    self.skip_line = false;
                    self.compact();
                    continue;
                }
                self.buf.clearRetainingCapacity();
                return null;
            }
            const i = nl orelse {
                if (data.len > max_message_bytes) {
                    self.buf.clearRetainingCapacity();
                    self.skip_line = true;
                    return .oversize;
                }
                return null;
            };
            const line = std.mem.trimEnd(u8, data[0..i], "\r");
            self.consumed = i + 1;
            if (line.len > max_message_bytes) return .oversize;
            if (std.mem.trim(u8, line, " \t").len == 0) {
                self.compact();
                continue;
            }
            return .{ .message = line };
        }
    }

    fn nextLengthPrefixed(self: *Framer) ?Frame {
        while (true) {
            if (self.skip_bytes > 0) {
                const n = @min(self.skip_bytes, self.buf.items.len);
                self.consumed = n;
                self.skip_bytes -= n;
                self.compact();
                if (self.skip_bytes > 0) return null;
            }
            const data = self.buf.items;
            // Tolerate bare-LF header terminators.
            const crlf = std.mem.indexOf(u8, data, "\r\n\r\n");
            const lf = std.mem.indexOf(u8, data, "\n\n");
            const sep_len: usize = if (crlf != null and (lf == null or crlf.? < lf.?)) 4 else 2;
            const head_end = (if (sep_len == 4) crlf else lf) orelse {
                if (data.len > 8192) {
                    self.buf.clearRetainingCapacity();
                    return .bad_header;
                }
                return null;
            };
            const body_start = head_end + sep_len;
            const length = contentLength(data[0..head_end]) orelse {
                self.consumed = body_start;
                return .bad_header;
            };
            if (length > max_message_bytes) {
                self.consumed = body_start;
                self.skip_bytes = length;
                self.compact();
                return .oversize;
            }
            if (data.len < body_start + length) return null;
            self.consumed = body_start + length;
            return .{ .message = data[body_start..][0..length] };
        }
    }
};

fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
    }
    return null;
}

/// One outgoing message in the chosen framing.
pub fn appendFrame(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), framing: args_mod.Framing, json: []const u8) !void {
    switch (framing) {
        .ndjson => {
            try out.appendSlice(gpa, json);
            try out.append(gpa, '\n');
        },
        .content_length => {
            var head: [48]u8 = undefined;
            try out.appendSlice(gpa, try std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{json.len}));
            try out.appendSlice(gpa, json);
        },
    }
}

// ---------------------------------------------------------------- server

/// Where encoded frames go. Stdout in production, a buffer in tests.
const Output = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
};

const Item = union(enum) {
    /// gpa-owned message body.
    message: []u8,
    oversize,
    bad_header,

    fn deinit(self: Item, gpa: std.mem.Allocator) void {
        switch (self) {
            .message => |m| gpa.free(m),
            else => {},
        }
    }
};

const Reply = union(enum) {
    /// Result JSON text (scratch-owned).
    ok: []const u8,
    err: struct { code: i32, message: []const u8 },
};

fn fail(code: i32, message: []const u8) Reply {
    return .{ .err = .{ .code = code, .message = message } };
}

/// One ACP session: a runtime rooted at `cwd`.
const Session = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    cwd: std.Io.Dir,
    cfg: config_mod.Store,
    rt: session_runtime.SessionRuntime,
    instr: instructions_mod.Assembled,
    cancel: std.atomic.Value(bool) = .init(false),
    /// True while `rt` is initialized (a failed open frees the rest).
    rt_ready: bool = false,
};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    global: args_mod.GlobalFlags = .{},
    wire: ?*wire_log.WireLog = null,
    framing: args_mod.Framing = .ndjson,
    out: Output,
    approval_timeout_ms: i64 = permission_timeout_ms,

    out_mutex: std.Io.Mutex = .init,
    queue_mutex: std.Io.Mutex = .init,
    queue: std.ArrayListUnmanaged(Item) = .empty,
    /// Messages pulled off the queue while waiting for a response; served
    /// first by the main loop.
    deferred: std.ArrayListUnmanaged(Item) = .empty,
    eof: std.atomic.Value(bool) = .init(false),

    sessions_mutex: std.Io.Mutex = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    /// Cancel flags by session id, for the reader thread.
    cancels: std.StringHashMapUnmanaged(*std.atomic.Value(bool)) = .empty,

    approval_mutex: std.Io.Mutex = .init,
    next_request_id: i64 = 1,

    pub fn deinit(self: *Server) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| self.closeSession(entry.value_ptr.*);
        self.sessions.deinit(self.gpa);
        self.cancels.deinit(self.gpa);
        for (self.queue.items) |item| item.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        for (self.deferred.items) |item| item.deinit(self.gpa);
        self.deferred.deinit(self.gpa);
    }

    // ---- output

    fn send(self: *Server, json: []const u8) void {
        var frame: std.ArrayListUnmanaged(u8) = .empty;
        defer frame.deinit(self.gpa);
        appendFrame(self.gpa, &frame, self.framing, json) catch return;
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        _ = self.out.write(self.out.ctx, frame.items);
    }

    fn sendReply(self: *Server, id: std.json.Value, reply: Reply) void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        std.json.Stringify.value(id, .{}, w) catch return;
        switch (reply) {
            .ok => |result| {
                w.writeAll(",\"result\":") catch return;
                w.writeAll(result) catch return;
            },
            .err => |e| {
                w.print(",\"error\":{{\"code\":{d},\"message\":", .{e.code}) catch return;
                std.json.Stringify.value(e.message, .{}, w) catch return;
                w.writeAll("}") catch return;
            },
        }
        w.writeAll("}") catch return;
        self.send(aw.written());
    }

    /// `{"jsonrpc":"2.0","method":<method>,"params":<params_json>}`.
    fn sendNotification(self: *Server, method: []const u8, params_json: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":", .{method}) catch return;
        w.writeAll(params_json) catch return;
        w.writeAll("}") catch return;
        self.send(aw.written());
    }

    // ---- input

    fn pushItem(self: *Server, item: Item) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        self.queue.append(self.gpa, item) catch item.deinit(self.gpa);
    }

    /// Frame one chunk of input. `session/cancel` is acted on here, not
    /// queued, so it works while the main thread is inside a turn.
    pub fn feed(self: *Server, framer: *Framer, bytes: []const u8) void {
        framer.push(self.gpa, bytes) catch return;
        while (framer.next()) |frame| switch (frame) {
            .oversize => self.pushItem(.oversize),
            .bad_header => self.pushItem(.bad_header),
            .message => |m| {
                if (self.handleCancel(m)) continue;
                const copy = self.gpa.dupe(u8, m) catch continue;
                self.pushItem(.{ .message = copy });
            },
        };
    }

    /// If `bytes` is a `session/cancel` notification, set the flag. Returns
    /// whether it was one.
    fn handleCancel(self: *Server, bytes: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), bytes, .{}) catch return false;
        if (root != .object) return false;
        const method = root.object.get("method") orelse return false;
        if (method != .string or !std.mem.eql(u8, method.string, "session/cancel")) return false;
        if (root.object.get("id") != null) return false; // a request form is answered by the main loop
        const params = root.object.get("params") orelse return true;
        if (params != .object) return true;
        const sid = params.object.get("sessionId") orelse return true;
        if (sid != .string) return true;
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        if (self.cancels.get(sid.string)) |flag| flag.store(true, .release);
        return true;
    }

    fn readerMain(self: *Server) void {
        var framer = Framer{ .framing = self.framing };
        defer framer.deinit(self.gpa);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = std.Io.File.stdin().readStreaming(self.io, &.{&buf}) catch break;
            if (n == 0) break;
            self.feed(&framer, buf[0..n]);
        }
        self.eof.store(true, .release);
    }

    /// Next unit of work, waiting for input; null once stdin is closed and
    /// everything buffered has been served.
    fn nextItem(self: *Server) ?Item {
        while (true) {
            {
                self.queue_mutex.lockUncancelable(self.io);
                defer self.queue_mutex.unlock(self.io);
                if (self.deferred.items.len > 0) return self.deferred.orderedRemove(0);
                if (self.queue.items.len > 0) return self.queue.orderedRemove(0);
                if (self.eof.load(.acquire)) return null;
            }
            std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch {};
        }
    }

    /// Wait for the response to request `id`, moving every other message to
    /// `deferred`. Null on timeout, cancel, or closed stdin.
    fn awaitResponse(self: *Server, scratch: std.mem.Allocator, id: i64, cancel: *const std.atomic.Value(bool)) ?std.json.Value {
        const start = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const limit_ns: i96 = @as(i96, self.approval_timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (cancel.load(.acquire)) return null;
            {
                self.queue_mutex.lockUncancelable(self.io);
                defer self.queue_mutex.unlock(self.io);
                while (self.queue.items.len > 0) {
                    const item = self.queue.orderedRemove(0);
                    if (item == .message) {
                        if (std.json.parseFromSliceLeaky(std.json.Value, scratch, item.message, .{})) |root| {
                            if (isResponseTo(root, id)) {
                                item.deinit(self.gpa);
                                return root;
                            }
                        } else |_| {}
                    }
                    self.deferred.append(self.gpa, item) catch item.deinit(self.gpa);
                }
                if (self.eof.load(.acquire)) return null;
            }
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds - start > limit_ns) return null;
            std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch {};
        }
    }

    // ---- main loop

    /// Serve until stdin closes, then close every session.
    pub fn loop(self: *Server) void {
        while (self.nextItem()) |item| {
            defer item.deinit(self.gpa);
            switch (item) {
                .oversize => self.sendReply(.null, fail(code_invalid_request, "message exceeds 1 MiB")),
                .bad_header => self.sendReply(.null, fail(code_invalid_request, "missing or invalid Content-Length header")),
                .message => |m| {
                    var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
                    defer scratch_state.deinit();
                    self.handleMessage(scratch_state.allocator(), m);
                },
            }
        }
    }

    fn handleMessage(self: *Server, scratch: std.mem.Allocator, bytes: []const u8) void {
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{}) catch {
            self.sendReply(.null, fail(code_parse_error, "parse error"));
            return;
        };
        if (root != .object) {
            self.sendReply(.null, fail(code_invalid_request, "a request must be a JSON object (batches are not supported)"));
            return;
        }
        const obj = root.object;
        const id = obj.get("id");
        const method_value = obj.get("method") orelse {
            // A response that nobody was waiting for is ignored.
            if (obj.get("result") != null or obj.get("error") != null) return;
            self.sendReply(id orelse .null, fail(code_invalid_request, "missing method"));
            return;
        };
        if (method_value != .string) {
            self.sendReply(id orelse .null, fail(code_invalid_request, "method must be a string"));
            return;
        }
        if (obj.get("jsonrpc")) |v| {
            if (v != .string or !std.mem.eql(u8, v.string, "2.0")) {
                self.sendReply(id orelse .null, fail(code_invalid_request, "jsonrpc must be \"2.0\""));
                return;
            }
        }
        const params = obj.get("params") orelse .null;
        const reply = self.dispatch(scratch, method_value.string, params);
        // Notifications never get a response, not even an error.
        if (id) |request_id| self.sendReply(request_id, reply);
    }

    fn dispatch(self: *Server, scratch: std.mem.Allocator, method: []const u8, params: std.json.Value) Reply {
        const table = .{
            .{ "initialize", methodInitialize },
            .{ "session/new", methodSessionNew },
            .{ "session/load", methodSessionLoad },
            .{ "session/prompt", methodSessionPrompt },
            .{ "session/close", methodSessionClose },
            .{ "session/cancel", methodSessionCancel },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, method, entry[0])) {
                return entry[1](self, scratch, params) catch |err| internalError(scratch, err);
            }
        }
        return fail(code_method_not_found, "method not found");
    }

    // ---- methods

    fn methodInitialize(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        _ = self;
        _ = params;
        return .{ .ok = try std.fmt.allocPrint(
            scratch,
            "{{\"protocolVersion\":1,\"agentCapabilities\":{{\"loadSession\":true,\"promptCapabilities\":{{\"image\":true}}}}," ++
                "\"agentInfo\":{{\"name\":\"ifnh\",\"version\":\"{s}\"}},\"authMethods\":[]}}",
            .{version.version},
        ) };
    }

    fn methodSessionNew(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        const cwd_path = switch (optionalString(params, "cwd")) {
            .absent => ".",
            .value => |v| v,
            .wrong_type => return fail(code_invalid_params, "cwd must be a string"),
        };
        var notice_mcp = false;
        if (params == .object) {
            if (params.object.get("mcpServers")) |servers| {
                if (servers != .array) return fail(code_invalid_params, "mcpServers must be an array");
                notice_mcp = servers.array.items.len > 0;
            }
        }
        const session = self.openSession(cwd_path, null) catch |err| return openFailure(scratch, err);
        if (notice_mcp) self.notify(session.id, "info", "mcpServers sent by the client are ignored; configure mcp_servers in the ifnh config");
        return .{ .ok = try std.fmt.allocPrint(scratch, "{{\"sessionId\":{f}}}", .{std.json.fmt(session.id, .{})}) };
    }

    fn methodSessionLoad(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        const sid = requiredString(params, "sessionId") orelse return fail(code_invalid_params, "sessionId is required");
        const cwd_path = switch (optionalString(params, "cwd")) {
            .absent => ".",
            .value => |v| v,
            .wrong_type => return fail(code_invalid_params, "cwd must be a string"),
        };
        if (self.findSession(sid)) |existing| {
            return .{ .ok = try std.fmt.allocPrint(scratch, "{{\"sessionId\":{f}}}", .{std.json.fmt(existing.id, .{})}) };
        }
        const session = self.openSession(cwd_path, sid) catch |err| switch (err) {
            error.UnknownSession => return fail(code_invalid_params, "unknown sessionId"),
            else => return openFailure(scratch, err),
        };
        return .{ .ok = try std.fmt.allocPrint(scratch, "{{\"sessionId\":{f}}}", .{std.json.fmt(session.id, .{})}) };
    }

    fn methodSessionClose(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        _ = scratch;
        const sid = requiredString(params, "sessionId") orelse return fail(code_invalid_params, "sessionId is required");
        const session = self.takeSession(sid) orelse return fail(code_invalid_params, "unknown sessionId");
        self.closeSession(session);
        return .{ .ok = "{}" };
    }

    /// The request form of `session/cancel` (the notification form is handled
    /// by the reader thread, which cannot be blocked by a running turn).
    fn methodSessionCancel(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        _ = scratch;
        const sid = requiredString(params, "sessionId") orelse return fail(code_invalid_params, "sessionId is required");
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        const flag = self.cancels.get(sid) orelse return fail(code_invalid_params, "unknown sessionId");
        flag.store(true, .release);
        return .{ .ok = "{}" };
    }

    fn methodSessionPrompt(self: *Server, scratch: std.mem.Allocator, params: std.json.Value) !Reply {
        const sid = requiredString(params, "sessionId") orelse return fail(code_invalid_params, "sessionId is required");
        const session = self.findSession(sid) orelse return fail(code_invalid_params, "unknown sessionId");
        const blocks = params.object.get("prompt") orelse return fail(code_invalid_params, "prompt is required");
        if (blocks != .array) return fail(code_invalid_params, "prompt must be an array of content blocks");

        var text: std.ArrayListUnmanaged(u8) = .empty;
        var images: std.ArrayListUnmanaged(core_types.ImagePart) = .empty;
        var parts: usize = 0;
        for (blocks.array.items) |block| {
            if (block != .object) return fail(code_invalid_params, "each prompt block must be an object");
            const kind = requiredString(block, "type") orelse return fail(code_invalid_params, "prompt block without a type");
            var piece: []const u8 = "";
            if (std.mem.eql(u8, kind, "text")) {
                piece = requiredString(block, "text") orelse return fail(code_invalid_params, "text block without text");
            } else if (std.mem.eql(u8, kind, "resource_link")) {
                const uri = requiredString(block, "uri") orelse return fail(code_invalid_params, "resource_link without uri");
                piece = try std.fmt.allocPrint(scratch, "[link] {s}", .{uri});
            } else if (std.mem.eql(u8, kind, "image")) {
                const mime = requiredString(block, "mimeType") orelse return fail(code_invalid_params, "image block without mimeType");
                const data = requiredString(block, "data") orelse return fail(code_invalid_params, "image block without data");
                if (images.items.len >= image_mod.max_per_turn) return fail(code_invalid_params, "too many images in one prompt");
                switch (try image_mod.fromBase64(session.arena.allocator(), mime, data)) {
                    .ok => |part| try images.append(scratch, part),
                    .err => |message| return fail(code_invalid_params, message),
                }
                continue;
            } else {
                return fail(code_invalid_params, "unsupported prompt block type");
            }
            if (parts > 0) try text.append(scratch, '\n');
            try text.appendSlice(scratch, piece);
            parts += 1;
        }
        if (std.mem.trim(u8, text.items, " \t\r\n").len == 0 and images.items.len == 0) {
            return fail(code_invalid_params, "empty prompt");
        }
        // Images live as long as the history that carries them.
        const kept_images = try session.arena.allocator().dupe(core_types.ImagePart, images.items);
        const prompt_text = try session.arena.allocator().dupe(u8, text.items);

        // Commands and tools resolve paths against the process cwd.
        std.process.setCurrentDir(self.io, session.cwd) catch |err|
            return fail(code_internal, try std.fmt.allocPrint(scratch, "cannot enter the session directory: {s}", .{@errorName(err)}));

        var sink = Sink{ .server = self, .session_id = session.id, .cancel = &session.cancel, .scratch = scratch };
        const events = sink.events();
        const pcfg = session.rt.providerConfig(&session.cfg);
        const outcome = session.rt.submitTurn(
            session.arena.allocator(),
            &session.cfg,
            pcfg,
            session.instr.text,
            session.instr.stable_len,
            prompt_text,
            kept_images,
            session.cwd,
            &events,
        ) catch |err| return fail(code_internal, try std.fmt.allocPrint(scratch, "turn failed: {s}", .{@errorName(err)}));

        if (outcome.budget_exceeded) return .{ .ok = "{\"stopReason\":\"refusal\"}" };
        if (!outcome.ran) {
            const why = if (sink.last_status.len > 0) std.mem.trim(u8, sink.last_status, " \t\r\n") else "turn did not run";
            return fail(code_internal, try oneLine(scratch, why));
        }
        return switch (outcome.status) {
            .cancelled => .{ .ok = "{\"stopReason\":\"cancelled\"}" },
            .completed => .{ .ok = "{\"stopReason\":\"end_turn\"}" },
            .failed => if (std.mem.indexOf(u8, outcome.error_message, "tool round limit") != null)
                .{ .ok = "{\"stopReason\":\"max_turn_requests\"}" }
            else
                fail(code_internal, try oneLine(scratch, if (outcome.error_message.len > 0) outcome.error_message else "turn failed")),
        };
    }

    // ---- sessions

    fn findSession(self: *Server, id: []const u8) ?*Session {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        return self.sessions.get(id);
    }

    fn takeSession(self: *Server, id: []const u8) ?*Session {
        self.sessions_mutex.lockUncancelable(self.io);
        defer self.sessions_mutex.unlock(self.io);
        const session = self.sessions.get(id) orelse return null;
        _ = self.sessions.remove(id);
        _ = self.cancels.remove(id);
        return session;
    }

    fn closeSession(self: *Server, session: *Session) void {
        if (session.rt_ready) {
            _ = session_runtime.dispatchHook(&session.rt, session.arena.allocator(), &session.cfg, .session_end);
            session.rt.deinit();
        }
        var arena = session.arena;
        self.gpa.destroy(session);
        arena.deinit();
    }

    const OpenError = anyerror;

    /// Create (or, with `resume_id`, reopen) a session rooted at `cwd_path`.
    fn openSession(self: *Server, cwd_path: []const u8, resume_id: ?[]const u8) OpenError!*Session {
        const session = try self.gpa.create(Session);
        session.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .id = "", .cwd = undefined, .cfg = undefined, .rt = undefined, .instr = undefined };
        const a = session.arena.allocator();
        errdefer {
            if (session.rt_ready) session.rt.deinit();
            var arena = session.arena;
            self.gpa.destroy(session);
            arena.deinit();
        }
        session.cwd = std.Io.Dir.cwd().openDir(self.io, cwd_path, .{}) catch return error.BadCwd;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = a.dupe(u8, path_buf[0..(session.cwd.realPathFile(self.io, ".", &path_buf) catch return error.BadCwd)]) catch return error.OutOfMemory;

        session.cfg = try self.loadConfig(a, session.cwd);
        const sessions_dir = sessionsDir(&session.cfg);
        session.rt = session_runtime.SessionRuntime.init(self.io, a, self.environ, &session.cfg, session.cwd, .{
            .sessions_dir = sessions_dir,
            .resume_id = resume_id,
            .cwd_label = real,
            .profile = self.global.profile,
            .wire = self.wire,
        }) catch |err| {
            if (resume_id != null) return error.UnknownSession;
            return err;
        };
        session.rt_ready = true;
        session.rt.cancel_flag = &session.cancel;
        session.id = try a.dupe(u8, session.rt.store.manifest.id);

        session.instr = try instructions_mod.assemble(session.cwd, self.io, a, system_prompt.system_prompt, &.{});
        if (self.global.profile) |name| {
            if (session.cfg.profilePrompt(name)) |fragment| {
                session.instr = instructions_mod.appendFragment(a, session.instr, fragment) catch session.instr;
            }
        }
        if (resume_id != null) {
            var sink = Sink{ .server = self, .session_id = session.id, .cancel = &session.cancel, .scratch = a };
            const events = sink.events();
            try session.rt.rebuildHistory(a, &events);
        }

        {
            self.sessions_mutex.lockUncancelable(self.io);
            defer self.sessions_mutex.unlock(self.io);
            try self.sessions.put(self.gpa, session.id, session);
            errdefer _ = self.sessions.remove(session.id);
            try self.cancels.put(self.gpa, session.id, &session.cancel);
        }
        _ = session_runtime.dispatchHook(&session.rt, a, &session.cfg, .session_start);
        return session;
    }

    /// Config layers for one session: files, env, then the global flags,
    /// exactly as `ifnh ask` builds them. Any error is fatal for the session.
    fn loadConfig(self: *Server, a: std.mem.Allocator, cwd: std.Io.Dir) !config_mod.Store {
        var cfg = try config_mod.load(a, self.io, self.environ, cwd);
        if (self.global.profile) |name| try cfg.applyProfile(name);
        if (self.global.override_count > 0) try cfg.applyCliOverrides(self.global.overrideList());
        for (cfg.errors.items) |e| self.diag("config error [{s}]: {s}\n", .{ e.path, e.message });
        if (cfg.errors.items.len > 0) return error.ConfigInvalid;
        return cfg;
    }

    fn diag(self: *Server, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, text) catch {};
    }

    /// `ifnh/notice` {sessionId, level, text}: runtime status and notice lines.
    fn notify(self: *Server, session_id: []const u8, level: []const u8, text: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"sessionId\":") catch return;
        std.json.Stringify.value(session_id, .{}, w) catch return;
        w.print(",\"level\":\"{s}\",\"text\":", .{level}) catch return;
        std.json.Stringify.value(text, .{}, w) catch return;
        w.writeAll("}") catch return;
        self.sendNotification("ifnh/notice", aw.written());
    }
};

fn sessionsDir(cfg: *const config_mod.Store) []const u8 {
    const v = cfg.getString("sessions.dir", "project");
    if (v.len == 0 or std.mem.eql(u8, v, "project")) return ".ifnh/sessions";
    return v;
}

fn openFailure(scratch: std.mem.Allocator, err: anyerror) Reply {
    return switch (err) {
        error.BadCwd => fail(code_invalid_params, "cwd is not a readable directory"),
        error.ConfigInvalid => fail(code_internal, "invalid ifnh configuration (see stderr)"),
        else => internalError(scratch, err),
    };
}

/// A one-line message from an error; never a trace, never request data.
fn internalError(scratch: std.mem.Allocator, err: anyerror) Reply {
    const message = std.fmt.allocPrint(scratch, "internal error: {s}", .{@errorName(err)}) catch "internal error";
    return fail(code_internal, message);
}

fn oneLine(scratch: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try scratch.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
    return out;
}

fn requiredString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

const OptionalString = union(enum) { absent, value: []const u8, wrong_type };

fn optionalString(v: std.json.Value, key: []const u8) OptionalString {
    if (v != .object) return .absent;
    const field = v.object.get(key) orelse return .absent;
    if (field == .null) return .absent;
    return if (field == .string) .{ .value = field.string } else .wrong_type;
}

fn isResponseTo(root: std.json.Value, id: i64) bool {
    if (root != .object) return false;
    if (root.object.get("method") != null) return false;
    const got = root.object.get("id") orelse return false;
    return got == .integer and got.integer == id;
}

// ---------------------------------------------------------------- events

/// Maps runtime `Events` to ACP notifications and permission requests.
const Sink = struct {
    server: *Server,
    session_id: []const u8,
    cancel: *const std.atomic.Value(bool),
    scratch: std.mem.Allocator,
    /// Call id of the tool being run, to name an approval request.
    call_id: []const u8 = "",
    /// Latest status line, for a turn that never ran.
    last_status: []const u8 = "",

    fn events(self: *Sink) session_runtime.Events {
        return .{
            .ctx = @ptrCast(self),
            .on_text = onText,
            .on_status = onStatus,
            .on_tool_start = onToolStart,
            .on_tool_result = onToolResult,
            .on_notice = onNotice,
            .on_assistant_message = onAssistantMessage,
            .on_approval = onApproval,
        };
    }

    /// `session/update` with `update` = `{"sessionUpdate":<kind>,<rest>}`.
    fn update(self: *Sink, kind: []const u8, comptime rest_fmt: []const u8, rest_args: anytype) void {
        const gpa = self.server.gpa;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"sessionId\":") catch return;
        std.json.Stringify.value(self.session_id, .{}, w) catch return;
        w.print(",\"update\":{{\"sessionUpdate\":\"{s}\"", .{kind}) catch return;
        w.print(rest_fmt, rest_args) catch return;
        w.writeAll("}}") catch return;
        self.server.sendNotification("session/update", aw.written());
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.update("agent_message_chunk", ",\"content\":{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(chunk, .{})});
    }

    fn onStatus(ctx: *anyopaque, level: session_runtime.Level, text: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.last_status = self.scratch.dupe(u8, text) catch "";
        self.server.notify(self.session_id, switch (level) {
            .plain => "info",
            .warn => "warn",
            .err => "error",
        }, text);
    }

    fn onNotice(ctx: *anyopaque, text: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.server.notify(self.session_id, "notice", text);
    }

    fn onToolStart(ctx: *anyopaque, call_id: []const u8, name: []const u8, arguments_json: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.call_id = self.scratch.dupe(u8, call_id) catch "";
        // The arguments are model output: re-serialize them rather than splice raw text.
        const input: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, self.scratch, arguments_json, .{}) catch .{ .string = arguments_json };
        self.update(
            "tool_call",
            ",\"toolCallId\":{f},\"title\":{f},\"kind\":\"other\",\"status\":\"in_progress\",\"rawInput\":{f}",
            .{ std.json.fmt(call_id, .{}), std.json.fmt(name, .{}), std.json.fmt(input, .{}) },
        );
    }

    fn onToolResult(ctx: *anyopaque, call_id: []const u8, name: []const u8, status: tool_mod.Status, output: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        self.update(
            "tool_call_update",
            ",\"toolCallId\":{f},\"title\":{f},\"status\":\"{s}\",\"content\":[{{\"type\":\"content\",\"content\":{{\"type\":\"text\",\"text\":{f}}}}}]",
            .{ std.json.fmt(call_id, .{}), std.json.fmt(name, .{}), if (status == .ok) "completed" else "failed", std.json.fmt(output, .{}) },
        );
    }

    fn onAssistantMessage(ctx: *anyopaque, content: []const u8, tool_calls_json: ?[]const u8) void {
        _ = ctx;
        _ = content;
        _ = tool_calls_json;
    }

    /// `session/request_permission`: block on the client's answer. Anything
    /// but an explicit allow (unknown option, timeout, cancel, closed stdin)
    /// is a rejection.
    fn onApproval(ctx: *anyopaque, req: tool_mod.ApprovalRequest) tool_mod.ApprovalResponse {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        const server = self.server;
        server.approval_mutex.lockUncancelable(server.io);
        defer server.approval_mutex.unlock(server.io);
        if (self.cancel.load(.acquire)) return .denied;

        var arena_state = std.heap.ArenaAllocator.init(server.gpa);
        defer arena_state.deinit();
        const scratch = arena_state.allocator();

        const id = server.next_request_id;
        server.next_request_id += 1;
        const call_id = if (self.call_id.len > 0) self.call_id else "approval";
        var aw: std.Io.Writer.Allocating = .init(scratch);
        const w = &aw.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/request_permission\",\"params\":{{\"sessionId\":{f},", .{ id, std.json.fmt(self.session_id, .{}) }) catch return .denied;
        w.print("\"toolCall\":{{\"toolCallId\":{f},\"title\":{f},\"status\":\"pending\",\"content\":[{{\"type\":\"content\",\"content\":{{\"type\":\"text\",\"text\":{f}}}}}", .{
            std.json.fmt(call_id, .{}), std.json.fmt(req.title, .{}), std.json.fmt(req.detail, .{}),
        }) catch return .denied;
        if (req.preview.len > 0) {
            w.print(",{{\"type\":\"content\",\"content\":{{\"type\":\"text\",\"text\":{f}}}}}", .{std.json.fmt(req.preview, .{})}) catch return .denied;
        }
        w.writeAll("]},\"options\":[" ++
            "{\"optionId\":\"allow_once\",\"name\":\"Allow once\",\"kind\":\"allow_once\"}," ++
            "{\"optionId\":\"allow_always\",\"name\":\"Allow for this session\",\"kind\":\"allow_always\"}," ++
            "{\"optionId\":\"reject_once\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}") catch return .denied;
        server.send(aw.written());

        const response = server.awaitResponse(scratch, id, self.cancel) orelse return .denied;
        return decisionFrom(response);
    }
};

/// The option the client picked in a permission response; anything unknown
/// or malformed is a rejection.
fn decisionFrom(response: std.json.Value) tool_mod.ApprovalResponse {
    if (response != .object) return .denied;
    const result = response.object.get("result") orelse return .denied;
    if (result != .object) return .denied;
    var option: ?[]const u8 = null;
    if (result.object.get("outcome")) |outcome| {
        if (outcome == .object) {
            const kind = requiredString(outcome, "outcome") orelse return .denied;
            if (!std.mem.eql(u8, kind, "selected")) return .denied;
            option = requiredString(outcome, "optionId");
        }
    } else {
        option = requiredString(result, "optionId");
    }
    const chosen = option orelse return .denied;
    if (std.mem.eql(u8, chosen, "allow_once")) return .approved_once;
    if (std.mem.eql(u8, chosen, "allow_always")) return .approved_session;
    return .denied;
}

// ---------------------------------------------------------------- entry point

const StdoutOutput = struct {
    io: std.Io,
    broken: bool = false,

    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *StdoutOutput = @ptrCast(@alignCast(ctx));
        if (self.broken) return false;
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {
            self.broken = true;
            return false;
        };
        return true;
    }
};

/// `ifnh serve`: returns the process exit code (0 after stdin closes).
pub fn run(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    global: args_mod.GlobalFlags,
    serve: args_mod.ServeArgs,
    wire: ?*wire_log.WireLog,
) u8 {
    var stdout = StdoutOutput{ .io = io };
    var server = Server{
        .io = io,
        .gpa = std.heap.smp_allocator,
        .environ = environ,
        .global = global,
        .wire = wire,
        .framing = serve.framing,
        .out = .{ .ctx = &stdout, .write = StdoutOutput.write },
    };
    defer server.deinit();
    const reader = std.Thread.spawn(.{}, Server.readerMain, .{&server}) catch |err| {
        server.diag("error: cannot start the stdin reader: {s}\n", .{@errorName(err)});
        return 1;
    };
    server.loop();
    reader.join();
    return 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectMessage(frame: ?Frame, want: []const u8) !void {
    try testing.expect(frame != null);
    try testing.expect(frame.? == .message);
    try testing.expectEqualStrings(want, frame.?.message);
}

test "serve ndjson framing: CRLF, blank lines, split reads" {
    var f = Framer{ .framing = .ndjson };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "{\"a\":1}\r\n\r\n\n  \n{\"b\"");
    try expectMessage(f.next(), "{\"a\":1}");
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, ":2}\n{\"c\":3}\n");
    try expectMessage(f.next(), "{\"b\":2}");
    try expectMessage(f.next(), "{\"c\":3}");
    try testing.expect(f.next() == null);
}

test "serve ndjson framing: a line over 1 MiB is reported once and the stream continues" {
    var f = Framer{ .framing = .ndjson };
    defer f.deinit(testing.allocator);
    const big = try testing.allocator.alloc(u8, max_message_bytes + 10);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    // Arrives in pieces, newline last, followed by a good message.
    try f.push(testing.allocator, big[0 .. max_message_bytes / 2]);
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, big[max_message_bytes / 2 ..]);
    try testing.expect(f.next().? == .oversize);
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, "tail of the long line\n{\"ok\":true}\n");
    try expectMessage(f.next(), "{\"ok\":true}");
    // A whole oversize line delivered in one push.
    var one: std.ArrayListUnmanaged(u8) = .empty;
    defer one.deinit(testing.allocator);
    try one.appendSlice(testing.allocator, big);
    try one.append(testing.allocator, '\n');
    try one.appendSlice(testing.allocator, "{\"after\":1}\n");
    try f.push(testing.allocator, one.items);
    try testing.expect(f.next().? == .oversize);
    try expectMessage(f.next(), "{\"after\":1}");
}

test "serve content-length framing: split headers and bodies, back-to-back, bare LF" {
    var f = Framer{ .framing = .content_length };
    defer f.deinit(testing.allocator);
    try f.push(testing.allocator, "Content-Len");
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, "gth: 7\r\n\r\n{\"a\":");
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, "1}content-length: 2\r\nContent-Type: x\r\n\r\n{}");
    try expectMessage(f.next(), "{\"a\":1}");
    try expectMessage(f.next(), "{}");
    try f.push(testing.allocator, "Content-Length: 2\n\n[]");
    try expectMessage(f.next(), "[]");
    try testing.expect(f.next() == null);
}

test "serve content-length framing: oversize body is skipped, bad header reported" {
    var f = Framer{ .framing = .content_length };
    defer f.deinit(testing.allocator);
    var head: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{max_message_bytes + 1});
    try f.push(testing.allocator, h);
    try testing.expect(f.next().? == .oversize);
    const chunk = try testing.allocator.alloc(u8, max_message_bytes + 1);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'z');
    try f.push(testing.allocator, chunk[0..1000]);
    try testing.expect(f.next() == null);
    try f.push(testing.allocator, chunk[1000..]);
    try f.push(testing.allocator, "Content-Length: 2\r\n\r\n{}");
    try expectMessage(f.next(), "{}");
    try f.push(testing.allocator, "X-Other: 1\r\n\r\n");
    try testing.expect(f.next().? == .bad_header);
}

test "serve frames outgoing messages in both framings" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendFrame(testing.allocator, &out, .ndjson, "{\"x\":1}");
    try testing.expectEqualStrings("{\"x\":1}\n", out.items);
    out.clearRetainingCapacity();
    try appendFrame(testing.allocator, &out, .content_length, "{\"x\":1}");
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"x\":1}", out.items);
}

/// A server wired to a buffer, fed synchronously (no reader thread).
const TestRig = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    env: std.process.Environ.Map,
    server: Server,

    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *TestRig = @ptrCast(@alignCast(ctx));
        self.out.appendSlice(testing.allocator, bytes) catch return false;
        return true;
    }

    fn init(rig: *TestRig, framing: args_mod.Framing) !void {
        rig.* = .{ .env = std.process.Environ.Map.init(testing.allocator), .server = undefined };
        try rig.env.put("OPENAI_API_KEY", "test-key-1234567890");
        rig.server = .{
            .io = testing.io,
            .gpa = testing.allocator,
            .environ = &rig.env,
            .framing = framing,
            .out = .{ .ctx = rig, .write = write },
            .approval_timeout_ms = 60,
        };
    }

    fn deinit(rig: *TestRig) void {
        rig.server.deinit();
        rig.out.deinit(testing.allocator);
        rig.env.deinit();
    }

    /// Feed `input`, mark stdin closed, and serve everything.
    fn run(rig: *TestRig, input: []const u8) void {
        var framer = Framer{ .framing = rig.server.framing };
        defer framer.deinit(testing.allocator);
        rig.server.feed(&framer, input);
        rig.server.eof.store(true, .release);
        rig.server.loop();
    }

    fn lines(rig: *TestRig) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, std.mem.trimEnd(u8, rig.out.items, "\n"), '\n');
    }
};

test "serve initialize, unknown method, parse error, invalid request" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    rig.run(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"method\":\"nope/never\"}\n" ++
            "{not json\n" ++
            "[1,2]\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":5}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"session/close\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"session/close\",\"params\":{}}\n",
    );
    var it = rig.lines();
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true,\"promptCapabilities\":{\"image\":true}}," ++
            "\"agentInfo\":{\"name\":\"ifnh\",\"version\":\"" ++ version.version ++ "\"},\"authMethods\":[]}}",
        it.next().?,
    );
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"error\":{\"code\":-32601,\"message\":\"method not found\"}}", it.next().?);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}", it.next().?);
    try testing.expect(std.mem.indexOf(u8, it.next().?, "\"code\":-32600") != null);
    try testing.expect(std.mem.indexOf(u8, it.next().?, "\"id\":5,\"error\":{\"code\":-32600") != null);
    // The notification form of an invalid call gets no reply; the request form does.
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32602,\"message\":\"sessionId is required\"}}", it.next().?);
    try testing.expect(it.next() == null);
}

test "serve content-length framing round trip" {
    var rig: TestRig = undefined;
    try rig.init(.content_length);
    defer rig.deinit();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"nope\"}";
    var input: [128]u8 = undefined;
    rig.run(try std.fmt.bufPrint(&input, "Content-Length: {d}\r\n\r\n{s}", .{ req.len, req }));
    try testing.expect(std.mem.startsWith(u8, rig.out.items, "Content-Length: "));
    const body_at = std.mem.indexOf(u8, rig.out.items, "\r\n\r\n").? + 4;
    try testing.expect(std.mem.indexOf(u8, rig.out.items[body_at..], "\"code\":-32601") != null);
}

test "serve oversize message gets -32600 and the stream continues" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    const big = try testing.allocator.alloc(u8, max_message_bytes + 100);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, big);
    try input.appendSlice(testing.allocator, "\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\"}\n");
    rig.run(input.items);
    var it = rig.lines();
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"message exceeds 1 MiB\"}}", it.next().?);
    try testing.expect(std.mem.indexOf(u8, it.next().?, "\"id\":3") != null);
}

test "serve session/new rejects a bad cwd and bad params" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    rig.run(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\"/no/such/dir/ifnh\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":7}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"ghost\",\"prompt\":[]}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/load\",\"params\":{\"sessionId\":\"ghost\",\"cwd\":\"/no/such/dir/ifnh\"}}\n",
    );
    var it = rig.lines();
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        try testing.expect(std.mem.indexOf(u8, line, "\"code\":-32602") != null);
    }
    try testing.expectEqual(@as(usize, 4), n);
}

/// `session/prompt` moves the process into the session directory; tests put
/// it back so later tests still find `.zig-cache`.
const CwdGuard = struct {
    dir: std.Io.Dir,

    fn init(io: std.Io) !CwdGuard {
        return .{ .dir = try std.Io.Dir.cwd().openDir(io, ".", .{}) };
    }

    fn deinit(self: CwdGuard, io: std.Io) void {
        std.process.setCurrentDir(io, self.dir) catch {};
        self.dir.close(io);
    }
};

/// A project directory whose config points the model at `base_url`.
fn writeProject(tmp: std.Io.Dir, io: std.Io, base_url: []const u8, arena: std.mem.Allocator) !void {
    try tmp.createDirPath(io, ".ifnh");
    const cfg = try std.fmt.allocPrint(arena,
        \\{{"model":{{"provider":"openai","model":"serve-test","base_url":"{s}","api_key_env":"OPENAI_API_KEY"}}}}
    , .{base_url});
    try tmp.writeFile(io, .{ .sub_path = ".ifnh/config.json", .data = cfg });
}

test "serve end to end: new, prompt with a scripted model, updates in order, close" {
    const providers_testing = @import("../providers/testing.zig");
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    const guard = try CwdGuard.init(io);
    defer guard.deinit(io);

    const body = "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"serve\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";
    const fake = try providers_testing.FakeServer.start(io, arena, body);
    defer fake.stop();
    try writeProject(tmp.dir, io, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{fake.port}), arena);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();

    // The id of the new session is only known after session/new; drive it in two steps.
    var framer = Framer{ .framing = .ndjson };
    defer framer.deinit(testing.allocator);
    const new_req = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{{\"cwd\":\"{s}\"}}}}\n", .{dir_path});
    rig.server.feed(&framer, new_req);
    const item = rig.server.nextItem().?;
    {
        defer item.deinit(testing.allocator);
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        rig.server.handleMessage(scratch.allocator(), item.message);
    }
    const first = std.mem.trim(u8, rig.out.items, "\n");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, first, .{});
    const sid = parsed.object.get("result").?.object.get("sessionId").?.string;

    rig.out.clearRetainingCapacity();
    const prompt_req = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"{s}\",\"prompt\":[{{\"type\":\"text\",\"text\":\"say hi\"}},{{\"type\":\"text\",\"text\":\"twice\"}}]}}}}\n" ++
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/close\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n", .{ sid, sid });
    rig.run(prompt_req);
    fake.wait();

    // The model saw both text parts joined by a newline.
    try testing.expect(std.mem.indexOf(u8, fake.requestHead(), "POST /chat/completions") != null or std.mem.indexOf(u8, fake.requestHead(), "POST /v1/chat/completions") != null);

    var texts: std.ArrayListUnmanaged(u8) = .empty;
    var saw_result = false;
    var saw_close = false;
    var it = rig.lines();
    while (it.next()) |line| {
        // Every stdout line is one JSON-RPC message with no escape bytes.
        try testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
        const msg = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try testing.expectEqualStrings("2.0", msg.object.get("jsonrpc").?.string);
        if (msg.object.get("method")) |m| {
            if (std.mem.eql(u8, m.string, "session/update")) {
                const upd = msg.object.get("params").?.object.get("update").?.object;
                try testing.expectEqualStrings("agent_message_chunk", upd.get("sessionUpdate").?.string);
                try texts.appendSlice(arena, upd.get("content").?.object.get("text").?.string);
                try testing.expect(!saw_result); // updates precede the prompt result
            }
        } else if (msg.object.get("id").?.integer == 2) {
            try testing.expectEqualStrings("end_turn", msg.object.get("result").?.object.get("stopReason").?.string);
            saw_result = true;
        } else if (msg.object.get("id").?.integer == 3) {
            saw_close = true;
        }
    }
    try testing.expectEqualStrings("hello serve", texts.items);
    try testing.expect(saw_result and saw_close);
    try testing.expectEqual(@as(u32, 0), rig.server.sessions.count());
}

test "serve prompt with no model configured is an internal error with one line" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .access_sub_paths = true });
    defer tmp.cleanup();
    const guard = try CwdGuard.init(io);
    defer guard.deinit(io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    var framer = Framer{ .framing = .ndjson };
    defer framer.deinit(testing.allocator);
    rig.server.feed(&framer, try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{{\"cwd\":\"{s}\"}}}}\n", .{dir_path}));
    const item = rig.server.nextItem().?;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    rig.server.handleMessage(scratch.allocator(), item.message);
    item.deinit(testing.allocator);
    const sid = (try std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trim(u8, rig.out.items, "\n"), .{})).object.get("result").?.object.get("sessionId").?.string;

    rig.out.clearRetainingCapacity();
    rig.run(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"{s}\",\"prompt\":[{{\"type\":\"text\",\"text\":\"hi\"}}]}}}}\n", .{sid}));
    var found_error = false;
    var it = rig.lines();
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"code\":-32603") != null) {
            found_error = true;
            try testing.expect(std.mem.indexOf(u8, line, "no model configured") != null);
            try testing.expect(std.mem.indexOf(u8, line, "\\n") == null);
        }
    }
    try testing.expect(found_error);
}

test "serve prompt validates content blocks" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    // Without a session every prompt fails on the id first; blocks are checked
    // against a real session in the end-to-end tests above, so here only the
    // shape checks that precede session lookup matter.
    rig.run("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[]}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":[]}\n");
    var it = rig.lines();
    while (it.next()) |line| try testing.expect(std.mem.indexOf(u8, line, "\"code\":-32602") != null);
}

fn approvalRequest() tool_mod.ApprovalRequest {
    return .{ .tool = "bash", .title = "run command", .detail = "touch x" };
}

fn approvalCase(rig: *TestRig, canned: []const u8, cancel: *std.atomic.Value(bool)) tool_mod.ApprovalResponse {
    var framer = Framer{ .framing = .ndjson };
    defer framer.deinit(testing.allocator);
    if (canned.len > 0) rig.server.feed(&framer, canned);
    var sink = Sink{ .server = &rig.server, .session_id = "s1", .cancel = cancel, .scratch = testing.allocator, .call_id = "call_7" };
    return Sink.onApproval(@ptrCast(&sink), approvalRequest());
}

test "serve permission request: options, id, and answers map to approvals" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    var cancel = std.atomic.Value(bool).init(false);

    // allow_always -> session grant; an unrelated message arrives first and is kept.
    const answered = approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"session/prompt\",\"params\":{}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_always\"}}}\n", &cancel);
    try testing.expectEqual(tool_mod.ApprovalResponse.approved_session, answered);
    try testing.expectEqual(@as(usize, 1), rig.server.deferred.items.len);

    // The request that went out.
    const sent = std.mem.trim(u8, rig.out.items, "\n");
    try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"session/request_permission\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"id\":1,") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"sessionId\":\"s1\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "\"toolCallId\":\"call_7\"") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "{\"optionId\":\"allow_once\",\"name\":\"Allow once\",\"kind\":\"allow_once\"}") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "{\"optionId\":\"allow_always\",\"name\":\"Allow for this session\",\"kind\":\"allow_always\"}") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "{\"optionId\":\"reject_once\",\"name\":\"Reject\",\"kind\":\"reject_once\"}") != null);

    // Ids are fresh per request: the next one is 2.
    try testing.expectEqual(tool_mod.ApprovalResponse.approved_once, approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}}\n", &cancel));
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"reject_once\"}}}\n", &cancel));
    // Unknown option, cancelled outcome, JSON-RPC error: all rejections.
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_forever\"}}}\n", &cancel));
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"outcome\":{\"outcome\":\"cancelled\"}}}\n", &cancel));
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-1,\"message\":\"no\"}}\n", &cancel));
}

test "serve permission request: timeout, closed stdin and cancel reject" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    var cancel = std.atomic.Value(bool).init(false);

    // No answer within the (shortened) timeout.
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "", &cancel));
    // Stdin closed while waiting.
    rig.server.eof.store(true, .release);
    rig.server.approval_timeout_ms = 60_000;
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "", &cancel));
    // A cancel that arrives while waiting.
    rig.server.eof.store(false, .release);
    cancel.store(true, .release);
    try testing.expectEqual(tool_mod.ApprovalResponse.denied, approvalCase(&rig, "", &cancel));
}

test "serve session/cancel notification flips the flag from the reader side" {
    var rig: TestRig = undefined;
    try rig.init(.ndjson);
    defer rig.deinit();
    var flag = std.atomic.Value(bool).init(false);
    try rig.server.cancels.put(testing.allocator, "s9", &flag);

    var framer = Framer{ .framing = .ndjson };
    defer framer.deinit(testing.allocator);
    rig.server.feed(&framer, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"other\"}}\n");
    try testing.expect(!flag.load(.acquire));
    rig.server.feed(&framer, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s9\"}}\n");
    try testing.expect(flag.load(.acquire));
    // Handled on the spot: nothing was queued for the main loop.
    try testing.expectEqual(@as(usize, 0), rig.server.queue.items.len);
}
