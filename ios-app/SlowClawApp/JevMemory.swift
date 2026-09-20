import Foundation

/// Source excerpts only. Classification never supplies replacement prose.
enum JevMemory {
    static let version = "jev-memory-v1"
    static let threshold = 0.7
    struct Answer: Codable, Sendable {
        let category: String
        let score: Double
        let version: String
        var valid: Bool { ["routine", "context", "insight"].contains(category) && score.isFinite && (0...1).contains(score) && version == JevMemory.version }
        var useful: Bool { valid && category != "routine" && score >= JevMemory.threshold }
    }
    struct Passage: Codable, Identifiable, Sendable {
        let id: String
        let sourceKey: String
        let text: String
        let category: String
        let score: Double
    }
    struct Record: Codable, Sendable {
        let fingerprint: String
        let version: String
        let passages: [Passage]
    }
    struct Cache: Codable {
        var records: [String: Record] = [:]
        var dismissed: Set<String> = []
        static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jev-memory.json")
        }
        static func load() -> Cache { (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))) ?? Cache() }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }
    /// Split near sentence/paragraph boundaries, falling back to whitespace.
    /// Slices preserve the source exactly, including Unicode and punctuation.
    static func split(_ text: String, near target: Int) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return [text] }
        let center = min(max(1, target), chars.count - 1)
        let radius = min(160, max(1, chars.count / 4))
        let lo = max(1, center - radius), hi = min(chars.count - 1, center + radius)
        let candidates = Array(lo...hi).sorted { abs($0-center) < abs($1-center) }
        let boundary = candidates.first { chars[$0-1] == "\n" || (".!?。！？".contains(chars[$0-1]) && chars[$0].isWhitespace) }
            ?? candidates.first { chars[$0].isWhitespace } ?? center
        return [String(chars[..<boundary]), String(chars[boundary...])]
    }
    static func chunks(_ text: String, maximum: Int = 1200) -> [String] {
        precondition(maximum >= 2)
        guard text.utf16.count > maximum else { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [text] }
        if text.count == 1 {
            var result: [String] = [], piece = ""
            for scalar in text.unicodeScalars {
                let next = String(scalar)
                if piece.utf16.count + next.utf16.count > maximum { result.append(piece); piece = "" }
                piece += next
            }
            if !piece.isEmpty { result.append(piece) }
            return result
        }
        let target = max(1, Int(Double(text.count) * Double(maximum - min(160, maximum / 4)) / Double(text.utf16.count)))
        let parts = split(text, near: target)
        return parts.flatMap { chunks($0, maximum: maximum) }
    }
}
