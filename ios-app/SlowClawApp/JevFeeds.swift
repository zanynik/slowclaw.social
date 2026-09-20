import Foundation

/// Weekly source decisions are separate from article admission. A selected
/// feed only earns a fetch; every article still needs its own memory match.
enum JevFeeds {
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    struct Decision: Codable {
        let score: Double
        let passageID: String
        let checkedAt: Date
        func selected(activePassages: Set<String>) -> Bool {
            score.isFinite && (JevMemory.threshold...1).contains(score)
                && activePassages.contains(passageID)
        }
        func needsRefresh(activePassages: Set<String>, now: Date = Date()) -> Bool {
            now.timeIntervalSince(checkedAt) >= JevFeeds.interval
                || now < checkedAt || !activePassages.contains(passageID)
        }
    }
    struct Cache: Codable {
        var decisions: [String: Decision] = [:]
        static var url: URL {
            JevMemory.Cache.url.deletingLastPathComponent().appendingPathComponent("jev-feeds-v1.json")
        }
        static func load() -> Cache {
            (try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))) ?? Cache()
        }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }

    /// Reserve candidate space, not visible feed space. Platform quotas never
    /// bypass Jev. Interleave so video/social also get judged early in a scan.
    static func candidates(_ items: [RankedFeedItem]) -> [RankedFeedItem] {
        let groups = ["rss", "youtube", "nostr"]
        let budgets = [40, 20, 20]
        var queues: [[RankedFeedItem]] = []
        var seen = Set<String>()
        for (index, platform) in groups.enumerated() {
            let sorted = items.filter { platform == "rss" ? !["youtube", "nostr"].contains($0.sourcePlatform) : $0.sourcePlatform == platform }
                .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            var counts: [String: Int] = [:]
            queues.append(Array(sorted.filter { item in
                let cap = platform == "nostr" ? 10 : 5
                guard counts[item.sourceLabel, default: 0] < cap,
                      seen.insert(item.link.isEmpty ? item.id : item.link).inserted else { return false }
                counts[item.sourceLabel, default: 0] += 1
                return true
            }.prefix(budgets[index])))
        }
        var result: [RankedFeedItem] = []
        for offset in 0..<(queues.map(\.count).max() ?? 0) {
            for queue in queues where offset < queue.count { result.append(queue[offset]) }
        }
        return result
    }
}
