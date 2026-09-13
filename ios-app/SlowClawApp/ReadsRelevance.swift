import Foundation

/// Conservative admission to the personal reading surface, independent of
/// freshness/popularity scores. Similarity is a heuristic, not a probability.
enum ReadsRelevance {
    static func accepts(title: String, summary: String, similarity: Double?, journalTopics: [[String]]) -> Bool {
        accepts(title: title, summary: summary, similarity: similarity, preparedJournalTopics: prepare(journalTopics))
    }

    static func prepare(_ journalTopics: [[String]]) -> [[String]] {
        journalTopics.map { Array(Set($0.map(normalized).filter { $0.count >= 3 })) }
            .filter { $0.count >= 2 }
    }

    static func accepts(title: String, summary: String, similarity: Double?, preparedJournalTopics: [[String]]) -> Bool {
        if let similarity, similarity.isFinite, similarity >= 0.65 { return true }
        let text = " " + normalized(title + " " + summary) + " "
        // Two distinct topics from the same journal reduce broad one-word
        // coincidences, including when sentence embeddings are unavailable.
        return preparedJournalTopics.contains { topics in
            var count = 0
            for topic in topics where text.contains(" " + topic + " ") {
                count += 1
                if count == 2 { return true }
            }
            return false
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
