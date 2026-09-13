import Foundation

/// Conservative admission to the personal reading surface, independent of
/// freshness/popularity scores. Similarity is a heuristic, not a probability.
enum ReadsRelevance {
    static func accepts(title: String, summary: String, similarity: Double?, journalTopics: [[String]]) -> Bool {
        if let similarity, similarity.isFinite, similarity >= 0.65 { return true }
        let text = " " + normalized(title + " " + summary) + " "
        // Two distinct topics from the same journal reduce broad one-word
        // coincidences, including when sentence embeddings are unavailable.
        return journalTopics.contains { topics in
            Set(topics.map(normalized))
                .filter { topic in
                    guard topic.count >= 3 else { return false }
                    return text.contains(" " + topic + " ")
                }.count >= 2
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
