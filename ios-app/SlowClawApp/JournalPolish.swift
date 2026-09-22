import Foundation

/// A reversible display projection. Never writes over the source transcript.
/// Deliberately leaves ambiguous repetitions ("very very", "no, no") alone.
enum TranscriptCleanup {
    static func clean(_ original: String) -> String {
        // Quoted speech and non-English words are left intact. Only obvious
        // hesitation tokens at sentence/clause boundaries are removed.
        var text = original.replacingOccurrences(
            of: #"(?im)(^|[.!?]\s+|,\s+)(?:(?:uh+|um+|hmm+)[,\s]+)+(?=\p{L})"#,
            with: "$1", options: .regularExpression)
        // An explicit false start, not ordinary emphatic repetition.
        text = text.replacingOccurrences(of: #"(?i)\b(I|we|the|it|but)-\s*\1\b"#,
                                        with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" +([,.!?])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return original }
        // Speech normally supplies punctuation. Do not guess clause boundaries.
        if let last = text.last, last.isLetter || last.isNumber { text += "." }
        if !text.contains("\n") {
            text = text.replacingOccurrences(
                of: #"((?:[^.!?]+[.!?]+\s+){2}[^.!?]+[.!?]+)\s+(?=\p{Lu})"#,
                with: "$1\n\n", options: .regularExpression)
        }
        return text
    }
}

enum DraftInboxState: String, CaseIterable, Identifiable {
    case new = "New", kept = "Kept", published = "Published", archived = "Archived"
    var id: String { rawValue }
}

/// Metadata only; draft text remains in the existing SQLite drafts session.
enum DraftInbox {
    static let key = "slowclaw.draft-inbox.v1"
    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    static func state(for key: String, states: [String: String], confirmed: Bool) -> DraftInboxState {
        if states[key] == DraftInboxState.archived.rawValue { return .archived }
        if confirmed { return .published }
        // A local label can never manufacture a successful publication.
        return states[key] == DraftInboxState.kept.rawValue ? .kept : .new
    }
}

/// Bounded, UTF-8-only import; filenames are not treated as trusted paths.
enum JournalTextImport {
    static let maximumBytes = 1_000_000
    static let maximumFiles = 100
    static func decode(_ data: Data) -> String? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else { return nil }
        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}
