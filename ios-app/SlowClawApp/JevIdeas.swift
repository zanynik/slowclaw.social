import Foundation

enum JevIdeas {
    static let version = "jev-sharing-v1"
    struct Decision: Codable {
        let id: String
        let score: Double
        let privateScore: Double
        var valid: Bool { score.isFinite && privateScore.isFinite && (0...1).contains(score) && (0...1).contains(privateScore) }
        var suggested: Bool { valid && score >= 0.7 && privateScore < 0.3 }
    }
    struct Cache: Codable {
        var version = JevIdeas.version
        var decisions: [String: Decision] = [:]
        private static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jev-ideas-v1.json")
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
