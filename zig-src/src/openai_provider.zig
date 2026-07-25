//! OpenAI-compatible LLM provider — HTTP chat completions via injected transport.
//!
//! Ports `src/providers/openai.rs` (831 LOC). The Rust original uses reqwest
//! for HTTP. Zig 0.16's `std.http.Client` requires the Io subsystem (async),
//! which is not easily accessible from synchronous code. Instead, the HTTP
//! transport is injected as a callback: the iOS app (Swift) provides the
//! actual HTTP call via URLSession, and Zig handles JSON request building +
//! response parsing.
//!
//! This is architecturally cleaner anyway — URLSession is better at TLS,
//! proxy handling, certificate pinning, and background sessions than any
//! HTTP client we'd build in Zig. The Zig core owns the API contract (JSON
//! shape, auth header format, URL construction); Swift owns the transport.
//!
//! Satisfies the `Provider` vtable from provider.zig.

const std = @import("std");
const provider = @import("provider.zig");

const ProviderError = provider.ProviderError;

/// HTTP transport callback. Given a URL, method, headers, and body, returns
/// the response body (allocator-owned). The iOS app implements this via
/// URLSession and passes it through the C ABI.
pub const HttpTransport = struct {
    ctx: *anyopaque,
    /// POST `body` to `url` with the given `auth_header` value. Returns the
    /// response body (allocator-owned, caller frees).
    post_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        auth_header: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) HttpError![]u8,

    pub fn post(
        self: HttpTransport,
        allocator: std.mem.Allocator,
        url: []const u8,
        auth_header: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) HttpError![]u8 {
        return self.post_fn(self.ctx, allocator, url, auth_header, content_type, body);
    }
};

pub const HttpError = error{
    HttpFailed,
    NonOkStatus,
    OutOfMemory,
};

/// OpenAI-compatible provider state. Mirrors `OpenAiProvider` in openai.rs.
/// `base_url` defaults to "https://api.openai.com/v1" but can point at any
/// compatible endpoint (OpenRouter, Ollama, etc.).
/// `transport` is the injected HTTP callback (typically Swift's URLSession).
pub const OpenAiProvider = struct {
    base_url: []const u8,
    api_key: ?[]const u8,
    transport: HttpTransport,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, api_key: ?[]const u8, transport: HttpTransport) OpenAiProvider {
        return .{
            .base_url = "https://api.openai.com/v1",
            .api_key = api_key,
            .transport = transport,
            .allocator = allocator,
        };
    }

    pub fn withBaseUrl(allocator: std.mem.Allocator, base_url: []const u8, api_key: ?[]const u8, transport: HttpTransport) OpenAiProvider {
        return .{
            .base_url = base_url,
            .api_key = api_key,
            .transport = transport,
            .allocator = allocator,
        };
    }

    /// Get a `Provider` vtable wrapping this instance.
    pub fn provider_(self: *OpenAiProvider) provider.Provider {
        return .{
            .ctx = self,
            .name_fn = vtableName,
            .capabilities_fn = vtableCapabilities,
            .chat_with_system_fn = vtableChatWithSystem,
        };
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "openai";
    }

    fn vtableCapabilities(_: *anyopaque) provider.ProviderCapabilities {
        return .{ .native_tool_calling = true, .vision = true };
    }

    fn vtableChatWithSystem(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8 {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ctx));
        return self.chatWithSystem(allocator, system_prompt, message, model, temperature);
    }

    /// Core chat call. Builds the JSON request body, delegates to the
    /// injected HTTP transport, parses the response.
    /// Returns the assistant's text response (allocator-owned).
    pub fn chatWithSystem(
        self: *OpenAiProvider,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) ProviderError![]u8 {
        const api_key = self.api_key orelse return error.InvalidArgument;

        // Build the JSON request body.
        const request_body = provider.buildChatRequestJson(
            allocator,
            system_prompt,
            message,
            model,
            temperature,
        ) catch return error.OutOfMemory;
        defer allocator.free(request_body);

        // Build the full URL: <base_url>/chat/completions
        const url = std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url}) catch return error.OutOfMemory;
        defer allocator.free(url);

        // Build the Authorization header value.
        const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch return error.OutOfMemory;
        defer allocator.free(auth_header);

        // Execute via the injected transport.
        const response_body = self.transport.post(
            allocator,
            url,
            auth_header,
            "application/json",
            request_body,
        ) catch return error.HttpFailed;
        defer allocator.free(response_body);

        // Parse the JSON response.
        const text = provider.parseChatResponseJson(allocator, response_body) catch return error.InvalidResponse;
        return text orelse allocator.dupe(u8, "") catch return error.OutOfMemory;
    }
};

// ──────────────────────────────────────────────────────────────────────────
// Tests — use a stub transport that returns canned responses.
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Stub HTTP transport for testing: returns a fixed canned response body.
const StubTransport = struct {
    canned_response: []const u8,
    last_url: ?[]const u8 = null,
    last_body: ?[]const u8 = null,
    arena: ?std.mem.Allocator = null, // for duping captured url/body

    fn postImpl(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        auth_header: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) HttpError![]u8 {
        _ = auth_header;
        _ = content_type;
        const self: *StubTransport = @ptrCast(@alignCast(ctx));
        // Capture the URL and body for later assertions (dupe so they outlive
        // the caller's temporary strings).
        if (self.arena) |a| {
            self.last_url = a.dupe(u8, url) catch null;
            self.last_body = a.dupe(u8, body) catch null;
        }
        // Return the canned response using the caller's allocator (it will free).
        return allocator.dupe(u8, self.canned_response) catch return error.OutOfMemory;
    }

    fn transport(self: *StubTransport) HttpTransport {
        return .{ .ctx = self, .post_fn = postImpl };
    }
};

test "OpenAiProvider: default base URL" {
    var stub = StubTransport{ .canned_response = "{}" };
    const p = OpenAiProvider.init(testing.allocator, "key", stub.transport());
    try testing.expectEqualStrings("https://api.openai.com/v1", p.base_url);
}

test "OpenAiProvider: custom base URL" {
    var stub = StubTransport{ .canned_response = "{}" };
    const p = OpenAiProvider.withBaseUrl(testing.allocator, "http://localhost:11434/v1", null, stub.transport());
    try testing.expectEqualStrings("http://localhost:11434/v1", p.base_url);
}

test "OpenAiProvider: name is 'openai'" {
    var stub = StubTransport{ .canned_response = "{}" };
    var p = OpenAiProvider.init(testing.allocator, "key", stub.transport());
    const pv = p.provider_();
    try testing.expectEqualStrings("openai", pv.name());
}

test "OpenAiProvider: capabilities declares native tools + vision" {
    var stub = StubTransport{ .canned_response = "{}" };
    var p = OpenAiProvider.init(testing.allocator, "key", stub.transport());
    const pv = p.provider_();
    const caps = pv.capabilities();
    try testing.expect(caps.native_tool_calling);
    try testing.expect(caps.vision);
}

test "OpenAiProvider: chatWithSystem without API key returns InvalidArgument" {
    var stub = StubTransport{ .canned_response = "{}" };
    var p = OpenAiProvider.init(testing.allocator, null, stub.transport());
    try testing.expectError(error.InvalidArgument, p.chatWithSystem(testing.allocator, null, "hi", "gpt-4", 0.7));
}

test "OpenAiProvider: chatWithSystem returns parsed response via stub transport" {
    const canned =
        \\{"choices":[{"message":{"role":"assistant","content":"4"}}]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub = StubTransport{ .canned_response = canned, .arena = arena.allocator() };
    var p = OpenAiProvider.init(testing.allocator, "test-key", stub.transport());

    const result = try p.chatWithSystem(testing.allocator, "be brief", "what is 2+2", "gpt-4", 0.7);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("4", result);

    // Verify the transport was called with the right URL.
    try testing.expect(stub.last_url != null);
    try testing.expect(std.mem.endsWith(u8, stub.last_url.?, "/chat/completions"));

    // Verify the request body contains the system prompt and user message.
    try testing.expect(stub.last_body != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_body.?, "be brief") != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_body.?, "what is 2+2") != null);
}

test "OpenAiProvider: provider vtable round-trip via stub" {
    const canned =
        \\{"choices":[{"message":{"role":"assistant","content":"hello"}}]}
    ;
    var stub = StubTransport{ .canned_response = canned };
    var p = OpenAiProvider.init(testing.allocator, "key", stub.transport());
    const pv = p.provider_();

    const result = try pv.simpleChat(testing.allocator, "say hi", "gpt-4", 0.5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "OpenAiProvider: empty content returns empty string" {
    const canned =
        \\{"choices":[{"message":{"role":"assistant","content":""}}]}
    ;
    var stub = StubTransport{ .canned_response = canned };
    var p = OpenAiProvider.init(testing.allocator, "key", stub.transport());

    const result = try p.chatWithSystem(testing.allocator, null, "say nothing", "gpt-4", 0.5);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}
