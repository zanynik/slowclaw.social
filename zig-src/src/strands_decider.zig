//! Strands Decider v21: merged Qwen3.5 torso and calibrated FP32 pointer head.
const std = @import("std");
const engine = @import("local_inference.zig");
const c = engine.llama;
const A = std.heap.c_allocator;
const E = engine.InferenceError;
const D = 2048;
const P = 256;
const Question = struct { instruction: []const u8, options: []const []const u8 };
const Request = struct { state: []const u8, questions: []const Question };
// Typed []u8 JSON parsing also accepts numeric arrays and instantiates f128
// integer conversion helpers unavailable on iOS. This protocol is strings only.
fn requestFromValue(value: std.json.Value, allocator: std.mem.Allocator) !Request {
    if (value != .object or value.object.count() != 2) return error.InvalidRequest;
    const state = value.object.get("state") orelse return error.InvalidRequest;
    const questions = value.object.get("questions") orelse return error.InvalidRequest;
    if (state != .string or questions != .array or questions.array.items.len == 0 or questions.array.items.len > 8) return error.InvalidRequest;
    const result = try allocator.alloc(Question, questions.array.items.len);
    for (questions.array.items, result) |question, *out| {
        if (question != .object or question.object.count() != 2) return error.InvalidRequest;
        const instruction = question.object.get("instruction") orelse return error.InvalidRequest;
        const options = question.object.get("options") orelse return error.InvalidRequest;
        if (instruction != .string or options != .array or options.array.items.len < 2 or options.array.items.len > 8) return error.InvalidRequest;
        const choices = try allocator.alloc([]const u8, options.array.items.len);
        for (options.array.items, choices) |option, *choice| {
            if (option != .string) return error.InvalidRequest;
            choice.* = option.string;
        }
        out.* = .{ .instruction = instruction.string, .options = choices };
    }
    return .{ .state = state.string, .questions = result };
}
const Token = struct { id: i32, output: bool = false, slot: usize = 0 };
const Handle = struct { model: *c.llama_model, meta: *c.gguf_context, nw: []const f32, nb: []const f32, qw: []const f32, qb: []const f32, kw: []const f32, kb: []const f32, temperature: f32 };
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
    const v = c.gguf_find_key(meta, "slowclaw.decider.version");
    if (v < 0 or c.gguf_get_kv_type(meta, v) != c.GGUF_TYPE_STRING or !std.mem.eql(u8, std.mem.span(c.gguf_get_val_str(meta, v)), "strands-decider-v21")) return error.ModelLoadFailed;
    const qw = try array(meta, "slowclaw.decider.q.weight", D * P);
    const qb = try array(meta, "slowclaw.decider.q.bias", P);
    const kw = try array(meta, "slowclaw.decider.k.weight", D * P);
    const kb = try array(meta, "slowclaw.decider.k.bias", P);
    const nw = try array(meta, "slowclaw.decider.norm.weight", D);
    const nb = try array(meta, "slowclaw.decider.norm.bias", D);
    const ti = c.gguf_find_key(meta, "slowclaw.decider.temperature");
    if (ti < 0 or c.gguf_get_kv_type(meta, ti) != c.GGUF_TYPE_FLOAT32) return error.ModelLoadFailed;
    const temperature = c.gguf_get_val_f32(meta, ti);
    if (!std.math.isFinite(temperature) or temperature <= 0) return error.ModelLoadFailed;
    engine.ensureBackendInit();
    var mp = c.llama_model_default_params();
    mp.n_gpu_layers = 0;
    mp.load_mode = c.LLAMA_LOAD_MODE_MMAP;
    const model = c.llama_model_load_from_file(z, mp) orelse return error.ModelLoadFailed;
    errdefer c.llama_model_free(model);
    if (c.llama_model_n_embd(model) != D) return error.ModelLoadFailed;
    const h = A.create(Handle) catch return error.OutOfMemory;
    h.* = .{ .model = model, .meta = meta, .nw = nw, .nb = nb, .qw = qw, .qb = qb, .kw = kw, .kb = kb, .temperature = temperature };
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
fn tokenize(vocab: ?*const c.llama_vocab, text: []const u8, tokens: *std.ArrayList(Token)) E!void {
    const count = c.llama_tokenize(vocab, text.ptr, @intCast(text.len), null, 0, false, true);
    if (count == std.math.minInt(i32)) return error.TokenizationFailed;
    const n: usize = @intCast(if (count < 0) -count else count);
    if (n + tokens.items.len > 4096) return error.ContextLimitExceeded;
    const ids = A.alloc(i32, n) catch return error.OutOfMemory;
    defer A.free(ids);
    if (c.llama_tokenize(vocab, text.ptr, @intCast(text.len), ids.ptr, @intCast(n), false, true) != n) return error.TokenizationFailed;
    for (ids) |id| tokens.append(A, .{ .id = id }) catch return error.OutOfMemory;
}
const Span = struct { start: usize, end: usize };
fn prompt(q: Question, spans: *[8]Span) E![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(A);
    text.appendSlice(A, "<question type=\"choice\">\nSelect exactly one option.\n") catch return error.OutOfMemory;
    text.appendSlice(A, std.mem.trim(u8, q.instruction, " \t\r\n")) catch return error.OutOfMemory;
    text.appendSlice(A, "\n<options>\n") catch return error.OutOfMemory;
    for (q.options, 0..) |option, i| {
        spans[i].start = text.items.len;
        const prefix = std.fmt.allocPrint(A, "{d}. ", .{i + 1}) catch return error.OutOfMemory;
        defer A.free(prefix);
        text.appendSlice(A, prefix) catch return error.OutOfMemory;
        // Choice labels are literal, exactly as upstream's criteria keys.
        if (std.mem.indexOfAny(u8, option, "\r\n") != null) return error.InferenceFailed;
        text.appendSlice(A, option) catch return error.OutOfMemory;
        spans[i].end = text.items.len;
        text.append(A, '\n') catch return error.OutOfMemory;
    }
    text.appendSlice(A, "</options>\n</question>\n<answer>") catch return error.OutOfMemory;
    return text.toOwnedSlice(A) catch return error.OutOfMemory;
}
/// Reconstruct Qwen BPE byte offsets, then use the last token wholly in each line.
fn endpoints(vocab: ?*const c.llama_vocab, text: []const u8, spans: []const Span, tokens: []Token) E!void {
    var cursor: usize = 0;
    var found = [_]?usize{null} ** 8;
    for (tokens, 0..) |t, i| {
        var piece: [1024]u8 = undefined;
        const n = c.llama_token_to_piece(vocab, t.id, &piece, piece.len, 0, true);
        if (n <= 0 or @as(usize, @intCast(n)) > text.len - cursor) return error.TokenizationFailed;
        const end = cursor + @as(usize, @intCast(n));
        if (!std.mem.eql(u8, text[cursor..end], piece[0..@intCast(n)])) return error.TokenizationFailed;
        for (spans, 0..) |span, slot| {
            if (cursor >= span.start and end <= span.end) found[slot] = i;
        }
        cursor = end;
    }
    if (cursor != text.len) return error.TokenizationFailed;
    for (found[0..spans.len], 0..) |index, slot| {
        const i = index orelse return error.TokenizationFailed;
        tokens[i].output = true;
        tokens[i].slot = slot;
    }
    tokens[tokens.len - 1].output = true;
    tokens[tokens.len - 1].slot = 8;
}
fn normalized(h: *Handle, input: *const [D]f32) E![D]f64 {
    var mean: f64 = 0;
    for (input) |x| {
        if (!std.math.isFinite(x)) return error.InferenceFailed;
        mean += x;
    }
    mean /= D;
    var variance: f64 = 0;
    for (input) |x| variance += (@as(f64, x) - mean) * (@as(f64, x) - mean);
    const scale = 1 / @sqrt(variance / D + 1e-5);
    var out: [D]f64 = undefined;
    for (0..D) |i| out[i] = (@as(f64, input[i]) - mean) * scale * h.nw[i] + h.nb[i];
    return out;
}
fn probabilities(h: *Handle, hidden: *const [9][D]f32, count: usize, out: []f64) E!void {
    const decide = try normalized(h, &hidden[8]);
    var query: [P]f64 = undefined;
    for (0..P) |p| {
        query[p] = h.qb[p];
        for (0..D) |d| query[p] += @as(f64, h.qw[p * D + d]) * decide[d];
    }
    var logits: [8]f64 = undefined;
    for (0..count) |i| {
        const option = try normalized(h, &hidden[i]);
        var dot: f64 = 0;
        for (0..P) |p| {
            var k: f64 = h.kb[p];
            for (0..D) |d| k += @as(f64, h.kw[p * D + d]) * option[d];
            dot += k * query[p];
        }
        logits[i] = dot / 16 / h.temperature;
    }
    try softmax(logits[0..count], out);
}
pub fn evaluate(raw: ?*anyopaque, json: []const u8, out: []f64) E!usize {
    if (!engine.have_llama) return error.ModelNotLoaded;
    const h: *Handle = @ptrCast(@alignCast(raw orelse return error.ModelNotLoaded));
    if (json.len == 0 or json.len > 64000) return error.ContextLimitExceeded;
    const parsed = std.json.parseFromSlice(std.json.Value, A, json, .{}) catch return error.InferenceFailed;
    defer parsed.deinit();
    const req = requestFromValue(parsed.value, parsed.arena.allocator()) catch return error.InferenceFailed;
    if (req.state.len == 0 or req.state.len > 12000) return error.ContextLimitExceeded;
    var total: usize = 0;
    for (req.questions) |q| {
        if (q.instruction.len == 0 or q.instruction.len > 10000) return error.ContextLimitExceeded;
        for (q.options) |o| if (o.len == 0 or o.len > 512) return error.ContextLimitExceeded;
        total += q.options.len;
    }
    if (out.len < total) return error.ContextLimitExceeded;
    engine.lockEngine();
    defer engine.unlockEngine();
    const vocab = c.llama_model_get_vocab(h.model);
    const state = std.fmt.allocPrint(A, "<state>\n{s}\n</state>\n", .{std.mem.trim(u8, req.state, " \t\r\n")}) catch return error.OutOfMemory;
    defer A.free(state);
    var cursor: usize = 0;
    // Hybrid attention has recurrent state: evaluate full prompts independently.
    for (req.questions) |q| {
        var tokens = std.ArrayList(Token).empty;
        defer tokens.deinit(A);
        try tokenize(vocab, state, &tokens);
        const start = tokens.items.len;
        var spans: [8]Span = undefined;
        const question = try prompt(q, &spans);
        defer A.free(question);
        try tokenize(vocab, question, &tokens);
        try endpoints(vocab, question, spans[0..q.options.len], tokens.items[start..]);
        var cp = c.llama_context_default_params();
        cp.n_ctx = 4096;
        cp.n_batch = 128;
        cp.n_ubatch = 128;
        cp.n_seq_max = 1;
        cp.embeddings = true;
        cp.pooling_type = c.LLAMA_POOLING_TYPE_NONE;
        cp.flash_attn_type = c.LLAMA_FLASH_ATTN_TYPE_DISABLED;
        const ctx = c.llama_init_from_model(h.model, cp) orelse return error.ContextCreateFailed;
        defer c.llama_free(ctx);
        c.llama_set_n_threads(ctx, 2, 2);
        var hidden: [9][D]f32 = undefined;
        var batch = c.llama_batch_init(128, 0, 1);
        defer c.llama_batch_free(batch);
        var offset: usize = 0;
        while (offset < tokens.items.len) {
            const n = @min(128, tokens.items.len - offset);
            batch.n_tokens = @intCast(n);
            for (tokens.items[offset .. offset + n], 0..) |t, i| {
                batch.token[i] = t.id;
                batch.pos[i] = @intCast(offset + i);
                batch.logits[i] = @intFromBool(t.output);
                batch.n_seq_id[i] = 1;
                batch.seq_id[i][0] = 0;
            }
            if (c.llama_decode(ctx, batch) != 0) return error.InferenceFailed;
            for (tokens.items[offset .. offset + n], 0..) |t, i| {
                if (!t.output) continue;
                const ptr = c.llama_get_embeddings_ith(ctx, @intCast(i));
                if (ptr == null) return error.InferenceFailed;
                @memcpy(&hidden[t.slot], ptr[0..D]);
            }
            offset += n;
        }
        try probabilities(h, &hidden, q.options.len, out[cursor .. cursor + q.options.len]);
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
test "Decider softmax is stable and rejects invalid input" {
    var out: [2]f64 = undefined;
    try softmax(&.{ 1000, 1000 }, &out);
    try std.testing.expectEqual(@as(f64, 0.5), out[0]);
    try std.testing.expectError(error.InferenceFailed, softmax(&.{ std.math.nan(f64), 0 }, &out));
}

test "Decider request requires string state and string choices" {
    const cases = [_][]const u8{
        "{\"state\":[65],\"questions\":[]}",
        "{\"state\":\"journal\",\"questions\":[{\"instruction\":\"relevant\",\"options\":[0,1]}]}",
        "{\"state\":\"journal\",\"questions\":[{\"instruction\":12,\"options\":[\"no\",\"yes\"]}]}",
    };
    for (cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidRequest, requestFromValue(parsed.value, parsed.arena.allocator()));
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"state\":\"journal\",\"questions\":[{\"instruction\":\"relevant\",\"options\":[\"no\",\"yes\"]}]}", .{});
    defer parsed.deinit();
    const request = try requestFromValue(parsed.value, parsed.arena.allocator());
    try std.testing.expectEqualStrings("journal", request.state);
    try std.testing.expectEqualStrings("yes", request.questions[0].options[1]);
}
