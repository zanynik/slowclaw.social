import Foundation
import NaturalLanguage

struct SemanticMatch: Codable, Sendable {
    let journalKey: String
    let similarity: Double
    let ageDays: Double
}

struct SemanticSource: Sendable {
    let key: String
    let text: String
    let date: Date
}

/// Apple's language models stay on this off-main serial actor. Geometry is
/// language-specific; never compare vectors from different embedding spaces.
actor SemanticMemory {
    static let shared = SemanticMemory()
    private struct Vector {
        let language: NLLanguage
        let values: [Double]
    }
    private var models: [NLLanguage: NLEmbedding] = [:]
    private var cache: [String: Vector] = [:]

    /// Hybrid personal-context/evidence retrieval. Exact-word fallback works
    /// without language assets; old sources retain their relevance.
    func retrieve(query: String, documents: [ContextDocument], limit: Int = 5,
                  shouldPause: @MainActor @Sendable () -> Bool) async -> [String] {
        defer { cache.removeAll(keepingCapacity: false) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let queryVector = vector(query)
        var scored: [(String, Double)] = []
        for document in documents.prefix(128) {
            if Task.isCancelled { return [] }
            if await shouldPause() { return [] }
            var similarity = 0.0
            if let a = queryVector, let b = vector(document.title + " " + document.text),
               a.language == b.language, a.values.count == b.values.count {
                var dot = 0.0, normA = 0.0, normB = 0.0
                for (x, y) in zip(a.values, b.values) { dot += x * y; normA += x * x; normB += y * y }
                if normA > 0 && normB > 0 { similarity = dot / sqrt(normA * normB) }
            }
            let lexical = ContextTools.lexicalMatch(query: query, text: document.title + " " + document.text)
            let score = slowclaw_feed_context_score(lexical, similarity)
            if score >= 0.12 { scored.append((document.id, score)) }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(max(0, min(limit, 8))).map(\.0)
    }

    private func vector(_ text: String) -> Vector? {
        let bounded = String(text.prefix(900))
        if let existing = cache[bounded] { return existing }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: bounded) else { return nil }
        if models[language] == nil { models[language] = NLEmbedding.sentenceEmbedding(for: language) }
        guard let values = models[language]?.vector(for: bounded),
              !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let result = Vector(language: language, values: values)
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[bounded] = result
        return result
    }

    func matches(items: [(String, String)], sources: [SemanticSource], shouldPause: @MainActor @Sendable () -> Bool) async -> [String: SemanticMatch] {
        defer { cache.removeAll(keepingCapacity: false) }
        var vectors: [(SemanticSource, Vector)] = []
        for source in sources.prefix(48) {
            if Task.isCancelled { return [:] }
            if await shouldPause() { return [:] }
            if let v = vector(source.text) { vectors.append((source, v)) }
        }
        var result: [String: SemanticMatch] = [:]
        for (id, text) in items.prefix(120) {
            if Task.isCancelled { return [:] }
            if await shouldPause() { return [:] }
            guard let item = vector(text) else { continue }
            var strongest = 0.0
            for (source, journal) in vectors where journal.language == item.language && journal.values.count == item.values.count {
                var dot = 0.0, normA = 0.0, normB = 0.0
                for (a, b) in zip(item.values, journal.values) { dot += a * b; normA += a * a; normB += b * b }
                guard normA > 0, normB > 0 else { continue }
                let similarity = dot / sqrt(normA * normB)
                let age = max(0, Date().timeIntervalSince(source.date) / 86_400)
                let boost = slowclaw_feed_semantic_score(0, similarity, age)
                if boost > strongest {
                    strongest = boost
                    result[id] = SemanticMatch(journalKey: source.key, similarity: similarity, ageDays: age)
                }
            }
        }
        // Private source text and vectors aren't retained after a pass; the
        // editable persisted memory is the only source of future matching.
        return result
    }
}
