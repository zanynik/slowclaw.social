import Foundation

enum DraftBudget {
    /// Original passages, shared fairly across sources. No model summaries.
    /// UTF-8 bounds also keep non-Latin journals from ballooning the prompt.
    static func source(_ texts: [String], miniCPM: Bool) -> String {
        let selected = Array(texts.prefix(3))
        guard !selected.isEmpty else { return "" }
        let perSource = (miniCPM ? 6000 : 1600) / selected.count
        return selected.enumerated().map { index, text in
            "Journal \(index + 1):\n" + passages(text, bytes: perSource)
        }.joined(separator: "\n\n")
    }

    static func passages(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let chars = Array(text)
        let third = max(0, (bytes - 40) / 3)
        func prefix(_ value: ArraySlice<Character>) -> String {
            var result = "", count = 0
            for c in value {
                let size = String(c).utf8.count
                if count + size > third { break }
                result.append(c); count += size
            }
            return result
        }
        let start = prefix(chars[...])
        let middle = prefix(chars[(chars.count / 2)...])
        let end = String(prefix(Array(chars.reversed())[...]).reversed())
        return start + "\n[passage omitted]\n" + middle + "\n[passage omitted]\n" + end
    }

    /// Hard bound even when a transcript has no paragraph breaks.
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return stride(from: 0, to: chars.count, by: limit).map {
            String(chars[$0..<min($0 + limit, chars.count)])
        }
    }
}
