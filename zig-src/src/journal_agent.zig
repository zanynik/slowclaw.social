//! Journal synthesis + interest extraction agents.
//!
//! The "intelligence" layer that turns raw user input into structured data:
//!   - `synthesizeJournal`: transcript → clean, structured journal entry
//!   - `extractInterests`: journal text → interest keywords for feed ranking
//!   - `draftPost`: journal thoughts → Bluesky/Nostr post draft
//!
//! These are the LLM prompts that power the three product loops. Each uses
//! the Provider vtable from provider.zig — the actual LLM call goes through
//! whatever provider is injected (OpenAI-compatible via the FFI, on-device
//! via llama.cpp, etc.).

const std = @import("std");
const provider = @import("provider.zig");

/// Synthesize a raw audio transcript into a clean, structured journal entry.
///
/// The prompt instructs the LLM to:
///   - Clean up speech disfluencies (um, uh, repetitions)
///   - Organize into clear paragraphs
///   - Preserve the user's voice and intent
///   - Add a concise title
///
/// Returns the synthesized journal text (allocator-owned).
pub fn synthesizeJournal(
    p: provider.Provider,
    allocator: std.mem.Allocator,
    transcript: []const u8,
    model: []const u8,
) provider.ProviderError![]u8 {
    const system_prompt =
        \\You are a journal synthesis engine. Your job is to transform a raw speech transcript into a clean, readable journal entry.
        \\
        \\Rules:
        \\- Remove filler words, false starts, and repetitions ("um", "uh", "like", "you know").
        \\- Organize the content into 1-3 clear paragraphs.
        \\- Preserve the speaker's voice, tone, and intent. This is THEIR journal, not a summary.
        \\- If the transcript mentions specific topics, projects, or ideas, keep them — they feed into interest extraction.
        \\- Do NOT add commentary, advice, or questions. Just clean up and structure.
        \\- Output the journal entry text directly. No markdown headers, no preamble.
    ;
    const user_prompt = try std.fmt.allocPrint(allocator, "Transcript:\n{s}", .{transcript});
    defer allocator.free(user_prompt);

    return p.chatWithSystem(allocator, system_prompt, user_prompt, model, 0.3);
}

/// Extract interest keywords from journal text for feed ranking.
///
/// The prompt asks the LLM to identify 3-8 distinct interests (topics,
/// themes, technologies, hobbies) that the journal entry reveals. These
/// become the `InterestVector` keywords that steer the feed ranker.
///
/// Returns a comma-separated list of lowercase keywords (allocator-owned).
pub fn extractInterests(
    p: provider.Provider,
    allocator: std.mem.Allocator,
    journal_text: []const u8,
    model: []const u8,
) provider.ProviderError![]u8 {
    const system_prompt =
        \\You are an interest extraction engine. Analyze a journal entry and extract the author's interests — the topics, themes, technologies, activities, and ideas they care about.
        \\
        \\Rules:
        \\- Output 3-8 distinct interests as a comma-separated list.
        \\- Each interest is 1-3 words, lowercase, no quotes.
        \\- Focus on SPECIFIC interests, not generic categories. "rust programming" not "programming". "sourdough baking" not "cooking".
        \\- Include both explicit mentions and implied interests.
        \\- Output ONLY the comma-separated list. No preamble, no explanation.
        \\
        \\Example output: rust programming, sourdough baking, urban cycling, climate tech
    ;
    return p.chatWithSystem(allocator, system_prompt, journal_text, model, 0.4);
}

/// Parse a comma-separated interest list into individual keywords.
/// Trims whitespace, lowercases, filters empty, deduplicates.
/// Returns an allocator-owned slice of allocator-owned strings.
pub fn parseInterestList(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]const []const u8 {
    var keywords = std.ArrayList([]const u8).empty;
    errdefer {
        for (keywords.items) |k| allocator.free(k);
        keywords.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var it = std.mem.tokenizeAny(u8, raw, ",\n");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;

        // Lowercase
        const lower = try allocator.alloc(u8, trimmed.len);
        for (trimmed, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);

        if (!seen.contains(lower)) {
            try seen.put(lower, {});
            try keywords.append(allocator, lower);
        } else {
            allocator.free(lower);
        }
    }

    return keywords.toOwnedSlice(allocator);
}

/// Free a keyword list produced by parseInterestList.
pub fn freeInterestList(allocator: std.mem.Allocator, keywords: []const []const u8) void {
    for (keywords) |k| allocator.free(k);
    allocator.free(keywords);
}

/// Draft a short-form post (Bluesky/Nostr) from journal thoughts.
///
/// The prompt asks the LLM to distill the essence of the journal entry into
/// a publishable post. The user reviews and edits before publishing.
pub fn draftPost(
    p: provider.Provider,
    allocator: std.mem.Allocator,
    journal_text: []const u8,
    model: []const u8,
    max_chars: usize,
) provider.ProviderError![]u8 {
    const system_prompt = try std.fmt.allocPrint(
        allocator,
        \\You are a social media post drafter. Transform a journal entry into a single publishable post for Bluesky/Nostr.
        \\
        \\Rules:
        \\- Capture ONE key insight or thought from the journal. Don't summarize everything.
        \\- Write in the author's voice — authentic, not promotional.
        \\- Maximum {d} characters (Bluesky limit). Be concise.
        \\- No hashtags unless the author naturally uses them.
        \\- No links unless the journal references one.
        \\- Output the post text directly. No preamble, no quotes around it.
        \\
        \\The post will be reviewed by the author before publishing. Draft something they'd be proud to share.
    ,
        .{max_chars},
    );
    defer allocator.free(system_prompt);

    return p.chatWithSystem(allocator, system_prompt, journal_text, model, 0.6);
}

/// Generate a concise title for a journal entry from its transcript/text.
///
/// The prompt asks the LLM for a short, descriptive title (max ~8 words) that
/// captures the entry's essence. Used as the audio journal's display title
/// when AI is available; otherwise the UI falls back to a date-time default.
/// Returns the title text (allocator-owned).
pub fn generateTitle(
    p: provider.Provider,
    allocator: std.mem.Allocator,
    transcript: []const u8,
    model: []const u8,
) provider.ProviderError![]u8 {
    const system_prompt =
        \\You write a concise, descriptive title for a journal entry.
        \\
        \\Rules:
        \\- Maximum 8 words. Capture the main topic or moment.
        \\- Title case is fine. No trailing period, no quotes, no preamble.
        \\- Reflect what the entry is actually about, not a generic label like "Journal Entry".
        \\- Output ONLY the title text, nothing else.
    ;
    return p.chatWithSystem(allocator, system_prompt, transcript, model, 0.4);
}

// ──────────────────────────────────────────────────────────────────────────
// Tests (with a stub provider)
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Stub provider that returns a fixed canned response.
const StubProvider = struct {
    canned: []const u8,
    last_system: ?[]const u8 = null,
    last_message: ?[]const u8 = null,
    arena: std.mem.Allocator,

    fn name(_: *anyopaque) []const u8 {
        return "stub";
    }
    fn caps(_: *anyopaque) provider.ProviderCapabilities {
        return .{};
    }
    fn chat(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) provider.ProviderError![]u8 {
        _ = model;
        _ = temperature;
        const self: *StubProvider = @ptrCast(@alignCast(ctx));
        if (system_prompt) |s| self.last_system = self.arena.dupe(u8, s) catch null;
        self.last_message = self.arena.dupe(u8, message) catch null;
        return allocator.dupe(u8, self.canned) catch error.OutOfMemory;
    }

    fn provider_(self: *StubProvider) provider.Provider {
        return .{
            .ctx = self,
            .name_fn = name,
            .capabilities_fn = caps,
            .chat_with_system_fn = chat,
        };
    }
};

test "synthesizeJournal: calls provider with transcript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub = StubProvider{ .canned = "Clean journal entry", .arena = arena.allocator() };
    const p = stub.provider_();

    const result = try synthesizeJournal(p, testing.allocator, "um so I was thinking about rust", "gpt-4");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Clean journal entry", result);

    // Verify the system prompt was set (contains "journal synthesis").
    try testing.expect(stub.last_system != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_system.?, "journal synthesis") != null);

    // Verify the user message contains the transcript.
    try testing.expect(stub.last_message != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_message.?, "rust") != null);
}

test "extractInterests: calls provider with journal text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub = StubProvider{ .canned = "rust, cycling, coffee", .arena = arena.allocator() };
    const p = stub.provider_();

    const result = try extractInterests(p, testing.allocator, "I love coding in rust and riding my bike", "gpt-4");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("rust, cycling, coffee", result);

    try testing.expect(stub.last_system != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_system.?, "interest extraction") != null);
}

test "parseInterestList: splits, trims, lowercases, dedupes" {
    const a = testing.allocator;
    const keywords = try parseInterestList(a, "Rust,  Cycling , cycling, Coffee,, ");
    defer freeInterestList(a, keywords);
    try testing.expectEqual(@as(usize, 3), keywords.len);
    try testing.expectEqualStrings("rust", keywords[0]);
    try testing.expectEqualStrings("cycling", keywords[1]);
    try testing.expectEqualStrings("coffee", keywords[2]);
}

test "parseInterestList: empty input returns empty" {
    const a = testing.allocator;
    const keywords = try parseInterestList(a, "  ,,  , ");
    defer freeInterestList(a, keywords);
    try testing.expectEqual(@as(usize, 0), keywords.len);
}

test "parseInterestList: newlines also split" {
    const a = testing.allocator;
    const keywords = try parseInterestList(a, "rust\ncycling\ncoffee");
    defer freeInterestList(a, keywords);
    try testing.expectEqual(@as(usize, 3), keywords.len);
}

test "draftPost: calls provider with max_chars in system prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub = StubProvider{ .canned = "Just shipped a thing", .arena = arena.allocator() };
    const p = stub.provider_();

    const result = try draftPost(p, testing.allocator, "I finished the project today", "gpt-4", 300);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Just shipped a thing", result);

    try testing.expect(stub.last_system != null);
    try testing.expect(std.mem.indexOf(u8, stub.last_system.?, "300") != null);
}
