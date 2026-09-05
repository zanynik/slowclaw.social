import Foundation

enum DraftBudget {
    /// Hard bound even when a transcript has no paragraph breaks.
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return stride(from: 0, to: chars.count, by: limit).map {
            String(chars[$0..<min($0 + limit, chars.count)])
        }
    }
}
