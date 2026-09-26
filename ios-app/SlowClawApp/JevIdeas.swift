import Foundation

enum JevIdeas {
    static let version = "jev-sharing-v2"
    struct Decision: Codable {
        let id: String
        let score: Double
        let privateScore: Double
        let standalone: Double
        let quote: Double
        var valid: Bool { [score, privateScore, standalone, quote].allSatisfy { $0.isFinite && (0...1).contains($0) } }
        var suggested: Bool { valid && score >= 0.7 && privateScore < 0.3 && standalone >= 0.6 }
        var shareableQuote: Bool { suggested && quote >= 0.7 }
    }
    struct Cache: Codable {
        var version = JevIdeas.version
        var decisions: [String: Decision] = [:]
        private static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jev-ideas-v2.json")
        }
        static func load() -> Cache {
            guard let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: url)),
                  cache.version == JevIdeas.version,
                  cache.decisions.allSatisfy({ $0.key == $0.value.id && $0.value.valid }) else { return Cache() }
            return cache
        }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }
    static func select(_ passages: [JevMemory.Passage], decisions: [String: Decision]) -> [JevMemory.Passage] {
        passages.filter { decisions[$0.id]?.suggested == true }.sorted {
            let left = decisions[$0.id]?.score ?? 0, right = decisions[$1.id]?.score ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
