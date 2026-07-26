//! On-device LLM inference via llama.cpp C API.
//!
//! Ports the concept from `web/src-tauri/src/inference.rs` (which uses
//! `llama-cpp-2`). The Zig version binds llama.cpp's C API directly —
//! no Rust crate, no async runtime. Loads a GGUF model file and runs
//! text generation locally.
//!
//! On iOS this links against the same llama.cpp binary the original app
//! used (Metal/Accelerate frameworks for GPU). The build.zig links the
//! precompiled llama.a when available.
//!
//! Architecture: this satisfies the Provider vtable from provider.zig —
//! so the same LLM calls (synthesizeJournal, extractInterests, draftPost)
//! work whether the backend is OpenAI HTTP or on-device llama.cpp.

const std = @import("std");
const provider = @import("provider.zig");

pub const InferenceError = error{
    ModelNotLoaded,
    ModelLoadFailed,
    ContextCreateFailed,
    TokenizationFailed,
    InferenceFailed,
    OutOfMemory,
};

/// On-device LLM inference engine. Wraps llama.cpp's C API.
/// On iOS, the model file lives in the app's Documents directory
/// (downloaded or bundled by Swift).
pub const LocalInference = struct {
    model_path: []const u8,
    is_loaded: bool = false,
    // In production these would be raw llama.cpp pointers (llama_model*,
    // llama_context*). For now we declare the structure; the actual C
    // bindings land when llama.a is linked in the build.
    // model_handle: ?*anyopaque = null,
    // context_handle: ?*anyopaque = null,

    pub fn init(model_path: []const u8) LocalInference {
        return .{ .model_path = model_path };
    }

    /// Load the GGUF model file. Must be called before inference.
    /// Returns InferenceError on failure.
    pub fn load(self: *LocalInference) InferenceError!void {
        // TODO: llama_model_load_from_file(self.model_path, params)
        // For now, mark as loaded if the file exists.
        const file = std.fs.cwd().openFile(self.model_path, .{}) catch return error.ModelLoadFailed;
        file.close();
        self.is_loaded = true;
    }

    /// Generate text from a prompt. Returns the generated text (allocator-owned).
    /// `max_tokens` limits the output length. `temperature` controls randomness.
    ///
    /// This is the core inference call — equivalent to llama.cpp's
    /// llama_decode + llama_sampler_sample loop.
    pub fn generate(
        self: *LocalInference,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        max_tokens: u32,
        temperature: f32,
    ) InferenceError![]u8 {
        if (!self.is_loaded) return error.ModelNotLoaded;
        _ = max_tokens;
        _ = temperature;

        // TODO: Real inference loop:
        // 1. Tokenize the prompt: llama_tokenize(model, prompt, ...)
        // 2. Create a batch: llama_batch_get_one(tokens, n_tokens)
        // 3. Feed into the model: llama_decode(ctx, batch)
        // 4. Sample the next token: llama_sampler_sample(sampler, ctx, -1)
        // 5. Append to output, repeat until EOS or max_tokens
        //
        // For now return the prompt as-is (placeholder so the FFI compiles
        // and the UI can be tested without a real model).
        return allocator.dupe(u8, prompt) catch error.OutOfMemory;
    }

    /// Generate a chat response. Builds a chat-formatted prompt (system +
    /// user), runs inference, returns the assistant's response.
    /// Satisfies the Provider vtable.
    pub fn chatWithSystem(
        self: *LocalInference,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) provider.ProviderError![]u8 {
        _ = model; // model is already loaded via load()

        // Build the chat prompt. Simple format:
        //   [system] {system_prompt}
        //   [user] {message}
        //   [assistant]
        var prompt = std.ArrayList(u8).empty;
        defer prompt.deinit(allocator);
        if (system_prompt) |sys| {
            prompt.appendSlice(allocator, "System: ") catch return error.OutOfMemory;
            prompt.appendSlice(allocator, sys) catch return error.OutOfMemory;
            prompt.append(allocator, '\n') catch return error.OutOfMemory;
        }
        prompt.appendSlice(allocator, "User: ") catch return error.OutOfMemory;
        prompt.appendSlice(allocator, message) catch return error.OutOfMemory;
        prompt.appendSlice(allocator, "\nAssistant: ") catch return error.OutOfMemory;

        return self.generate(allocator, prompt.items, 512, @floatCast(temperature)) catch |err| switch (err) {
            error.ModelNotLoaded => error.InvalidArgument,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ApiError,
        };
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
    try testing.expectError(error.ModelNotLoaded, li.generate(testing.allocator, "test", 100, 0.5));
}

test "LocalInference: chatWithSystem without load returns error" {
    var li = LocalInference.init("/nonexistent/path.gguf");
    try testing.expectError(error.InvalidArgument, li.chatWithSystem(testing.allocator, null, "hi", "local", 0.7));
}
