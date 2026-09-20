//! Kev's merged Qwen2 backbone and trained pointer head; no text generation.
const std = @import("std");
const engine = @import("local_inference.zig");
const c = engine.llama;
const A = std.heap.c_allocator;
const E = engine.InferenceError;
const D = 896;
const P = 256;
const Question = struct { instruction: []const u8, options: []const []const u8 };
const Request = struct { state: []const u8, questions: []const Question };
const Token = struct { id: i32, pos: i32, branch: i32, output: bool = false, q: usize = 0, slot: usize = 0 };
const Handle = struct { model: *c.llama_model, meta: *c.gguf_context, qw: []const f32, qb: []const f32, kw: []const f32, kb: []const f32 };

fn array(meta: *c.gguf_context, key: [:0]const u8, count: usize) E![]const f32 {
    const i = c.gguf_find_key(meta, key);
    if (i < 0 or c.gguf_get_kv_type(meta, i) != c.GGUF_TYPE_ARRAY or c.gguf_get_arr_type(meta, i) != c.GGUF_TYPE_FLOAT32 or c.gguf_get_arr_n(meta, i) != count) return error.ModelLoadFailed;
    const ptr: [*]const f32 = @ptrCast(@alignCast(c.gguf_get_arr_data(meta, i) orelse return error.ModelLoadFailed));
    for (ptr[0..count]) |x| if (!std.math.isFinite(x)) return error.ModelLoadFailed;
    return ptr[0..count];
}
pub fn load(path: []const u8) E!*anyopaque {
    if (!engine.have_llama) return error.ModelNotLoaded;
    engine.lockEngine();
    defer engine.unlockEngine();
    const z = A.dupeZ(u8, path) catch return error.OutOfMemory;
    defer A.free(z);
    try engine.checkGgufFile(z);
    const meta = c.gguf_init_from_file(z, .{ .no_alloc = true, .ctx = null }) orelse return error.ModelLoadFailed;
    errdefer c.gguf_free(meta);
    const v = c.gguf_find_key(meta, "slowclaw.kev.version");
    if (v < 0 or c.gguf_get_kv_type(meta, v) != c.GGUF_TYPE_STRING or !std.mem.eql(u8, std.mem.span(c.gguf_get_val_str(meta, v)), "kev-0.5b-v1")) return error.ModelLoadFailed;
    const qw = try array(meta, "slowclaw.kev.q.weight", D * P);
    const qb = try array(meta, "slowclaw.kev.q.bias", P);
    const kw = try array(meta, "slowclaw.kev.k.weight", D * P);
    const kb = try array(meta, "slowclaw.kev.k.bias", P);
    engine.ensureBackendInit();
    var mp = c.llama_model_default_params();
    mp.n_gpu_layers = 0;
    mp.load_mode = c.LLAMA_LOAD_MODE_MMAP;
    const model = c.llama_model_load_from_file(z, mp) orelse return error.ModelLoadFailed;
    errdefer c.llama_model_free(model);
    if (c.llama_model_n_embd(model) != D) return error.ModelLoadFailed;
    const h = A.create(Handle) catch return error.OutOfMemory;
    h.* = .{ .model = model, .meta = meta, .qw = qw, .qb = qb, .kw = kw, .kb = kb };
    return @ptrCast(h);
}
pub fn free(raw: ?*anyopaque) void {
    if (!engine.have_llama) return;
    engine.lockEngine();
    defer engine.unlockEngine();
    if (raw) |r| {
        const h: *Handle = @ptrCast(@alignCast(r));
        c.llama_model_free(h.model);
        c.gguf_free(h.meta);
        A.destroy(h);
    }
}
fn append(vocab: ?*const c.llama_vocab, text: []const u8, special: bool, branch: i32, pos: *i32, tokens: *std.ArrayList(Token)) E!void {
    const count = c.llama_tokenize(vocab, text.ptr, @intCast(text.len), null, 0, false, special);
    if (count == std.math.minInt(i32)) return error.TokenizationFailed;
    const n: usize = @intCast(if (count < 0) -count else count);
    if (n + tokens.items.len > 4096) return error.ContextLimitExceeded;
    const ids = A.alloc(i32, n) catch return error.OutOfMemory;
    defer A.free(ids);
    if (c.llama_tokenize(vocab, text.ptr, @intCast(text.len), ids.ptr, @intCast(n), false, special) != n) return error.TokenizationFailed;
    for (ids) |id| {
        tokens.append(A, .{ .id = id, .pos = pos.*, .branch = branch }) catch return error.OutOfMemory;
        pos.* += 1;
    }
}
// Match upstream user_tokens: control spellings are rewritten as <¦name¦>.
fn user(vocab: ?*const c.llama_vocab, text: []const u8, branch: i32, pos: *i32, tokens: *std.ArrayList(Token)) E!void {
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(A);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "<|")) {
            var end = i + 2;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
            if (end > i + 2 and std.mem.startsWith(u8, text[end..], "|>")) {
                clean.appendSlice(A, "<¦") catch return error.OutOfMemory;
                clean.appendSlice(A, text[i + 2 .. end]) catch return error.OutOfMemory;
                clean.appendSlice(A, "¦>") catch return error.OutOfMemory;
                i = end + 2;
                continue;
            }
        }
        clean.append(A, text[i]) catch return error.OutOfMemory;
        i += 1;
    }
    try append(vocab, clean.items, false, branch, pos, tokens);
}
pub fn evaluate(raw: ?*anyopaque, json: []const u8, out: []f64) E!usize {
    if (!engine.have_llama) return error.ModelNotLoaded;
    const h: *Handle = @ptrCast(@alignCast(raw orelse return error.ModelNotLoaded));
    if (json.len == 0 or json.len > 64000) return error.ContextLimitExceeded;
    const parsed = std.json.parseFromSlice(Request, A, json, .{}) catch return error.InferenceFailed;
    defer parsed.deinit();
    const req = parsed.value;
    if (req.state.len == 0 or req.state.len > 12000 or req.questions.len == 0 or req.questions.len > 8) return error.ContextLimitExceeded;
    var total: usize = 0;
    for (req.questions) |q| {
        if (q.instruction.len == 0 or q.instruction.len > 10000 or q.options.len < 2 or q.options.len > 8) return error.ContextLimitExceeded;
        for (q.options) |o| if (o.len == 0 or o.len > 512) return error.ContextLimitExceeded;
        total += q.options.len;
    }
    if (out.len < total) return error.ContextLimitExceeded;
    engine.lockEngine();
    defer engine.unlockEngine();
    const vocab = c.llama_model_get_vocab(h.model);
    var tokens = std.ArrayList(Token).empty;
    defer tokens.deinit(A);
    var pos: i32 = 0;
    try append(vocab, "<|fim_prefix|>", true, -1, &pos, &tokens);
    try user(vocab, req.state, -1, &pos, &tokens);
    if (pos > 1536) return error.ContextLimitExceeded;
    const state_len = pos;
    for (req.questions, 0..) |q, qi| {
        pos = state_len;
        const branch: i32 = @intCast(qi);
        try append(vocab, "<|fim_middle|>", true, branch, &pos, &tokens);
        try user(vocab, q.instruction, branch, &pos, &tokens);
        for (q.options, 0..) |o, oi| {
            try append(vocab, "<|box_start|>", true, branch, &pos, &tokens);
            try user(vocab, o, branch, &pos, &tokens);
            try append(vocab, "<|box_end|>", true, branch, &pos, &tokens);
            var t = &tokens.items[tokens.items.len - 1];
            t.output = true;
            t.q = qi;
            t.slot = oi;
        }
        try append(vocab, "<|fim_suffix|>", true, branch, &pos, &tokens);
        var t = &tokens.items[tokens.items.len - 1];
        t.output = true;
        t.q = qi;
        t.slot = 8;
        if (pos > 2048) return error.ContextLimitExceeded;
    }
    var cp = c.llama_context_default_params();
    cp.n_ctx = 4096;
    cp.n_batch = 128;
    cp.n_ubatch = 128;
    cp.type_k = c.GGML_TYPE_F32;
    cp.type_v = c.GGML_TYPE_F32;
    cp.flash_attn_type = c.LLAMA_FLASH_ATTN_TYPE_DISABLED;
    cp.n_seq_max = 8;
    cp.kv_unified = true;
    cp.embeddings = true;
    cp.pooling_type = c.LLAMA_POOLING_TYPE_NONE;
    const ctx = c.llama_init_from_model(h.model, cp) orelse return error.ContextCreateFailed;
    defer c.llama_free(ctx);
    c.llama_set_n_threads(ctx, 2, 2);
    const hidden = A.alloc([9][D]f32, req.questions.len) catch return error.OutOfMemory;
    defer A.free(hidden);
    var batch = c.llama_batch_init(128, 0, 8);
    defer c.llama_batch_free(batch);
    var offset: usize = 0;
    while (offset < tokens.items.len) {
        const n = @min(128, tokens.items.len - offset);
        batch.n_tokens = @intCast(n);
        for (tokens.items[offset .. offset + n], 0..) |t, i| {
            batch.token[i] = t.id;
            batch.pos[i] = t.pos;
            batch.logits[i] = @intFromBool(t.output);
            if (t.branch < 0) {
                batch.n_seq_id[i] = @intCast(req.questions.len);
                for (0..req.questions.len) |q| batch.seq_id[i][q] = @intCast(q);
            } else {
                batch.n_seq_id[i] = 1;
                batch.seq_id[i][0] = t.branch;
            }
        }
        if (c.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
        for (tokens.items[offset .. offset + n], 0..) |t, i| {
            if (!t.output) continue;
            const ptr = c.llama_get_embeddings_ith(ctx, @intCast(i));
            if (ptr == null) return error.InferenceFailed;
            @memcpy(&hidden[t.q][t.slot], ptr[0..D]);
        }
        offset += n;
    }
    var cursor: usize = 0;
    for (req.questions, 0..) |q, qi| {
        var query: [P]f64 = undefined;
        for (0..P) |p| {
            query[p] = h.qb[p];
            for (0..D) |d| query[p] += @as(f64, h.qw[p * D + d]) * hidden[qi][8][d];
        }
        var logits: [8]f64 = undefined;
        for (q.options, 0..) |_, oi| {
            var dot: f64 = 0;
            for (0..P) |p| {
                var k: f64 = h.kb[p];
                for (0..D) |d| k += @as(f64, h.kw[p * D + d]) * hidden[qi][oi][d];
                dot += k * query[p];
            }
            logits[oi] = dot / 16;
        }
        try softmax(logits[0..q.options.len], out[cursor .. cursor + q.options.len]);
        cursor += q.options.len;
    }
    return total;
}
fn softmax(logits: []const f64, out: []f64) E!void {
    var maximum: f64 = -std.math.inf(f64);
    for (logits) |x| {
        if (!std.math.isFinite(x)) return error.InferenceFailed;
        maximum = @max(maximum, x);
    }
    var sum: f64 = 0;
    for (logits, 0..) |x, i| {
        out[i] = @exp(x - maximum);
        sum += out[i];
    }
    for (out) |*x| x.* /= sum;
}
test "Kev softmax is stable and rejects invalid input" {
    var out: [2]f64 = undefined;
    try softmax(&.{ 1000, 1000 }, &out);
    try std.testing.expectEqual(@as(f64, 0.5), out[0]);
    try std.testing.expectError(error.InferenceFailed, softmax(&.{ std.math.nan(f64), 0 }, &out));
}
