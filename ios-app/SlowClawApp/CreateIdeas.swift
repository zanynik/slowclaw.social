import Foundation

/// Local candidate windows, batched classification, and a durable feed. Jev
/// judges exact source text; it never invents a quotation or an audio boundary.
enum CreateIdeas {
    static let version = "create-segments-v1"
    struct Candidate: Codable, Identifiable, Sendable {
        let id: String
        let key: String
        let fingerprint: String
        let text: String
        let timingID: String?
        let first: Int?
        let last: Int?
        let start: Double?
        let end: Double?
        var duration: Double? { guard let start, let end else { return nil }; return end - start }
        var passage: JevMemory.Passage { .init(id: id, sourceKey: key, text: text, category: "insight", score: 0) }
    }
    struct Cache: Codable {
        var version = CreateIdeas.version
        var candidates: [Candidate] = []
        var decisions: [String: JevIdeas.Decision] = [:]
        var dismissed: Set<String> = []
        private static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("create-segments-v1.json") }
        static func load() -> Cache {
            guard let value = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)), value.version == CreateIdeas.version,
                  value.candidates.count <= 600, value.decisions.allSatisfy({ $0.key == $0.value.id && $0.value.valid }) else { return .init() }
            return value
        }
        mutating func reconcile(_ current: [Candidate]) {
            candidates = Array(current.prefix(600))
            let active = Set(candidates.map(\.id))
            decisions = decisions.filter { active.contains($0.key) }
            dismissed.formIntersection(active)
        }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }
    static func timingID(_ transcript: TimedTranscript) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return JevBatch.digest(String(data: (try? encoder.encode(transcript)) ?? Data(), encoding: .utf8) ?? "")
    }
    static func candidates(key: String, content: String, body: String, timing: TimedTranscript?) -> [Candidate] {
        let fingerprint = JevBatch.digest(content)
        let identity = timing.map(timingID)
        func make(_ text: String, first: Int? = nil, last: Int? = nil) -> Candidate {
            .init(id: JevBatch.digest(version + key + fingerprint + (identity ?? "") + "\(first ?? -1):\(last ?? -1):" + text),
                  key: key, fingerprint: fingerprint, text: text, timingID: identity, first: first, last: last,
                  start: first.flatMap { timing?.words[$0].start }, end: last.flatMap { timing?.words[$0].end })
        }
        guard let timing, timing.valid else {
            return JevMemory.chunks(body, maximum: 550).filter { $0.split(whereSeparator: \.isWhitespace).count >= 5 }
                .prefix(100).map { make($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        // Sentence ends and real pauses are natural cut points. Hard bounds
        // keep even unpunctuated dictation within a readable, shareable length.
        var ranges: [ClosedRange<Int>] = [], first = 0, characters = 0
        for i in timing.words.indices {
            let word = timing.words[i]; characters += word.text.count + 1
            let seconds = word.end - timing.words[first].start
            let sentence = word.text.last.map { ".!?。！？".contains($0) } ?? false
            let pause = i + 1 < timing.words.count && timing.words[i + 1].start - word.end >= 0.8
            if characters >= 500 || seconds >= 28 || ((sentence || pause) && characters >= 100) || i == timing.words.count - 1 {
                ranges.append(first...i); first = i + 1; characters = 0
            }
        }
        var result: [Candidate] = []
        for (index, range) in ranges.enumerated() {
            for end in [index, index + 1] where end < ranges.count {
                let last = ranges[end].upperBound
                let words = timing.words[range.lowerBound...last]
                let text = words.map(\.text).joined(separator: " ")
                guard words.count >= 5, text.count <= 1400, text.utf16.count <= 3500, text.utf8.count <= 12000, let tail = words.last, let head = words.first,
                      tail.end - head.start <= 75 else { continue }
                result.append(make(text, first: range.lowerBound, last: last))
            }
        }
        return Array(result.prefix(100))
    }
    static func selected(_ cache: Cache) -> [Candidate] {
        let ranked = cache.candidates.filter { item in
            guard !cache.dismissed.contains(item.id), let decision = cache.decisions[item.id], decision.suggested else { return false }
            return item.timingID != nil || (decision.shareableQuote && item.text.count <= 600)
        }.sorted {
            let left = cache.decisions[$0.id]!.score, right = cache.decisions[$1.id]!.score
            return left == right ? $0.id < $1.id : left > right
        }
        var result: [Candidate] = []
        for item in ranked {
            guard result.filter({ $0.key == item.key }).count < 3,
                  !result.contains(where: { existing in
                      if existing.text == item.text { return true }
                      guard existing.key == item.key, let a = existing.first, let b = existing.last, let c = item.first, let d = item.last else { return false }
                      return max(a, c) <= min(b, d)
                  }) else { continue }
            result.append(item)
            if result.count == 24 { break }
        }
        return result
    }
    static func batches(_ items: [Candidate]) -> [[Candidate]] {
        // Existing endpoint evaluates six questions per segment, at most 12
        // segments. Also bound JSON bytes for Unicode and escaping.
        var batches: [[Candidate]] = [], current: [Candidate] = [], bytes = 0
        for item in items {
            let size = (try? JSONEncoder().encode(item.passage))?.count ?? 10000
            if !current.isEmpty && (current.count == 12 || bytes + size > 18000) { batches.append(current); current = []; bytes = 0 }
            current.append(item); bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
