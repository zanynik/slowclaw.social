//! Interest profile — editable steering layer for the curation lens.
//!
//! Ports `web/src/lib/interestProfile.ts` (171 LOC) from TypeScript to Zig.
//! The TS original is localStorage-backed; the Zig version uses in-memory
//! state (persisted via the SQLite store or Swift's UserDefaults — the caller
//! decides the backing store). The ranking logic is what matters: multipliers
//! + manual interests that steer the feed ranker.

const std = @import("std");
const testing = std.testing;
const feeds_ranking = @import("feeds_ranking.zig");

/// Discrete multiplier states (matching the TS INTEREST_MULT).
pub const MULT_MUTE: f64 = 0;
pub const MULT_NORMAL: f64 = 1;
pub const MULT_BOOST: f64 = 2;

/// In-memory interest profile. The caller persists this (SQLite or Swift
/// UserDefaults). Thread-safe access is the caller's responsibility (iOS
/// serializes via the main dispatch queue).
pub const InterestProfile = struct {
    allocator: std.mem.Allocator,
    /// label (lowercased) → multiplier. Overrides apply on top of the
    /// journal-derived weight. Mute (0) removes from the lens.
    overrides: std.StringHashMap(f64),
    /// Manual interests not yet in journals. These get a default multiplier
    /// of MULT_NORMAL and feed into the ranker as additional topics.
    manual_interests: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) InterestProfile {
        return .{
            .allocator = allocator,
            .overrides = std.StringHashMap(f64).init(allocator),
            .manual_interests = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *InterestProfile) void {
        var it = self.overrides.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.overrides.deinit();
        for (self.manual_interests.items) |s| self.allocator.free(s);
        self.manual_interests.deinit(self.allocator);
    }

    /// Get the multiplier for a label (default NORMAL=1.0).
    pub fn multiplierFor(self: *const InterestProfile, label: []const u8) f64 {
        const lower = lowerOwned(self.allocator, label) catch return MULT_NORMAL;
        defer self.allocator.free(lower);
        return self.overrides.get(lower) orelse MULT_NORMAL;
    }

    /// Set a topic's multiplier (use MULT_* constants).
    pub fn setMultiplier(self: *InterestProfile, label: []const u8, multiplier: f64) void {
        const lower = lowerOwned(self.allocator, label) catch return;
        // Free old key if re-setting.
        if (self.overrides.fetchRemove(lower)) |kv| {
            self.allocator.free(kv.key);
        }
        self.overrides.put(lower, multiplier) catch {};
    }

    /// Remove an override (return to as-derived weight).
    pub fn removeOverride(self: *InterestProfile, label: []const u8) void {
        const lower = lowerOwned(self.allocator, label) catch return;
        defer self.allocator.free(lower);
        if (self.overrides.fetchRemove(lower)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Add a manual interest. Returns true if new. Trims/lowercases.
    pub fn addManualInterest(self: *InterestProfile, label: []const u8) bool {
        const lower = lowerOwned(self.allocator, label) catch return false;
        if (lower.len == 0) {
            self.allocator.free(lower);
            return false;
        }
        for (self.manual_interests.items) |existing| {
            if (std.mem.eql(u8, existing, lower)) {
                self.allocator.free(lower);
                return false;
            }
        }
        self.manual_interests.append(self.allocator, lower) catch return false;
        return true;
    }

    /// Remove a manual interest.
    pub fn removeManualInterest(self: *InterestProfile, label: []const u8) void {
        const lower = lowerOwned(self.allocator, label) catch return;
        defer self.allocator.free(lower);
        for (self.manual_interests.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, lower)) {
                self.allocator.free(self.manual_interests.items[i]);
                _ = self.manual_interests.orderedRemove(i);
                return;
            }
        }
    }

    /// Get all manual interests.
    pub fn getManualInterests(self: *const InterestProfile) []const []const u8 {
        return self.manual_interests.items;
    }

    /// Build the effective topic list for the ranker: merge journal-derived
    /// topics with manual interests, applying multiplier overrides. Topics
    /// with multiplier 0 (muted) are dropped.
    ///
    /// Caller owns the returned slice (each topic's label is allocator-owned).
    pub fn effectiveTopics(
        self: *const InterestProfile,
        allocator: std.mem.Allocator,
        derived_topics: []const feeds_ranking.Topic,
    ) ![]feeds_ranking.Topic {
        var out = std.ArrayList(feeds_ranking.Topic).empty;
        errdefer {
            for (out.items) |t| allocator.free(t.label);
            out.deinit(allocator);
        }

        // Apply overrides to derived topics.
        for (derived_topics) |dt| {
            const mult = self.multiplierFor(dt.label);
            if (mult <= 0) continue; // muted
            const label_copy = try allocator.dupe(u8, dt.label);
            try out.append(allocator, .{
                .label = label_copy,
                .weight = dt.weight * mult,
            });
        }

        // Add manual interests (default weight 1.0 * multiplier).
        for (self.manual_interests.items) |manual| {
            const mult = self.multiplierFor(manual);
            if (mult <= 0) continue; // muted
            // Skip if already in derived topics.
            var already = false;
            for (out.items) |t| {
                if (std.mem.eql(u8, t.label, manual)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            const label_copy = try allocator.dupe(u8, manual);
            try out.append(allocator, .{
                .label = label_copy,
                .weight = 1.0 * mult,
            });
        }

        // Sort by weight descending.
        std.sort.block(feeds_ranking.Topic, out.items, {}, struct {
            fn cmp(_: void, a: feeds_ranking.Topic, b: feeds_ranking.Topic) bool {
                return a.weight > b.weight;
            }
        }.cmp);

        return out.toOwnedSlice(allocator);
    }
};

fn lowerOwned(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, src, " \t\n\r");
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

pub fn freeTopics(allocator: std.mem.Allocator, topics: []feeds_ranking.Topic) void {
    for (topics) |t| allocator.free(t.label);
    allocator.free(topics);
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "InterestProfile: default multiplier is NORMAL" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    try testing.expectEqual(MULT_NORMAL, profile.multiplierFor("rust"));
}

test "InterestProfile: set and get multiplier" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    profile.setMultiplier("rust", MULT_BOOST);
    try testing.expectEqual(MULT_BOOST, profile.multiplierFor("Rust")); // case-insensitive
    try testing.expectEqual(MULT_BOOST, profile.multiplierFor("rust"));
}

test "InterestProfile: mute sets to 0" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    profile.setMultiplier("celebrity gossip", MULT_MUTE);
    try testing.expectEqual(@as(f64, 0), profile.multiplierFor("Celebrity Gossip"));
}

test "InterestProfile: remove override returns to NORMAL" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    profile.setMultiplier("rust", MULT_BOOST);
    profile.removeOverride("rust");
    try testing.expectEqual(MULT_NORMAL, profile.multiplierFor("rust"));
}

test "InterestProfile: add manual interest (new)" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    try testing.expect(profile.addManualInterest("Rust")); // new
    try testing.expect(!profile.addManualInterest("rust")); // dup (case-insensitive)
    try testing.expect(!profile.addManualInterest("")); // empty
}

test "InterestProfile: remove manual interest" {
    var profile = InterestProfile.init(testing.allocator);
    defer profile.deinit();
    _ = profile.addManualInterest("rust");
    _ = profile.addManualInterest("cycling");
    profile.removeManualInterest("Rust"); // case-insensitive
    try testing.expectEqual(@as(usize, 1), profile.getManualInterests().len);
    try testing.expectEqualStrings("cycling", profile.getManualInterests()[0]);
}

test "effectiveTopics: merges derived + manual, applies multipliers, drops muted" {
    const a = testing.allocator;
    var profile = InterestProfile.init(a);
    defer profile.deinit();

    _ = profile.addManualInterest("coffee");
    profile.setMultiplier("rust", MULT_BOOST);
    profile.setMultiplier("spam", MULT_MUTE);

    const derived = [_]feeds_ranking.Topic{
        .{ .label = "rust", .weight = 0.5 },
        .{ .label = "spam", .weight = 0.3 },
    };
    const effective = try profile.effectiveTopics(a, &derived);
    defer freeTopics(a, effective);

    // rust: 0.5 * 2.0 = 1.0, coffee: 1.0 * 1.0 = 1.0, spam: muted (dropped)
    try testing.expectEqual(@as(usize, 2), effective.len);
    // Sorted by weight desc; both are 1.0 so order may vary. Verify no "spam".
    for (effective) |t| {
        try testing.expect(!std.mem.eql(u8, t.label, "spam"));
    }
}
