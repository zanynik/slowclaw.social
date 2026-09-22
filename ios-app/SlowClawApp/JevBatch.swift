import Foundation
import CryptoKit

/// One fixed classifier question per candidate, sharing a small persona state.
enum JevBatch {
    static let version = "jev-persona-relevance-v1"
    static let limit = 32
    // Experimental admission floor, not a calibrated probability.
    static let threshold = 0.55
    struct Interest: Codable, Equatable { let topic: String; let weight: Double }
    struct Candidate: Codable { let id: String; let text: String }
    struct Score: Codable {
        let id: String
        let score: Double
        var valid: Bool { score.isFinite && (0...1).contains(score) }
    }
    static func profile(_ weights: [Double]) -> [Interest] {
        guard weights.count == JevPersona.topics.count, weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [] }
        let selected = weights.indices.filter { weights[$0] > 0 }.sorted {
            weights[$0] == weights[$1] ? $0 < $1 : weights[$0] > weights[$1]
        }.prefix(15)
        let total = selected.reduce(0) { $0 + weights[$1] }
        guard total.isFinite, total > 0 else { return [] }
        return selected.compactMap { i in
            let weight = (weights[i] / total * 1000).rounded() / 1000
            return weight > 0 ? Interest(topic: JevPersona.topics[i], weight: weight) : nil
        }
    }
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func profileID(_ interests: [Interest]) -> String {
        digest(version + interests.map { "\($0.topic):\($0.weight)" }.joined(separator: "\n"))
    }
    /// Word and byte bounds both matter: unspaced/combining Unicode is bounded.
    static func excerpt(title: String, body: String) -> String {
        func bytes(_ text: String, limit: Int) -> String {
            var result = "", count = 0
            for scalar in text.unicodeScalars {
                let part = String(scalar)
                guard count + part.utf8.count <= limit else { break }
                result += part; count += part.utf8.count
            }
            return result
        }
        let heading = bytes(title, limit: 200)
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(100).joined(separator: " ")
        return bytes(heading + "\n" + words, limit: 1200).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Budget the twice-escaped candidate inside the provider question, not
    /// just the app JSON. Quotes/control characters can otherwise expand it.
    static func batches(_ items: [Candidate]) -> [[Candidate]] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var result: [[Candidate]] = [], current: [Candidate] = [], bytes = 0
        for item in items {
            let quoted = (try? encoder.encode(item.text)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let cost = ((try? encoder.encode(quoted))?.count ?? 10000) + 600
            if !current.isEmpty && (current.count == limit || bytes + cost > 54000) {
                result.append(current); current = []; bytes = 0
            }
            current.append(item); bytes += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    static func valid(_ scores: [Score], for items: [Candidate]) -> Bool {
        scores.count == items.count && Set(scores.map(\.id)).count == scores.count
            && Set(scores.map(\.id)) == Set(items.map(\.id)) && scores.allSatisfy(\.valid)
    }
    struct Cache: Codable {
        struct Entry: Codable { let score: Double; let date: Date }
        var version = JevBatch.version
        var profile = ""
        var entries: [String: Entry] = [:]
        func score(for id: String, profile expected: String, now: Date = Date()) -> Double? {
            guard version == JevBatch.version, profile == expected, let entry = entries[id],
                  entry.score.isFinite, (0...1).contains(entry.score),
                  (0..<(7 * 86400)).contains(now.timeIntervalSince(entry.date)) else { return nil }
            return entry.score
        }
        private static var file: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("jev-batch-relevance-v1.json")
        }
        static func load() -> Cache {
            guard let value = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: file)),
                  value.version == JevBatch.version, value.entries.count <= 300 else { return Cache() }
            return value
        }
        mutating func trim() {
            let keep = Set(entries.sorted { $0.value.date == $1.value.date ? $0.key < $1.key : $0.value.date > $1.value.date }.prefix(300).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic, .completeFileProtection])
        }
    }
}
