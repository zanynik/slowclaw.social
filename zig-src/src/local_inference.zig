//! On-device LLM inference via llama.cpp C API.
//!
//! Ports `web/src-tauri/src/inference.rs` (which used the `llama-cpp-2` Rust
//! crate) to Zig, binding llama.cpp's C API directly — no Rust crate, no
//! async runtime. The vendored llama.cpp (b10201) is compiled into
//! `libllama.a` by build.zig (CPU backend; Metal/CUDA intentionally not
//! vendored — the Tauri app defaulted to CPU on iOS because TestFlight
//! devices hit uncatchable Metal allocator crashes).
//!
//! The module compiles in two modes via the `with_llama` build option:
//!   - true  (default for the shipped staticlib): real llama.cpp bindings.
//!   - false (all unit-test steps): stub that reports ModelNotLoaded, so
//!     `zig build test*` stays fast and C++-free. Behavior matches the
//!     pre-llama builds: the FFI reports on-device AI as unavailable.
//!
//! Architecture: satisfies the Provider vtable from provider.zig — so the
//! same journal_agent calls (synthesizeJournal, extractInterests, draftPost)
//! work whether the backend is the OpenAI HTTP provider or on-device
//! llama.cpp.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const provider = @import("provider.zig");

/// True when the vendored llama.cpp backend is compiled into this module.
pub const have_llama = build_options.with_llama;

// Only analyzed when have_llama is true (comptime-lazy), so the stub build
// never references llama symbols or headers. Public so audio_transcribe.zig
// can share the same declarations (DRY — both modules bind llama.h).
pub const llama = if (have_llama) @cImport({
    @cInclude("llama.h");
}) else struct {};

// libc stdio for the load() pre-checks (readable file, size, GGUF magic).
// Zig 0.16 moved std.fs behind the Io interface; at the FFI boundary plain
// stdio is simpler and this module is only ever exercised with libc linked.
const c_stdio = @cImport({
    @cInclude("stdio.h");
});

const c_stdlib = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});
const c_getenv = c_stdlib.getenv;

pub const InferenceError = error{
    ModelNotLoaded,
    ModelLoadFailed,
    ContextCreateFailed,
    TokenizationFailed,
    InferenceFailed,
    OutOfMemory,
};

// ── Engine state (llama.cpp handles; opaque so the stub build typechecks) ──

var g_backend_init: bool = false;
var g_model: ?*anyopaque = null;
var g_model_id: []u8 = &.{};

// Raw pthread mutex: the 0.16 std.Io.Mutex needs an Io interface we don't
// have at the FFI boundary, and this module must also compile libc-free
// (the `test` step) — pthread symbols are only referenced from have_llama
// code paths, which the libc-free test build never emits.
var g_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

fn lockEngine() void {
    if (!have_llama) return;
    _ = std.c.pthread_mutex_lock(&g_mutex);
}

fn unlockEngine() void {
    if (!have_llama) return;
    _ = std.c.pthread_mutex_unlock(&g_mutex);
}

fn ensureBackendInit() void {
    if (have_llama) {
        if (!g_backend_init) {
            llama.llama_backend_init();
            g_backend_init = true;
        }
    }
}

fn loadedModel() ?*llama.llama_model {
    if (!have_llama) return null;
    const m = g_model orelse return null;
    return @ptrCast(@alignCast(m));
}

/// Public accessor for the currently-loaded text model pointer, so
/// audio_transcribe.zig can attach an mtmd projector to it. Returns null
/// when no model is loaded (or the backend is compiled out). Borrowed —
/// the caller must not free it; lifetime is owned by this module.
pub fn loadedModelPtr() ?*llama.llama_model {
    return loadedModel();
}

/// On-device LLM inference engine. Wraps llama.cpp's C API.
/// On iOS the model file lives in the app's Documents directory
/// (downloaded by Swift from the curated preset catalog).
pub const LocalInference = struct {
    model_path: []const u8,
    is_loaded: bool = false,

    pub fn init(model_path: []const u8) LocalInference {
        return .{ .model_path = model_path };
    }

    /// Load the GGUF model file. Must be called before inference.
    /// Mirrors the Rust load_model: validates the file (exists, >1 KiB,
    /// "GGUF" magic) before handing it to llama.cpp, and loads with
    /// mmap enabled + n_gpu_layers=0 (CPU — the stable iOS path).
    pub fn load(self: *LocalInference) InferenceError!void {
        if (have_llama) {
            lockEngine();
            defer unlockEngine();

            // Pre-checks (ported from inference.rs): readable, sane size,
            // GGUF magic — llama.cpp's own errors for a truncated download
            // are far less actionable than failing fast here.
            const path_z = std.heap.c_allocator.dupeZ(u8, self.model_path) catch return error.OutOfMemory;
            defer std.heap.c_allocator.free(path_z);
            checkGgufFile(path_z) catch return error.ModelLoadFailed;

            ensureBackendInit();

            var params = llama.llama_model_default_params();
            params.n_gpu_layers = 0; // CPU: the stable default from inference.rs
            // Keep pages file-backed under iOS RAM pressure (use_mmap=true
            // in inference.rs; b10201 moved this to the load_mode enum).
            params.load_mode = llama.LLAMA_LOAD_MODE_MMAP;

            // Drop any previously loaded model before loading the new one.
            unloadLocked();

            const model = llama.llama_model_load_from_file(path_z.ptr, params) orelse return error.ModelLoadFailed;
            g_model = model;

            // Model id drives the chat-template fallback family detection.
            // Prefer GGUF general.name, then general.basename, then the file
            // name — same role model_id plays in inference.rs.
            g_model_id = readModelId(model, self.model_path);

            self.is_loaded = true;
            return;
        } else {
            // Stub mode: keep the pre-llama behavior (file-exists check only).
            const path_z = std.heap.c_allocator.dupeZ(u8, self.model_path) catch return error.OutOfMemory;
            defer std.heap.c_allocator.free(path_z);
            const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return error.ModelLoadFailed;
            _ = c_stdio.fclose(fp);
            self.is_loaded = true;
        }
    }

    /// Unload the model and free its memory.
    pub fn unload(self: *LocalInference) void {
        if (have_llama) {
            lockEngine();
            defer unlockEngine();
            unloadLocked();
        }
        self.is_loaded = false;
    }

    fn unloadLocked() void {
        if (!have_llama) return;
        if (g_model) |m| {
            const model: *llama.llama_model = @ptrCast(@alignCast(m));
            llama.llama_model_free(model);
            g_model = null;
        }
        if (g_model_id.len > 0) {
            std.heap.c_allocator.free(g_model_id);
            g_model_id = &.{};
        }
    }

    fn readModelId(model: *llama.llama_model, path: []const u8) []u8 {
        if (!have_llama) return &.{};
        var buf: [256]u8 = undefined;
        for ([_][]const u8{ "general.name", "general.basename" }) |key| {
            var key_buf: [64]u8 = undefined;
            const key_z = std.fmt.bufPrintZ(&key_buf, "{s}", .{key}) catch continue;
            const n = llama.llama_model_meta_val_str(model, key_z.ptr, &buf, buf.len);
            if (n > 0) {
                const len: usize = @intCast(@min(n, buf.len - 1));
                return std.heap.c_allocator.dupe(u8, buf[0..len]) catch &.{};
            }
        }
        const base = std.fs.path.basename(path);
        return std.heap.c_allocator.dupe(u8, base) catch &.{};
    }

    /// Generate a chat response. Applies the model's embedded chat template
    /// (falling back to a family-specific manual format, ported from
    /// inference.rs), tokenizes, decodes, and samples. Satisfies the
    /// Provider vtable.
    pub fn chatWithSystem(
        self: *LocalInference,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) provider.ProviderError![]u8 {
        _ = model; // the model is already loaded via load()
        return self.generate(allocator, system_prompt, message, 512, @floatCast(temperature)) catch |err| switch (err) {
            error.ModelNotLoaded => error.InvalidArgument,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ApiError,
        };
    }

    /// Core inference call — ported from inference.rs run_inference:
    /// chat template → tokenize → context sizing + truncation → batched
    /// prompt decode → temp/dist sampler loop → detokenize + cleanup.
    pub fn generate(
        self: *LocalInference,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        max_tokens: u32,
        temperature: f32,
    ) InferenceError![]u8 {
        if (!self.is_loaded) return error.ModelNotLoaded;
        if (!have_llama) return error.InferenceFailed;

        lockEngine();
        defer unlockEngine();

        const model = loadedModel() orelse return error.ModelNotLoaded;
        const vocab = llama.llama_model_get_vocab(model);

        // ── Prompt: embedded chat template, else family fallback ────────
        const prompt = buildChatPrompt(allocator, model, system_prompt, message) catch return error.OutOfMemory;
        defer allocator.free(prompt);

        // ── Tokenize (two-pass: probe size, then fill) ──────────────────
        var n_tokens = llama.llama_tokenize(vocab, prompt.ptr, @intCast(prompt.len), null, 0, true, true);
        if (n_tokens == std.math.minInt(i32)) return error.TokenizationFailed;
        if (n_tokens < 0) n_tokens = -n_tokens;
        var tokens = allocator.alloc(llama.llama_token, @intCast(n_tokens)) catch return error.OutOfMemory;
        defer allocator.free(tokens);
        const got = llama.llama_tokenize(vocab, prompt.ptr, @intCast(prompt.len), tokens.ptr, n_tokens, true, true);
        if (got < 0) return error.TokenizationFailed;
        var n_prompt: usize = @intCast(got);

        // ── Context sizing & prompt truncation (from inference.rs) ──────
        // iOS has limited RAM; cap the KV-cache to a safe ceiling. The
        // context must fit prompt + generation headroom. Over-long prompts
        // keep the first 80% and last 20% so the model sees both the
        // instruction and the tail of the content.
        const max_ctx: u32 = if (builtin.os.tag == .ios) 1536 else 4096;
        const gen_headroom: u32 = @min(max_tokens, max_ctx / 2);
        const max_prompt_tokens: usize = max_ctx - gen_headroom - 8;
        var truncated: []llama.llama_token = tokens;
        if (n_prompt > max_prompt_tokens) {
            const keep_start = max_prompt_tokens * 4 / 5;
            const keep_end = max_prompt_tokens - keep_start;
            const buf = allocator.alloc(llama.llama_token, max_prompt_tokens) catch return error.OutOfMemory;
            @memcpy(buf[0..keep_start], tokens[0..keep_start]);
            @memcpy(buf[keep_start..], tokens[n_prompt - keep_end ..]);
            truncated = buf;
            n_prompt = max_prompt_tokens;
        }
        defer if (truncated.ptr != tokens.ptr) allocator.free(truncated);

        const n_ctx: u32 = @min(@as(u32, @intCast(n_prompt)) + gen_headroom + 8, max_ctx);
        const n_batch: u32 = if (builtin.os.tag == .ios) 128 else 512;

        var cparams = llama.llama_context_default_params();
        cparams.n_ctx = n_ctx;
        cparams.n_batch = n_batch;
        const ctx = llama.llama_init_from_model(model, cparams) orelse return error.ContextCreateFailed;
        defer llama.llama_free(ctx);

        // ── Decode the prompt in chunks no larger than n_batch ──────────
        // (Decoding the whole prompt in one oversized batch can abort
        // inside llama_decode instead of returning an error — inference.rs)
        var off: usize = 0;
        while (off < n_prompt) {
            const chunk_len: i32 = @intCast(@min(n_batch, n_prompt - off));
            const batch = llama.llama_batch_get_one(truncated.ptr + off, chunk_len);
            if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
            off += @intCast(chunk_len);
        }

        // ── Sampler chain: temp → dist (mirrors chain_simple) ───────────
        const seed: u32 = @truncate(@as(u64, @bitCast(c_stdlib.time(null))) *% 2654435761 +% @intFromPtr(model));
        const smpl = llama.llama_sampler_chain_init(llama.llama_sampler_chain_default_params()) orelse return error.InferenceFailed;
        defer llama.llama_sampler_free(smpl);
        llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_temp(temperature));
        llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_dist(seed));

        // ── Generation loop ─────────────────────────────────────────────
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var piece_buf: [128]u8 = undefined;
        var n_cur: u32 = @intCast(n_prompt);
        const max_gen: u32 = @min(max_tokens, gen_headroom);

        var gen_i: u32 = 0;
        while (gen_i < max_gen) : (gen_i += 1) {
            const new_token = llama.llama_sampler_sample(smpl, ctx, -1);
            llama.llama_sampler_accept(smpl, new_token);

            if (llama.llama_vocab_is_eog(vocab, new_token)) break;
            if (n_cur + 1 >= n_ctx) break; // context_full

            const piece_len = llama.llama_token_to_piece(vocab, new_token, &piece_buf, piece_buf.len, 0, true);
            if (piece_len > 0) {
                out.appendSlice(allocator, piece_buf[0..@intCast(piece_len)]) catch return error.OutOfMemory;
            }

            var tok_arr = [1]llama.llama_token{new_token};
            const batch = llama.llama_batch_get_one(&tok_arr, 1);
            if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
            n_cur += 1;
        }

        // Trim chat-template end markers that slipped through as text.
        const cleaned = std.mem.trim(u8, out.items, " \n\r\t");
        for ([_][]const u8{ "<|im_end|>", "<|endoftext|>", "<end_of_turn>", "<turn|>" }) |marker| {
            if (std.mem.endsWith(u8, cleaned, marker)) {
                return allocator.dupe(u8, std.mem.trim(u8, cleaned[0 .. cleaned.len - marker.len], " \n\r\t")) catch return error.OutOfMemory;
            }
        }
        return allocator.dupe(u8, cleaned) catch return error.OutOfMemory;
    }

    /// Get a Provider vtable wrapping this instance.
    pub fn provider_(self: *LocalInference) provider.Provider {
        return .{
            .ctx = self,
            .name_fn = vtableName,
            .capabilities_fn = vtableCapabilities,
            .chat_with_system_fn = vtableChatWithSystem,
        };
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "local";
    }

    fn vtableCapabilities(_: *anyopaque) provider.ProviderCapabilities {
        return .{ .native_tool_calling = false, .vision = false };
    }

    fn vtableChatWithSystem(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) provider.ProviderError![]u8 {
        const self: *LocalInference = @ptrCast(@alignCast(ctx));
        return self.chatWithSystem(allocator, system_prompt, message, model, temperature);
    }
};

/// Readable, >1 KiB, "GGUF" magic — the three pre-checks from
/// inference.rs load_model. `path_z` must be null-terminated.
/// Public so audio_transcribe.zig can validate an mmproj GGUF the same way.
pub fn checkGgufFile(path_z: [:0]const u8) InferenceError!void {
    const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return error.ModelLoadFailed;
    defer _ = c_stdio.fclose(fp);
    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return error.ModelLoadFailed;
    const size = c_stdio.ftell(fp);
    if (size < 1024) return error.ModelLoadFailed;
    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_SET) != 0) return error.ModelLoadFailed;
    var magic: [4]u8 = undefined;
    if (c_stdio.fread(&magic, 1, 4, fp) != 4) return error.ModelLoadFailed;
    if (!std.mem.eql(u8, &magic, "GGUF")) return error.ModelLoadFailed;
}

// ── Chat prompt construction ────────────────────────────────────────────────

fn buildChatPrompt(
    allocator: std.mem.Allocator,
    model: *llama.llama_model,
    system_prompt: ?[]const u8,
    message: []const u8,
) ![]u8 {
    if (have_llama) {
        // Try the model's embedded chat template first (two-pass sizing).
        if (llama.llama_model_chat_template(model, null)) |tmpl| {
            var msgs: [2]llama.llama_chat_message = undefined;
            var n_msg: usize = 0;
            var sys_z: ?[:0]u8 = null;
            defer if (sys_z) |s| allocator.free(s);
            const msg_z = try allocator.dupeZ(u8, message);
            defer allocator.free(msg_z);
            if (system_prompt) |sys| {
                sys_z = try allocator.dupeZ(u8, sys);
                msgs[n_msg] = .{ .role = "system", .content = sys_z.?.ptr };
                n_msg += 1;
            }
            msgs[n_msg] = .{ .role = "user", .content = msg_z.ptr };
            n_msg += 1;

            var stack_buf: [2048]u8 = undefined;
            var n = llama.llama_chat_apply_template(tmpl, &msgs, n_msg, true, &stack_buf, stack_buf.len);
            if (n > 0 and n <= stack_buf.len) {
                return allocator.dupe(u8, stack_buf[0..@intCast(n)]);
            } else if (n > stack_buf.len) {
                const buf = try allocator.alloc(u8, @intCast(n));
                errdefer allocator.free(buf);
                n = llama.llama_chat_apply_template(tmpl, &msgs, n_msg, true, buf.ptr, @intCast(buf.len));
                if (n > 0 and n <= buf.len) return buf[0..@intCast(n)];
                allocator.free(buf);
            }
            // Embedded template failed (common with complex multimodal /
            // tool-calling Jinja) — fall through to the manual formats.
        }
        return buildFallbackPrompt(allocator, system_prompt, message, g_model_id);
    }
    return allocator.dupe(u8, message);
}

/// Manual chat formats keyed by model family, ported verbatim from
/// build_fallback_prompt in inference.rs. Used when the embedded Jinja
/// template is missing or fails in llama.cpp's template engine.
fn buildFallbackPrompt(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    model_id: []const u8,
) ![]u8 {
    var id_buf: [256]u8 = undefined;
    const id_len = @min(model_id.len, id_buf.len);
    const id_lower = std.ascii.lowerString(id_buf[0..id_len], model_id[0..id_len]);

    var prompt = std.ArrayList(u8).empty;
    errdefer prompt.deinit(allocator);
    if (std.mem.indexOf(u8, id_lower, "gemma-4") != null or std.mem.indexOf(u8, id_lower, "gemma4") != null) {
        // Gemma 4: <|turn>role / <turn|> (NOT Gemma 3's <start_of_turn>).
        if (system_prompt) |sys| {
            try prompt.print(allocator, "<|turn>system\n{s}\n<turn|>\n", .{sys});
        }
        try prompt.print(allocator, "<|turn>user\n{s}<turn|>\n<|turn>model\n", .{message});
    } else if (std.mem.indexOf(u8, id_lower, "gemma") != null) {
        // Gemma 2/3.
        if (system_prompt) |sys| {
            try prompt.print(allocator, "<start_of_turn>user\n{s}\n\n{s}<end_of_turn>\n", .{ sys, message });
        } else {
            try prompt.print(allocator, "<start_of_turn>user\n{s}<end_of_turn>\n", .{message});
        }
        try prompt.appendSlice(allocator, "<start_of_turn>model\n");
    } else if (std.mem.indexOf(u8, id_lower, "llama") != null) {
        // Llama 3.
        if (system_prompt) |sys| {
            try prompt.print(allocator, "<|start_header_id|>system<|end_header_id|>\n\n{s}<|eot_id|>", .{sys});
        }
        try prompt.print(allocator, "<|start_header_id|>user<|end_header_id|>\n\n{s}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n", .{message});
    } else {
        // ChatML fallback (Qwen, Mistral, generic).
        if (system_prompt) |sys| {
            try prompt.print(allocator, "<|im_start|>system\n{s}<|im_end|>\n", .{sys});
        }
        try prompt.print(allocator, "<|im_start|>user\n{s}<|im_end|>\n<|im_start|>assistant\n", .{message});
    }
    return prompt.toOwnedSlice(allocator);
}

/// Status snapshot for the FFI layer (Swift renders the On-Device AI card).
pub fn statusJson(allocator: std.mem.Allocator) ![]u8 {
    lockEngine();
    defer unlockEngine();
    if (!have_llama) {
        return allocator.dupe(u8, "{\"available\":false,\"loaded\":false,\"reason\":\"llama.cpp backend not linked\"}");
    }
    if (g_model != null) {
        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(allocator);
        for (g_model_id) |ch| {
            if (ch == '"' or ch == '\\') try escaped.append(allocator, '\\');
            try escaped.append(allocator, ch);
        }
        return std.fmt.allocPrint(allocator, "{{\"available\":true,\"loaded\":true,\"modelId\":\"{s}\",\"reason\":null}}", .{escaped.items});
    }
    return allocator.dupe(u8, "{\"available\":true,\"loaded\":false,\"reason\":\"No model loaded. Download a model to enable on-device AI.\"}");
}

/// Load a model into the shared engine (FFI entry).
pub fn loadModel(path: []const u8) InferenceError!void {
    var engine = LocalInference.init(path);
    try engine.load();
}

/// Unload the shared engine's model (FFI entry).
pub fn unloadModel() void {
    var engine = LocalInference.init("");
    engine.unload();
}

/// Run one chat completion on the shared engine (FFI entry).
pub fn chat(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    max_tokens: u32,
    temperature: f32,
) InferenceError![]u8 {
    var engine = LocalInference.init("");
    engine.is_loaded = isLoaded();
    return engine.generate(allocator, system_prompt, message, max_tokens, temperature);
}

/// True when a model is currently loaded (FFI entry for status checks).
pub fn isLoaded() bool {
    lockEngine();
    defer unlockEngine();
    return g_model != null;
}

/// The currently loaded model id (empty when none). Borrowed slice — do not free.
pub fn loadedModelId() []const u8 {
    return g_model_id;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "LocalInference: init sets model path" {
    const li = LocalInference.init("/path/to/model.gguf");
    try testing.expectEqualStrings("/path/to/model.gguf", li.model_path);
    try testing.expect(!li.is_loaded);
}

test "LocalInference: name is 'local'" {
    var li = LocalInference.init("/path/to/model.gguf");
    const p = li.provider_();
    try testing.expectEqualStrings("local", p.name());
}

test "LocalInference: capabilities (no tools, no vision)" {
    var li = LocalInference.init("/path/to/model.gguf");
    const p = li.provider_();
    const caps = p.capabilities();
    try testing.expect(!caps.native_tool_calling);
    try testing.expect(!caps.vision);
}

test "LocalInference: generate without load returns ModelNotLoaded" {
    var li = LocalInference.init("/nonexistent/path.gguf");
    try testing.expectError(error.ModelNotLoaded, li.generate(testing.allocator, null, "test", 100, 0.5));
}

test "LocalInference: chatWithSystem without load returns error" {
    var li = LocalInference.init("/nonexistent/path.gguf");
    try testing.expectError(error.InvalidArgument, li.chatWithSystem(testing.allocator, null, "hi", "local", 0.7));
}

test "LocalInference: load rejects a non-GGUF file" {
    if (!have_llama) return; // stub mode has no magic check
    // Write a non-GGUF file to the system temp dir via libc (markdown.zig's
    // tempWorkspace pattern — std.fs is behind the Io interface in 0.16).
    const tmp_root = blk: {
        if (c_getenv("TMPDIR")) |p2| break :blk std.mem.span(p2);
        if (c_getenv("TMP")) |p2| break :blk std.mem.span(p2);
        break :blk "/tmp";
    };
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/slowclaw-llm-test-{d}.gguf", .{ tmp_root, std.c.getpid() });
    defer testing.allocator.free(path);
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    const fp = c_stdio.fopen(path_z.ptr, "wb") orelse return error.SkipZigTest;
    const payload = "definitely not a gguf file, just enough padding to clear the 1 KiB size check " ** 20;
    _ = c_stdio.fwrite(payload.ptr, 1, payload.len, fp);
    _ = c_stdio.fclose(fp);
    defer _ = c_stdio.remove(path_z.ptr);

    var li = LocalInference.init(path);
    try testing.expectError(error.ModelLoadFailed, li.load());
}

test "local llm: load + chat (requires SLOWCLAW_TEST_GGUF)" {
    if (!have_llama) return error.SkipZigTest;
    if (have_llama) {
        const env = c_getenv("SLOWCLAW_TEST_GGUF") orelse return error.SkipZigTest;
        const path = std.mem.span(env);
        loadModel(path) catch |err| {
            std.debug.print("loadModel failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer unloadModel();
        try testing.expect(isLoaded());
        std.debug.print("loaded model id: {s}\n", .{loadedModelId()});

        const json = try statusJson(testing.allocator);
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"loaded\":true") != null);

        const reply = try chat(testing.allocator, "You are a terse assistant.", "Reply with exactly one word: hello", 16, 0.0);
        defer testing.allocator.free(reply);
        std.debug.print("local llm reply: {s}\n", .{reply});
        try testing.expect(reply.len > 0);
    }
}

test "statusJson reports unavailable in stub mode" {
    const json = try statusJson(testing.allocator);
    defer testing.allocator.free(json);
    if (have_llama) {
        try testing.expect(std.mem.indexOf(u8, json, "\"available\":true") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, json, "\"available\":false") != null);
    }
}
