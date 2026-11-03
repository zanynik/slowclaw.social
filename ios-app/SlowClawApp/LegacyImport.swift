import Foundation
import SQLite3

/// One-time, read-only import of journals written by earlier SlowClaw builds
/// (Documents/slowclaw.sqlite, `memories` table). The old database and audio
/// files are left untouched on disk.
@MainActor
enum LegacyImport {
    private static let doneKey = "slowclaw.legacy-import.v1"
    private static let placeholder = "🎙 Audio journal — transcribing…"
    private static let softDeleteKey = "slowclaw.softdeleted"

    static func runIfNeeded(store: Store) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = docs.appendingPathComponent("slowclaw.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        do {
            let journals = try read(path: path)
            _ = store.importLegacy(journals)
            store.saveNow()
            UserDefaults.standard.set(true, forKey: doneKey)
        } catch {
            store.loadError = "Older journals could not be imported yet: \(error.localizedDescription)"
        }
    }

    private struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func read(path: String) throws -> [Journal] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ImportError(message: "Could not open the old journal database.")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT key, content, category, created_at, updated_at, session_id, source, media_url
        FROM memories
        WHERE category NOT IN ('deleted', 'question_threads')
          AND (session_id IS NULL OR session_id NOT IN ('drafts', 'app_metadata'))
          AND key <> 'question_threads_v1'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError(message: "The old journal database has an unexpected format.")
        }
        defer { sqlite3_finalize(stmt) }

        func column(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        let softDeleted = UserDefaults.standard.dictionary(forKey: softDeleteKey) ?? [:]
        var out: [Journal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let key = column(0), let content = column(1) else { continue }
            if softDeleted[key] != nil { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let media = column(7)
            if trimmed.isEmpty && media == nil { continue }

            let (title, body) = splitTitle(content)
            let created = parseDate(column(3)) ?? epochFromKey(key) ?? Date()
            let updated = parseDate(column(4)) ?? created
            let pending = body.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder
                || title.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder
            let hasAudio = media.flatMap { AudioRecorder.absoluteURL(forMediaRelativePath: $0) }
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false

            var j = Journal(id: key, title: title == placeholder ? "" : title,
                            body: pending ? "" : body, transcript: nil,
                            audioPath: hasAudio ? media : nil, spaceID: nil,
                            createdAt: created, updatedAt: updated,
                            status: .ready, organized: false, deleted: false, dirty: true)
            if pending {
                // Only re-queue if the audio still exists; otherwise keep an empty entry out.
                guard hasAudio else { continue }
                j.status = .transcribing
            }
            out.append(j)
        }
        return out
    }

    /// Old builds stored "Title\n\nBody". Single-paragraph entries have no separate title.
    private static func splitTitle(_ content: String) -> (String, String) {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard lines.count > 1, let first = lines.first, first.count <= 120 else {
            return ("", content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (first.trimmingCharacters(in: .whitespaces), body)
    }

    private static func epochFromKey(_ key: String) -> Date? {
        guard let raw = key.split(separator: "_").last, let value = Double(raw), value > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = CloudDates.parse(raw) { return d }
        if let v = Double(raw), v > 1_000_000_000 { return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}
