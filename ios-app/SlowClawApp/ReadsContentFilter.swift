// ReadsContentFilter.swift — adult-content gate for the Reads feed.
//
// Global relays and broad RSS catalogs carry adult/spam content that doesn't
// tag itself (no content-warning), so ingestion filters alone aren't enough.
// This is a deliberately SMALL blocklist of unambiguous sexual-content terms
// (English + the CJK/Cyrillic patterns observed on the default relays),
// matched against whitespace-stripped lowercased text. Whitespace stripping
// matters: relay spam writes "脚 交" with a space to dodge naive filters.
//
// Applied in two places:
//   - NostrFetcher.filterArticles (title + summary + body, at ingestion)
//   - AppState.loadReads (title + description, on the merged batch — covers
//     RSS sources too)
//
// Kept dependency-free and conservative: better to let a borderline item
// through than to drop legitimate tech/politics articles on false positives.

enum ReadsContentFilter {

    /// Unambiguous adult/sexual terms. Lowercase, whitespace-free. Add only
    /// terms with no plausible innocent meaning in feed content.
    private static let blockedTerms: [String] = [
        // English
        "porn", "pornhub", "onlyfans", "nsfw", "xxx", "escortservice",
        "camgirl", "hookup", "sexcam", "sexchat", "sexvideo",
        "sextape", "nudes", "nudespics", "xxxvideo", "adultvideo",
        "deepfakeporn", "leakednudes",
        // CJK (spam observed on the default relays; written with or without spaces)
        "脚交", "口交", "援交", "约炮", "嫖娼", "卖淫", "自慰", "色情",
        "情色", "a片", "風俗", "アダルト", "無修正", "中出",
        // Cyrillic
        "проститутк", "порно", "эскорт", "сексвидео", "шлюх",
        // Spanish / Portuguese
        "putas", "escortsporno",
    ]

    /// True when the combined text passes the adult-content gate.
    /// `parts` are joined with spaces before normalization.
    static func isAllowed(_ parts: String...) -> Bool {
        var hay = parts.joined(separator: " ").lowercased()
        hay.removeAll { $0.isWhitespace }
        guard !hay.isEmpty else { return true }
        return !blockedTerms.contains { hay.contains($0) }
    }
}
