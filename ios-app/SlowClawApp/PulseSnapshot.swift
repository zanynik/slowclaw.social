import Foundation

/// A bounded, protected last-successful timeline, independent of pending work.
enum PulseSnapshot {
    struct Saved: Codable { let version: Int; let items: [RankedFeedItem] }
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pulse-ranked-v1.json")
    }
    static func decode(_ data: Data) -> [RankedFeedItem] {
        guard data.count <= 4_000_000,
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == 1,
              saved.items.count <= 40,
              saved.items.allSatisfy({ $0.sourceLabel == "Nostr posts" && $0.id.hasPrefix("nostr:") }),
              Set(saved.items.map(\.id)).count == saved.items.count else { return [] }
        return saved.items
    }
    static func load() -> [RankedFeedItem] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4_000_000, let data = try? Data(contentsOf: file) else { return [] }
        return decode(data)
    }
    static func save(_ items: [RankedFeedItem]) throws {
        let data = try JSONEncoder().encode(Saved(version: 1, items: Array(items.prefix(40))))
        guard data.count <= 4_000_000 else { throw CocoaError(.fileWriteFileTooLarge) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
