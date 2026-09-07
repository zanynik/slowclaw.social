import Foundation

/// Persistence policy, independent of the speech engine. Recognition must
/// never silently discard newer edits or replace a transcript with less text.
enum TranscriptSafety {
    static func canReplace(original: String, current: String, candidate: String) -> Bool {
        let result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return original == current && !result.isEmpty && result.count >= current.count
    }
}
