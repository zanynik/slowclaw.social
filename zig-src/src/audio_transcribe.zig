//! On-device audio transcription via llama.cpp's mtmd (multimodal) C API.
//!
//! Pairs with local_inference.zig (the text-LLM engine). The text model
//! (Gemma) is loaded there; this module loads the matching multimodal
//! projector (mmproj) that teaches the same model to ingest audio, then
//! turns raw PCM F32 samples into a transcript string.
//!
//! Architecture: the text model is the single source of truth (owned by
//! local_inference.g_model). mtmd attaches an audio encoder + projector on
//! top of it via mtmd_init_from_file(mmproj, text_model, params). The
//! transcript flow:
//!   1. mtmd_bitmap_init_from_audio(pcm_f32, n_samples)
//!   2. mtmd_tokenize(text_prompt + audio_bitmap) → input_chunks
//!   3. iterate chunks: text → collect tokens; audio → mtmd_batch_encode
//!      produces embeddings → feed through llama_decode
//!   4. run the generation loop (sampler → token → piece) reusing the same
//!      pattern as local_inference.generate
//!
//! Like local_inference, this module compiles in two modes via the
//! `with_llama` build option:
//!   - true  (shipped staticlib): real mtmd bindings.
//!   - false (all unit-test steps): stub that reports unavailable, so
//!     `zig build test*` stays fast and C++-free.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const local_inference = @import("local_inference.zig");

/// True when the vendored llama.cpp + mtmd backend is compiled in.
pub const have_mtmd = build_options.with_llama;

// Only analyzed when have_mtmd is true (comptime-lazy), so the stub build
// never references mtmd/llama symbols or headers.
const mtmd = if (have_mtmd) @cImport({
    @cInclude("mtmd.h");
}) else struct {};
const llama = if (have_mtmd) local_inference.llama_symbols else struct {};

const c_stdlib = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});
const c_getenv = c_stdlib.getenv;

pub const AudioError = error{
    MmprojNotLoaded,
    MmprojLoadFailed,
    AudioNotSupported,
    NoTextModel,
    TokenizationFailed,
    EncodingFailed,
    InferenceFailed,
    OutOfMemory,
};

/// Per-transcription timing (milliseconds). The locked-phone experiment
/// reads these to determine whether the process got CPU time while the
/// screen was locked.
pub const AudioTimings = struct {
    load_ms: i64 = 0,
    encode_ms: i64 = 0,
    decode_ms: i64 = 0,
    total_ms: i64 = 0,
};

// ── Engine state ────────────────────────────────────────────────────────────
// The mmproj context is cached process-global (like local_inference.g_model)
// so repeated transcriptions don't reload the projector. It's tied to the
// currently-loaded text model: if the text model is unloaded, the mmproj
// must be unloaded too (unloadMmproj is called from the FFI when the text
// model is unloaded/reloaded).

var g_mtmd_ctx: ?*anyopaque = null;
var g_mtmd_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

fn lockEngine() void {
    if (!have_mtmd) return;
    _ = std.c.pthread_mutex_lock(&g_mtmd_mutex);
}

fn unlockEngine() void {
    if (!have_mtmd) return;
    _ = std.c.pthread_mutex_unlock(&g_mtmd_mutex);
}

fn loadedMtmd() ?*mtmd.mtmd_context {
    if (!have_mtmd) return null;
    const c = g_mtmd_ctx orelse return null;
    return @ptrCast(@alignCast(c));
}

/// Load the multimodal projector (mmproj GGUF) against the currently-loaded
/// text model. The text model MUST be loaded first (via local_inference.load).
/// Safe to call repeatedly; unloads any previously-loaded projector first.
pub fn loadMmproj(mmproj_path: []const u8) AudioError!void {
    if (!have_mtmd) return error.MmprojLoadFailed;

    lockEngine();
    defer unlockEngine();

    // The text model must already be in memory — mtmd attaches to it.
    const text_model = local_inference.loadedModelPtr() orelse return error.NoTextModel;

    const path_z = std.heap.c_allocator.dupeZ(u8, mmproj_path) catch return error.OutOfMemory;
    defer std.heap.c_allocator.free(path_z);

    // Pre-check: readable, sane size, GGUF magic (same guard as local_inference).
    local_inference.checkGgufFile(path_z) catch return error.MmprojLoadFailed;

    // Drop any previously-loaded projector before loading the new one.
    unloadMmprojLocked();

    var params = mtmd.mtmd_context_params_default();
    params.use_gpu = false; // CPU: matches local_inference (n_gpu_layers=0)
    params.print_timings = false;
    params.n_threads = 4; // conservative for iOS; avoids saturating under RAM pressure

    const ctx = mtmd.mtmd_init_from_file(path_z.ptr, text_model, params) orelse return error.MmprojLoadFailed;

    // Verify the projector actually supports audio input.
    if (!mtmd.mtmd_support_audio(ctx)) {
        mtmd.mtmd_free(ctx);
        return error.AudioNotSupported;
    }

    g_mtmd_ctx = ctx;
}

/// Unload the projector. No-op when nothing is loaded.
pub fn unloadMmproj() void {
    lockEngine();
    defer unlockEngine();
    unloadMmprojLocked();
}

fn unloadMmprojLocked() void {
    if (!have_mtmd) return;
    if (g_mtmd_ctx) |c| {
        const ctx: *mtmd.mtmd_context = @ptrCast(@alignCast(c));
        mtmd.mtmd_free(ctx);
        g_mtmd_ctx = null;
    }
}

/// True when an audio-capable mmproj is loaded.
pub fn isLoaded() bool {
    lockEngine();
    defer unlockEngine();
    return g_mtmd_ctx != null;
}

/// The audio sample rate the loaded projector expects (e.g. 16000 for Gemma).
/// Returns 0 when no projector is loaded. Swift resamples the recording to
/// this rate before calling transcribe.
pub fn audioSampleRate() i32 {
    if (!have_mtmd) return 0;
    lockEngine();
    defer unlockEngine();
    const ctx = loadedMtmd() orelse return 0;
    return @intCast(mtmd.mtmd_get_audio_sample_rate(ctx));
}

/// Status snapshot for the FFI layer (Swift renders the audio engine card).
pub fn statusJson(allocator: std.mem.Allocator) ![]u8 {
    lockEngine();
    defer unlockEngine();
    if (!have_mtmd) {
        return allocator.dupe(u8, "{\"available\":false,\"supported\":false,\"sampleRate\":0,\"reason\":\"mtmd backend not linked\"}");
    }
    if (g_mtmd_ctx != null) {
        const ctx = loadedMtmd().?;
        const sr: i32 = @intCast(mtmd.mtmd_get_audio_sample_rate(ctx));
        return std.fmt.allocPrint(allocator, "{{\"available\":true,\"supported\":true,\"sampleRate\":{d},\"reason\":null}}", .{sr});
    }
    return allocator.dupe(u8, "{\"available\":true,\"supported\":false,\"sampleRate\":0,\"reason\":\"No audio mmproj loaded. Download a Gemma audio mmproj to enable on-device transcription.\"}");
}

// ── Transcription ───────────────────────────────────────────────────────────

/// Transcribe mono PCM F32 samples into text.
///
/// `pcm` is raw 32-bit float samples at the rate returned by audioSampleRate()
/// (typically 16000 Hz). The caller (Swift) is responsible for decoding +
/// resampling the audio file to this format before calling.
///
/// Returns the transcript string (allocator-owned) and fills `timings`.
pub fn transcribe(
    allocator: std.mem.Allocator,
    pcm: []const f32,
    max_tokens: u32,
    temperature: f32,
    timings: *AudioTimings,
) AudioError![]u8 {
    if (!have_mtmd) return error.InferenceFailed;

    const total_start = nowMs();

    // ── Validate engine state ────────────────────────────────────────────
    const text_model = local_inference.loadedModelPtr() orelse return error.NoTextModel;
    const mctx = loadedMtmd() orelse return error.MmprojNotLoaded;
    if (pcm.len == 0) return error.InferenceFailed;

    lockEngine();
    defer unlockEngine();

    // ── Build the audio bitmap + tokenize ────────────────────────────────
    const load_start = nowMs();
    const bitmap = mtmd.mtmd_bitmap_init_from_audio(pcm.len, pcm.ptr) orelse return error.OutOfMemory;
    defer mtmd.mtmd_bitmap_free(bitmap);

    // The instruction text that steers the model toward transcription.
    // Gemma-audio responds to a natural-language instruction; this asks for
    // a faithful transcript (no translation, no commentary).
    const instruction = "Transcribe this audio faithfully. Output only the spoken text.";
    const input_text = mtmd.mtmd_input_text{
        .text = instruction.ptr,
        .text_len = instruction.len,
        .add_special = true,
        .parse_special = true,
    };
    const bitmaps = [_]?*const mtmd.mtmd_bitmap{bitmap};
    const chunks = mtmd.mtmd_input_chunks_init() orelse return error.OutOfMemory;
    defer mtmd.mtmd_input_chunks_free(chunks);

    const tok_ok = mtmd.mtmd_tokenize(mctx, chunks, &input_text, @ptrCast(&bitmaps), bitmaps.len);
    if (tok_ok != 0) return error.TokenizationFailed;

    timings.load_ms = nowMs() - load_start;

    // ── Encode media chunks + collect all tokens for the prompt decode ───
    const encode_start = nowMs();

    // Walk the tokenized chunks. Text chunks yield token arrays directly;
    // audio chunks must be encoded (mel → embeddings) then fed as embeddings.
    const n_chunks = mtmd.mtmd_input_chunks_size(chunks);
    var n_prompt: usize = 0;

    // First pass: count total prompt tokens so we can allocate once.
    var ci: usize = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        n_prompt += mtmd.mtmd_input_chunk_get_n_tokens(chunk);
    }

    // We can't pre-build a flat token array because audio chunks contribute
    // embeddings (not discrete tokens) via llama_decode on the encoder output.
    // The mtmd batch API handles this: add all media chunks to a batch, encode
    // once, then mtmd feeds the results into the context's KV cache itself.
    //
    // For Gemma-audio the flow (per upstream) is:
    //   - text chunks → their tokens go into the prompt batch directly
    //   - audio chunks → mtmd_batch_encode produces embeddings, then
    //     llama_decode on those embeddings slots them into the KV cache
    //
    // The simplest correct path mirrors llama-server's audio handling: build
    // a llama_batch, add text tokens, and let mtmd_encode_chunk handle media.
    // mtmd_encode_chunk "text chunk will be ignored silently, only media chunk
    // will be encoded" — so we iterate chunks and encode each media one.

    ci = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        const chunk_type = mtmd.mtmd_input_chunk_get_type(chunk);
        if (chunk_type == mtmd.MTMD_INPUT_CHUNK_TYPE_AUDIO) {
            // Encode this audio chunk: runs the audio encoder + projector,
            // producing embeddings that the LLM cross-attends to.
            const enc_ok = mtmd.mtmd_encode_chunk(mctx, chunk);
            if (enc_ok != 0) return error.EncodingFailed;
        }
    }
    timings.encode_ms = nowMs() - encode_start;

    // ── Decode the prompt tokens + run generation ───────────────────────
    const decode_start = nowMs();

    // Build the prompt token list from text chunks only (audio embeddings
    // were slot into the model's internal state by mtmd_encode_chunk).
    var prompt_tokens = std.ArrayList(llama.llama_token).empty;
    defer prompt_tokens.deinit(allocator);
    try prompt_tokens.ensureTotalCapacity(allocator, n_prompt);

    ci = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        const chunk_type = mtmd.mtmd_input_chunk_get_type(chunk);
        if (chunk_type == mtmd.MTMD_INPUT_CHUNK_TYPE_TEXT) {
            var n_tok: usize = 0;
            const toks = mtmd.mtmd_input_chunk_get_tokens_text(chunk, &n_tok);
            if (n_tok > 0) try prompt_tokens.appendSlice(allocator, toks[0..n_tok]);
        }
    }

    const vocab = llama.llama_model_get_vocab(text_model);

    // Context sizing — same conservative iOS caps as local_inference.
    const max_ctx: u32 = if (builtin.os.tag == .ios) 2048 else 4096;
    const gen_headroom: u32 = @min(max_tokens, max_ctx / 2);
    const n_batch: u32 = if (builtin.os.tag == .ios) 128 else 512;

    var cparams = llama.llama_context_default_params();
    cparams.n_ctx = @min(@as(u32, @intCast(prompt_tokens.items.len)) + gen_headroom + 8, max_ctx);
    cparams.n_batch = n_batch;
    const ctx = llama.llama_init_from_model(text_model, cparams) orelse return error.ContextCreateFailed;
    defer llama.llama_free(ctx);

    // Decode the prompt tokens in ≤n_batch chunks (same guard as local_inference).
    var off: usize = 0;
    while (off < prompt_tokens.items.len) {
        const chunk_len: i32 = @intCast(@min(n_batch, prompt_tokens.items.len - off));
        const batch = llama.llama_batch_get_one(prompt_tokens.items.ptr + off, chunk_len);
        if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
        off += @intCast(chunk_len);
    }

    // Sampler chain: temp → dist (mirrors local_inference.generate).
    const seed: u32 = @truncate(@as(u64, @bitCast(c_stdlib.time(null))) *% 2654435761 +% @intFromPtr(text_model));
    const smpl = llama.llama_sampler_chain_init(llama.llama_sampler_chain_default_params()) orelse return error.InferenceFailed;
    defer llama.llama_sampler_free(smpl);
    llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_temp(temperature));
    llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_dist(seed));

    // Generation loop (mirrors local_inference.generate).
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var piece_buf: [128]u8 = undefined;
    var n_cur: u32 = @intCast(prompt_tokens.items.len);
    const max_gen: u32 = @min(max_tokens, gen_headroom);

    var gen_i: u32 = 0;
    while (gen_i < max_gen) : (gen_i += 1) {
        const new_token = llama.llama_sampler_sample(smpl, ctx, -1);
        llama.llama_sampler_accept(smpl, new_token);

        if (llama.llama_vocab_is_eog(vocab, new_token)) break;
        if (n_cur + 1 >= cparams.n_ctx) break; // context_full

        const piece_len = llama.llama_token_to_piece(vocab, new_token, &piece_buf, piece_buf.len, 0, true);
        if (piece_len > 0) {
            try out.appendSlice(allocator, piece_buf[0..@intCast(piece_len)]);
        }

        var tok_arr = [1]llama.llama_token{new_token};
        const batch = llama.llama_batch_get_one(&tok_arr, 1);
        if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
        n_cur += 1;
    }

    timings.decode_ms = nowMs() - decode_start;
    timings.total_ms = nowMs() - total_start;

    const cleaned = std.mem.trim(u8, out.items, " \n\r\t");
    return allocator.dupe(u8, cleaned) catch error.OutOfMemory;
}

fn nowMs() i64 {
    // std.time.milliTimestamp is portable (no libc) and monotonic enough for
    // timing deltas; the locked-phone experiment reads deltas, not absolute time.
    return std.time.milliTimestamp();
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "audio_transcribe: statusJson reports unavailable in stub mode" {
    const json = try statusJson(testing.allocator);
    defer testing.allocator.free(json);
    if (have_mtmd) {
        try testing.expect(std.mem.indexOf(u8, json, "\"available\":true") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, json, "\"available\":false") != null);
    }
}

test "audio_transcribe: isLoaded false before any load" {
    try testing.expect(!isLoaded());
}

test "audio_transcribe: audioSampleRate 0 when not loaded" {
    try testing.expectEqual(@as(i32, 0), audioSampleRate());
}

test "audio_transcribe: loadMmproj fails in stub mode" {
    if (!have_mtmd) {
        try testing.expectError(error.MmprojLoadFailed, loadMmproj("/nonexistent.mmproj.gguf"));
    }
}

test "audio_transcribe: transcribe fails when no projector loaded" {
    if (!have_mtmd) {
        var timings = AudioTimings{};
        const pcm = [_]f32{ 0.0, 0.1, 0.2 };
        try testing.expectError(error.InferenceFailed, transcribe(testing.allocator, &pcm, 64, 0.0, &timings));
    }
}
