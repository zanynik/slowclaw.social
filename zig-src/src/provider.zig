//! LLM provider trait + types.
//!
//! Ports `src/providers/traits.rs` (950 LOC). The Rust `Provider` trait
//! (async via async_trait) becomes a synchronous Zig vtable. The core
//! method is `chatWithSystem` — given an optional system prompt + a user
//! message + a model name + temperature, return the LLM's text response.
//!
//! The iOS app calls this for:
//!   - Journal synthesis (transcript → structured journal entry)
//!   - Interest extraction (journal entries → interest keywords)
//!   - Post drafting (journal thoughts → Bluesky/Nostr draft)
//!
//! The first provider impl (`OpenAiProvider` in openai_provider.zig) uses
//! `std.http.Client` to POST to any OpenAI-compatible endpoint (OpenAI,
//! OpenRouter, Ollama, etc.).

const std = @import("std");
const testing = std.testing;

/// A single message in a conversation. Mirrors `ChatMessage` in traits.rs:8.
pub const ChatMessage = struct {
    role: []const u8, // "system" | "user" | "assistant" | "tool"
    content: []const u8,

    pub fn system(content: []const u8) ChatMessage {
        return .{ .role = "system", .content = content };
    }
    pub fn user(content: []const u8) ChatMessage {
        return .{ .role = "user", .content = content };
    }
    pub fn assistant(content: []const u8) ChatMessage {
        return .{ .role = "assistant", .content = content };
    }
};

/// A tool call requested by the LLM. Mirrors `ToolCall` in traits.rs:34.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Token usage from a provider response. Mirrors `TokenUsage`.
pub const TokenUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
};

/// An LLM response. Mirrors `ChatResponse` in traits.rs:46.
pub const ChatResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    usage: ?TokenUsage = null,
    reasoning_content: ?[]const u8 = null,

    pub fn hasToolCalls(self: ChatResponse) bool {
        return self.tool_calls.len > 0;
    }

    pub fn textOrEmpty(self: ChatResponse) []const u8 {
        return self.text orelse "";
    }
};

/// Provider errors.
pub const ProviderError = error{
    HttpFailed,
    InvalidResponse,
    ApiError,
    OutOfMemory,
    InvalidArgument,
};

/// Provider capabilities. Mirrors `ProviderCapabilities`.
pub const ProviderCapabilities = struct {
    native_tool_calling: bool = false,
    vision: bool = false,
};

/// The core LLM provider vtable. Implementers fill in `ctx` (their state)
/// and the `chat_with_system_fn` function pointer. Convenience wrappers
/// (`simpleChat`, `chatWithHistory`) delegate to the core method.
///
/// Mirrors the Rust `Provider` trait. The Rust trait's streaming methods
/// (`chat_stream`) are deferred to a later slice — the synchronous path
/// covers all iOS-side needs (journal synthesis, interest extraction, draft
/// generation).
pub const Provider = struct {
    ctx: *anyopaque,
    name_fn: *const fn (ctx: *anyopaque) []const u8,
    capabilities_fn: *const fn (ctx: *anyopaque) ProviderCapabilities,
    chat_with_system_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8,

    pub fn name(self: Provider) []const u8 {
        return self.name_fn(self.ctx);
    }

    pub fn capabilities(self: Provider) ProviderCapabilities {
        return self.capabilities_fn(self.ctx);
    }

    /// One-shot chat with optional system prompt. Returns the LLM's text
    /// response (allocator-owned). The caller frees it.
    pub fn chatWithSystem(
        self: Provider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8 {
        return self.chat_with_system_fn(self.ctx, allocator, system_prompt, message, model, temperature);
    }

    /// Simple one-shot chat (no system prompt). Convenience wrapper.
    pub fn simpleChat(
        self: Provider,
        allocator: std.mem.Allocator,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8 {
        return self.chatWithSystem(allocator, null, message, model, temperature);
    }

    /// Multi-turn conversation. Extracts the system prompt (first "system"
    /// message) and the last "user" message, delegates to chatWithSystem.
    /// This is the default Rust trait behavior — full history support is
    /// deferred (most iOS use cases are one-shot or two-turn).
    pub fn chatWithHistory(
        self: Provider,
        allocator: std.mem.Allocator,
        messages: []const ChatMessage,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8 {
        var system_prompt: ?[]const u8 = null;
        var last_user: []const u8 = "";
        for (messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) system_prompt = msg.content;
            if (std.mem.eql(u8, msg.role, "user")) last_user = msg.content;
        }
        return self.chatWithSystem(allocator, system_prompt, last_user, model, temperature);
    }
};

// ──────────────────────────────────────────────────────────────────────────
// JSON helpers for provider request/response serialization.
// ──────────────────────────────────────────────────────────────────────────

/// Build the OpenAI-compatible chat completions JSON request body.
/// `messages` is the conversation, `model` is the model name, `temperature`
/// controls randomness. Returns an allocator-owned JSON string.
pub fn buildChatRequestJson(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    model: []const u8,
    temperature: f64,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"model\":");
    try writeJsonString(allocator, &buf, model);
    try buf.appendSlice(allocator, ",\"temperature\":");
    const temp_str = try std.fmt.allocPrint(allocator, "{d}", .{temperature});
    defer allocator.free(temp_str);
    try buf.appendSlice(allocator, temp_str);
    try buf.appendSlice(allocator, ",\"messages\":[");

    var first = true;
    if (system_prompt) |sys| {
        try buf.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try writeJsonString(allocator, &buf, sys);
        try buf.append(allocator, '}');
        first = false;
    }
    if (!first) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "{\"role\":\"user\",\"content\":");
    try writeJsonString(allocator, &buf, message);
    try buf.append(allocator, '}');

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Extract the assistant's text content from an OpenAI-compatible JSON
/// response. Returns an allocator-owned string. Returns null if no content
/// was present (e.g. only tool calls).
pub fn parseChatResponseJson(allocator: std.mem.Allocator, json: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    const choices = parsed.value.object.get("choices") orelse return error.InvalidResponse;
    if (choices.array.items.len == 0) return null;

    const first_choice = choices.array.items[0];
    const message_obj = first_choice.object.get("message") orelse return error.InvalidResponse;
    const content = message_obj.object.get("content") orelse return null;

    switch (content) {
        .string => |s| return try allocator.dupe(u8, s),
        .null => return null,
        else => return null,
    }
}

/// Write a JSON-escaped string into `buf`. Handles quotes, backslashes,
/// control chars.
pub fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{ch});
                    defer allocator.free(esc);
                    try buf.appendSlice(allocator, esc);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "ChatMessage constructors" {
    const sys = ChatMessage.system("you are helpful");
    try testing.expectEqualStrings("system", sys.role);
    try testing.expectEqualStrings("you are helpful", sys.content);

    const usr = ChatMessage.user("hello");
    try testing.expectEqualStrings("user", usr.role);
}

test "ChatResponse.textOrEmpty" {
    const with_text = ChatResponse{ .text = "hello" };
    try testing.expectEqualStrings("hello", with_text.textOrEmpty());

    const no_text = ChatResponse{};
    try testing.expectEqualStrings("", no_text.textOrEmpty());
}

test "buildChatRequestJson: system + user" {
    const a = testing.allocator;
    const json = try buildChatRequestJson(a, "be brief", "what is 2+2", "gpt-4", 0.7);
    defer a.free(json);

    const Tag = std.meta.Tag(std.json.Value);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(Tag.object, std.meta.activeTag(parsed.value));
    const messages = parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 2), messages.array.items.len);
    try testing.expectEqualStrings("system", messages.array.items[0].object.get("role").?.string);
    try testing.expectEqualStrings("user", messages.array.items[1].object.get("role").?.string);
}

test "buildChatRequestJson: user only (no system)" {
    const a = testing.allocator;
    const json = try buildChatRequestJson(a, null, "hi", "gpt-4", 0.0);
    defer a.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?;
    try testing.expectEqual(@as(usize, 1), messages.array.items.len);
    try testing.expectEqualStrings("user", messages.array.items[0].object.get("role").?.string);
}

test "buildChatRequestJson: escapes special chars in message" {
    const a = testing.allocator;
    const json = try buildChatRequestJson(a, null, "say \"hello\"\nworld", "gpt-4", 0.5);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\\\"hello\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}

test "parseChatResponseJson: extracts content" {
    const a = testing.allocator;
    const response =
        \\{"choices":[{"message":{"role":"assistant","content":"4"}}]}
    ;
    const text = try parseChatResponseJson(a, response);
    defer if (text) |t| a.free(t);
    try testing.expect(text != null);
    try testing.expectEqualStrings("4", text.?);
}

test "parseChatResponseJson: null content returns null" {
    const a = testing.allocator;
    const response =
        \\{"choices":[{"message":{"role":"assistant","content":null}}]}
    ;
    const text = try parseChatResponseJson(a, response);
    try testing.expect(text == null);
}

test "parseChatResponseJson: empty choices returns null" {
    const a = testing.allocator;
    const response = "{\"choices\":[]}";
    const text = try parseChatResponseJson(a, response);
    try testing.expect(text == null);
}

test "parseChatResponseJson: invalid JSON returns error" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidResponse, parseChatResponseJson(a, "not json"));
}

test "writeJsonString: escapes correctly" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try writeJsonString(a, &buf, "hello \"world\"\t");
    try testing.expectEqualStrings("\"hello \\\"world\\\"\\t\"", buf.items);
}
