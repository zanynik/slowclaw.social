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
const llama = if (have_mtmd) local_inference.llama else struct {};

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
    ContextCreateFailed,
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

    const ctx = mtmd.mtmd_init_from_file(path_z.ptr, @ptrCast(text_model), params) orelse return error.MmprojLoadFailed;

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
/// Mirrors upstream mtmd-helper's eval flow (the same one llama-server uses):
///   1. wrap the PCM in an audio bitmap
///   2. mtmd_tokenize a prompt that contains the projector's media marker
///      (the marker count MUST equal the bitmap count, else tokenize fails)
///   3. walk the chunks in order, tracking n_past:
///        text chunk  → llama_decode its tokens into the KV cache
///        audio chunk → mtmd_encode_chunk, then llama_decode the resulting
///                      embeddings (llama_batch.embd, explicit positions,
///                      non-causal attention when the projector asks for it)
///   4. run the generation loop off the tail of the shared context
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

    // The prompt MUST contain the projector's media marker exactly once per
    // bitmap — without <__media__>, mtmd_tokenize fails with "number of
    // bitmaps does not match number of markers" (this was the empty-result
    // root cause). The instruction is wrapped in Gemma's turn markers so the
    // model answers as if asked in chat (parse_special turns them into real
    // special tokens; harmless literal text for other families).
    const marker_z = std.mem.span(@as([*:0]const u8, @ptrCast(mtmd.mtmd_get_marker(mctx))));
    const prompt = std.fmt.allocPrint(
        allocator,
        "<start_of_turn>user\n{s}\nTranscribe this audio faithfully. Output only the spoken text.<end_of_turn>\n<start_of_turn>model\n",
        .{marker_z},
    ) catch return error.OutOfMemory;
    defer allocator.free(prompt);

    const input_text = mtmd.mtmd_input_text{
        .text = @ptrCast(prompt.ptr),
        .text_len = prompt.len,
        .add_special = true, // prepend BOS (Gemma needs it)
        .parse_special = true, // parse <start_of_turn>/<end_of_turn>/marker
    };
    const bitmaps = [_]?*const mtmd.mtmd_bitmap{bitmap};
    const chunks = mtmd.mtmd_input_chunks_init() orelse return error.OutOfMemory;
    defer mtmd.mtmd_input_chunks_free(chunks);

    const tok_ok = mtmd.mtmd_tokenize(mctx, chunks, &input_text, @constCast(&bitmaps), bitmaps.len);
    if (tok_ok != 0) return error.TokenizationFailed;

    // ── Size the context from the REAL token count ───────────────────────
    // Audio chunks contribute embeddings (not discrete tokens), so the KV
    // cache must hold text tokens + every audio embedding + generation
    // headroom. Count per-chunk tokens, and remember the largest media chunk
    // (its embeddings are decoded in one llama_batch, in ≤n_batch slices).
    const n_chunks = mtmd.mtmd_input_chunks_size(chunks);
    var max_media_tokens: usize = 0;
    var total_tokens: usize = 0;
    var ci: usize = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        const n_tok = mtmd.mtmd_input_chunk_get_n_tokens(chunk);
        total_tokens += n_tok;
        if (mtmd.mtmd_input_chunk_get_type(chunk) != mtmd.MTMD_INPUT_CHUNK_TYPE_TEXT) {
            if (n_tok > max_media_tokens) max_media_tokens = n_tok;
        }
    }
    if (total_tokens == 0) return error.InferenceFailed;

    // Context sizing. Audio eats tokens fast (~25/s), so the audio path uses
    // a larger iOS ceiling than local_inference's text-only 2048. If the
    // recording still doesn't fit, trailing audio chunks are skipped (the
    // leading speech transcribes; SpeechAnalyzer handles marathon journals).
    const max_ctx: u32 = if (builtin.os.tag == .ios) 4096 else 8192;
    const gen_headroom: u32 = @min(max_tokens, max_ctx / 2);
    const n_batch: u32 = if (builtin.os.tag == .ios) 128 else 512;
    const prompt_budget: usize = max_ctx - gen_headroom - 8;

    // First pass: decide which chunks fit. Text chunks always fit (tiny);
    // audio chunks are added while budget allows.
    var planned: usize = 0;
    var audio_fits = try allocator.alloc(bool, n_chunks);
    defer allocator.free(audio_fits);
    ci = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        const n_tok = mtmd.mtmd_input_chunk_get_n_tokens(chunk);
        const is_media = mtmd.mtmd_input_chunk_get_type(chunk) != mtmd.MTMD_INPUT_CHUNK_TYPE_TEXT;
        audio_fits[ci] = !is_media or (planned + n_tok <= prompt_budget);
        if (audio_fits[ci]) planned += n_tok;
    }
    if (max_media_tokens > 0 and planned == 0) return error.InferenceFailed;

    timings.load_ms = nowMs() - load_start;
    const encode_start = nowMs();

    const vocab = llama.llama_model_get_vocab(text_model);
    const n_mmproj_embd: usize = @intCast(llama.llama_model_n_embd_inp(text_model));
    const use_mrope = mtmd.mtmd_decode_use_mrope(mctx);
    const n_pos_per_embd: usize = if (use_mrope) 4 else 1;

    var cparams = llama.llama_context_default_params();
    cparams.n_ctx = @min(@as(u32, @intCast(planned)) + gen_headroom + 8, max_ctx);
    cparams.n_batch = n_batch;
    const ctx = llama.llama_init_from_model(text_model, cparams) orelse return error.ContextCreateFailed;
    defer llama.llama_free(ctx);

    // Scratch buffers for hand-built batches (text uses ≤n_batch tokens).
    const batch_cap: usize = @intCast(n_batch);
    var tok_buf: [512]llama.llama_token = undefined;
    var pos_buf: [512]llama.llama_pos = undefined;
    var nseq_buf: [512]c_int = undefined;
    var logits_buf: [512]i8 = undefined;
    var seq0 = [1]llama.llama_seq_id{0};
    var seqid_ptrs: [512]?[*]llama.llama_seq_id = undefined;
    for (0..batch_cap) |i| seqid_ptrs[i] = &seq0;

    // Media embedding positions are sized by the largest chunk (4 planes
    // when the projector uses M-RoPE, else 1). `media_pos_view` is a separate
    // scratch for repacked per-batch M-RoPE slices (never aliases storage).
    const media_pos = try allocator.alloc(llama.llama_pos, max_media_tokens * n_pos_per_embd + 1);
    defer allocator.free(media_pos);
    const media_pos_view = try allocator.alloc(llama.llama_pos, max_media_tokens * 4 + 1);
    defer allocator.free(media_pos_view);
    const media_nseq = try allocator.alloc(c_int, max_media_tokens + 1);
    defer allocator.free(media_nseq);
    const media_logits = try allocator.alloc(i8, max_media_tokens + 1);
    defer allocator.free(media_logits);
    const media_seqids = try allocator.alloc(?[*]llama.llama_seq_id, max_media_tokens + 1);
    defer allocator.free(media_seqids);
    for (0..max_media_tokens + 1) |i| media_seqids[i] = &seq0;

    // ── Encode + decode chunks in order (mtmd-helper eval pattern) ──────
    var n_past: llama.llama_pos = 0;
    ci = 0;
    while (ci < n_chunks) : (ci += 1) {
        const chunk = mtmd.mtmd_input_chunks_get(chunks, ci);
        const chunk_type = mtmd.mtmd_input_chunk_get_type(chunk);
        const is_last_chunk = (ci + 1 == n_chunks);
        if (!audio_fits[ci]) continue; // over budget — skip this media chunk

        if (chunk_type == mtmd.MTMD_INPUT_CHUNK_TYPE_TEXT) {
            var n_tok: usize = 0;
            const toks = mtmd.mtmd_input_chunk_get_tokens_text(chunk, &n_tok);
            const toks_slice: []const llama.llama_token = if (n_tok > 0 and toks != null)
                toks[0..n_tok]
            else
                &.{};
            var i: usize = 0;
            while (i < toks_slice.len) {
                var n: usize = 0;
                while (i < toks_slice.len and n < batch_cap) : (n += 1) {
                    tok_buf[n] = toks_slice[i];
                    pos_buf[n] = n_past;
                    n_past += 1;
                    nseq_buf[n] = 1;
                    logits_buf[n] = 0;
                    // The final prompt token must request logits so the
                    // sampler can read the first-step distribution.
                    if (is_last_chunk and i + 1 == toks_slice.len) logits_buf[n] = 1;
                    i += 1;
                }
                const batch = llama.llama_batch{
                    .n_tokens = @intCast(n),
                    .token = &tok_buf,
                    .embd = null,
                    .pos = &pos_buf,
                    .n_seq_id = &nseq_buf,
                    .seq_id = &seqid_ptrs,
                    .logits = &logits_buf,
                };
                if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
            }
        } else {
            // Audio chunk: encode (mel → audio encoder → projector), then
            // decode the resulting embeddings into the KV cache.
            if (mtmd.mtmd_encode_chunk(mctx, chunk) != 0) return error.EncodingFailed;
            const embd: [*]f32 = @ptrCast(mtmd.mtmd_get_output_embd(mctx) orelse return error.EncodingFailed);
            const n_tok = mtmd.mtmd_input_chunk_get_n_tokens(chunk);

            // Positions for the embeddings. Normal: pos_0 + i. M-RoPE 1D
            // (audio): the same value repeated across the 4 planes.
            if (use_mrope) {
                for (0..n_tok) |j| {
                    const p = n_past + @as(llama.llama_pos, @intCast(j));
                    media_pos[j] = p;
                    media_pos[n_tok + j] = p;
                    media_pos[2 * n_tok + j] = p;
                    media_pos[3 * n_tok + j] = p;
                }
            } else {
                for (0..n_tok) |j| media_pos[j] = n_past + @as(llama.llama_pos, @intCast(j));
            }
            for (0..n_tok) |j| {
                media_nseq[j] = 1;
                media_logits[j] = 0;
                if (is_last_chunk and j + 1 == n_tok) media_logits[j] = 1;
            }

            // Some projectors (Gemma family) want the media span attended
            // non-causally — honor whatever the projector asks for.
            const non_causal = mtmd.mtmd_decode_use_non_causal(mctx, chunk);
            if (non_causal) llama.llama_set_causal_attn(ctx, false);
            defer if (non_causal) llama.llama_set_causal_attn(ctx, true);

            var off2: usize = 0;
            while (off2 < n_tok) {
                const len: usize = @min(batch_cap, n_tok - off2);
                const batch = llama.llama_batch{
                    .n_tokens = @intCast(len),
                    .token = null,
                    .embd = embd + off2 * n_mmproj_embd,
                    .pos = if (use_mrope)
                        repackMropePos(media_pos_view, media_pos, n_tok, off2, len)
                    else
                        media_pos[off2..].ptr,
                    .n_seq_id = media_nseq[off2..].ptr,
                    .seq_id = media_seqids[off2..].ptr,
                    .logits = media_logits[off2..].ptr,
                };
                if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
                off2 += len;
            }
            n_past += mtmd.mtmd_input_chunk_get_n_pos(chunk);
        }
    }
    timings.encode_ms = nowMs() - encode_start;

    // ── Generation loop (mirrors local_inference.generate) ──────────────
    const decode_start = nowMs();

    // Sampler chain: temp → dist (mirrors local_inference.generate).
    const seed: u32 = @truncate(@as(u64, @bitCast(c_stdlib.time(null))) *% 2654435761 +% @intFromPtr(text_model));
    const smpl = llama.llama_sampler_chain_init(llama.llama_sampler_chain_default_params()) orelse return error.InferenceFailed;
    defer llama.llama_sampler_free(smpl);
    llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_temp(temperature));
    llama.llama_sampler_chain_add(smpl, llama.llama_sampler_init_dist(seed));

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var piece_buf: [128]u8 = undefined;
    const max_gen: u32 = @min(max_tokens, gen_headroom);

    var gen_i: u32 = 0;
    while (gen_i < max_gen) : (gen_i += 1) {
        const new_token = llama.llama_sampler_sample(smpl, ctx, -1);
        llama.llama_sampler_accept(smpl, new_token);

        if (llama.llama_vocab_is_eog(vocab, new_token)) break;
        if (n_past + 1 >= cparams.n_ctx) break; // context_full

        const piece_len = llama.llama_token_to_piece(vocab, new_token, &piece_buf, piece_buf.len, 0, true);
        if (piece_len > 0) {
            out.appendSlice(allocator, piece_buf[0..@intCast(piece_len)]) catch return error.OutOfMemory;
        }

        var tok_arr = [1]llama.llama_token{new_token};
        var one_pos = [1]llama.llama_pos{n_past};
        var one_nseq = [1]c_int{1};
        // logits=1 (not NULL): llama_sampler_sample below reads the logits
        // of this freshly-decoded token. An explicit all-zero array would
        // store NO outputs and the next sample would abort (llama_batch_get_one
        // leaves logits NULL, meaning "output last token" — the hand-built
        // batch must ask for it explicitly).
        var one_logits = [1]i8{1};
        const batch = llama.llama_batch{
            .n_tokens = 1,
            .token = &tok_arr,
            .embd = null,
            .pos = &one_pos,
            .n_seq_id = &one_nseq,
            .seq_id = &seqid_ptrs, // seqid_ptrs[0] == &seq0
            .logits = &one_logits,
        };
        if (llama.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
        n_past += 1;
    }

    timings.decode_ms = nowMs() - decode_start;
    timings.total_ms = nowMs() - total_start;

    const cleaned = std.mem.trim(u8, out.items, " \n\r\t");
    return allocator.dupe(u8, cleaned) catch error.OutOfMemory;
}

/// M-RoPE (1D audio) positions are stored planar — [t…][y…][x…][z…] — so a
/// batch view starting at `offset` must be repacked plane-by-plane into
/// `view`. Mirrors decode_embd_batch::get_view from upstream
/// mtmd-helper-common.h. Returns the packed slice's pointer.
fn repackMropePos(view: []llama.llama_pos, pos: []const llama.llama_pos, n_tok_total: usize, offset: usize, len: usize) [*]llama.llama_pos {
    var w: usize = 0;
    for (0..4) |plane| {
        const src = plane * n_tok_total + offset;
        for (0..len) |j| {
            view[w] = pos[src + j];
            w += 1;
        }
    }
    return view.ptr;
}

fn nowMs() i64 {
    // Zig 0.16 moved std.time behind the Io interface; at the FFI boundary libc
    // is linked, so use clock_gettime (CLOCK_MONOTONIC) for timing deltas —
    // monotonic, unaffected by wall-clock changes. Matches local_inference's
    // libc-at-the-boundary approach. Falls back to time() * 1000 on error.
    var ts: c_stdlib.timespec = undefined;
    if (c_stdlib.clock_gettime(c_stdlib.CLOCK_MONOTONIC, &ts) == 0) {
        return @as(i64, @intCast(ts.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.tv_nsec)), 1_000_000);
    }
    return @as(i64, @intCast(c_stdlib.time(null))) * 1000;
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
