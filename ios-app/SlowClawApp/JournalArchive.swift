import Foundation

/// A separate connection confines archive reads to this actor rather than
/// sharing the UI's SQLite handle across threads.
actor JournalArchive {
    static let shared = JournalArchive()
    private var memory: SlowClawSqliteMemory?
    func page(before: Int64) throws -> (entries: [SlowClawMemoryEntry], next: Int64) {
        if memory == nil {
            guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw PublishingError.message("Journal storage is unavailable.")
            }
            memory = try SlowClawSqliteMemory(path: directory.appendingPathComponent("slowclaw.sqlite").path, embedder: false)
        }
        return try memory!.archivePage(before: before)
    }
}
