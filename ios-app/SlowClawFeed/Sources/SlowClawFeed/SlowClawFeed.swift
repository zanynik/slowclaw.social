// SlowClawFeed.swift — idiomatic Swift wrapper over the slowclaw_feed C ABI.
//
// This file turns the (pointer, length) C interface into Swift types that
// feel native: String instead of (UnsafePointer<UInt8>, count), throws
// instead of int32 status codes, etc. Swift consumers should use these
// types exclusively and never touch the C functions directly.

import Foundation

/// Errors thrown by the SlowClawFeed wrapper.
public enum SlowClawFeedError: Error, Equatable {
    case openFailed(String)
    case storeFailed(String)
    case getFailed(String)
    case recallFailed(String)
    case forgetFailed(String)
    case invalidArgument(String)
    case outOfMemory
    case internalError(String)
    case unexpectedStatus(Int32)
}

/// A stored memory entry.
public struct SlowClawMemoryEntry: Equatable {
    public let id: String
    public let key: String
    public let content: String
    public let category: String
    public let timestamp: String
    public let sessionID: String?
    public let score: Double?

    public init(id: String, key: String, content: String, category: String,
                timestamp: String, sessionID: String?, score: Double?) {
        self.id = id
        self.key = key
        self.content = content
        self.category = category
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.score = score
    }
}

/// Memory category tags. Matches the Rust enum's lowercase string form.
public enum SlowClawMemoryCategory: String, CaseIterable {
    case core
    case daily
    case conversation
    // Custom categories are supported by passing a raw String to the store API.
}

/// A SQLite-backed memory store. One instance owns one database connection.
/// Not thread-safe; serialize access from a single dispatch queue.
public final class SlowClawSqliteMemory {

    /// The underlying opaque handle. Nil after `close()`.
    private var handle: OpaquePointer?
    /// Optional owned embedder handle (when opened with one).
    private var embedderHandle: OpaquePointer?

    /// Open (or create) a SQLite DB at `path`. Pass ":memory:" for an
    /// in-memory DB. Pass `embedder: true` to enable hybrid vector+keyword
    /// recall via the deterministic HashEmbedder.
    public init(path: String, embedder: Bool = false) throws {
        if embedder {
            let model = "slowclaw-default"
            guard let emb = model.withCString({ modelPtr in
                slowclaw_feed_hash_embedder_new(modelPtr, model.utf8.count, 384)
            }) else {
                throw SlowClawFeedError.openFailed("hash_embedder_new returned null")
            }
            self.embedderHandle = emb
        }
        let embParam = embedderHandle
        guard let h = path.withCString({ pathPtr in
            slowclaw_feed_sqlite_open(pathPtr, path.utf8.count, embParam)
        }) else {
            if let emb = embedderHandle { slowclaw_feed_hash_embedder_free(emb) }
            throw SlowClawFeedError.openFailed("sqlite_open returned null for path: \(path)")
        }
        self.handle = h
    }

    deinit {
        close()
    }

    public func close() {
        if let h = handle {
            slowclaw_feed_sqlite_close(h)
            handle = nil
        }
        if let emb = embedderHandle {
            slowclaw_feed_hash_embedder_free(emb)
            embedderHandle = nil
        }
    }

    public func healthCheck() -> Bool {
        guard let h = handle else { return false }
        return slowclaw_feed_sqlite_health(h)
    }

    /// Insert or upsert a memory. Custom categories pass through verbatim.
    public func store(key: String, content: String, category: String,
                      sessionID: String? = nil) throws {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let status = key.withCString { keyPtr in
            content.withCString { contentPtr in
                category.withCString { catPtr in
                    if let sid = sessionID {
                        return sid.withCString { sidPtr in
                            slowclaw_feed_sqlite_store(h, keyPtr, key.utf8.count,
                                                       contentPtr, content.utf8.count,
                                                       catPtr, category.utf8.count,
                                                       sidPtr, sid.utf8.count)
                        }
                    } else {
                        return slowclaw_feed_sqlite_store(h, keyPtr, key.utf8.count,
                                                          contentPtr, content.utf8.count,
                                                          catPtr, category.utf8.count,
                                                          nil, 0)
                    }
                }
            }
        }
        if status != SLOWCLAW_OK {
            throw SlowClawFeedError.storeFailed("store returned status \(status)")
        }
    }

    /// Convenience overload using the typed category enum.
    public func store(key: String, content: String, category: SlowClawMemoryCategory,
                      sessionID: String? = nil) throws {
        try store(key: key, content: content, category: category.rawValue, sessionID: sessionID)
    }

    /// Fetch a memory by key. Returns nil if not found.
    public func get(key: String) throws -> SlowClawMemoryEntry? {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        var entry = SlowclawSqliteEntry()
        let status = key.withCString { keyPtr in
            slowclaw_feed_sqlite_get(h, keyPtr, key.utf8.count, &entry)
        }
        defer { slowclaw_feed_sqlite_entry_free(&entry) }
        switch status {
        case SLOWCLAW_OK:
            return entryToSwift(entry)
        case 1:
            return nil
        default:
            throw SlowClawFeedError.getFailed("get returned status \(status)")
        }
    }

    /// Delete a memory by key. Returns true if removed, false if not found.
    @discardableResult
    public func forget(key: String) throws -> Bool {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let status = key.withCString { keyPtr in
            slowclaw_feed_sqlite_forget(h, keyPtr, key.utf8.count)
        }
        switch status {
        case 1: return true
        case 0: return false
        default: throw SlowClawFeedError.forgetFailed("forget returned status \(status)")
        }
    }

    /// Count stored memories.
    public func count() throws -> Int {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let n = slowclaw_feed_sqlite_count(h)
        if n < 0 { throw SlowClawFeedError.internalError("count returned \(n)") }
        return Int(n)
    }

    /// Hybrid recall (FTS5 keyword + vector similarity if embedder is set).
    /// Returns matching entries ordered by relevance.
    public func recall(query: String, limit: Int = 10, sessionID: String? = nil) throws -> [SlowClawMemoryEntry] {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        var result = SlowclawRankResult()
        let status = query.withCString { qPtr in
            if let sid = sessionID {
                return sid.withCString { sidPtr in
                    slowclaw_feed_sqlite_recall(h, qPtr, query.utf8.count, limit,
                                                sidPtr, sid.utf8.count, &result)
                }
            } else {
                return slowclaw_feed_sqlite_recall(h, qPtr, query.utf8.count, limit,
                                                   nil, 0, &result)
            }
        }
        if status != SLOWCLAW_OK {
            throw SlowClawFeedError.recallFailed("recall returned status \(status)")
        }
        defer { slowclaw_feed_sqlite_result_free(&result) }
        // The result's items_json is a JSON array of full entries. Decode it.
        guard let bytes = result.items_json.bytes else { return [] }
        let len = result.items_json.len
        let data = Data(bytes: bytes, count: len)
        do {
            let decoded = try JSONDecoder().decode([MemoryEntryDTO].self, from: data)
            return decoded.map { $0.toSwift() }
        } catch {
            throw SlowClawFeedError.recallFailed("JSON decode failed: \(error)")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private func entryToSwift(_ entry: SlowclawSqliteEntry) -> SlowClawMemoryEntry {
        let id = stringFromSlowclaw(entry.id)
        let key = stringFromSlowclaw(entry.key)
        let content = stringFromSlowclaw(entry.content)
        let category = stringFromSlowclaw(entry.category)
        let timestamp = stringFromSlowclaw(entry.timestamp)
        let sessionID: String? = entry.session_id.bytes.map { _ in stringFromSlowclaw(entry.session_id) }
        let score = entry.score.isNaN ? nil : entry.score
        return SlowClawMemoryEntry(id: id, key: key, content: content, category: category,
                                   timestamp: timestamp, sessionID: sessionID, score: score)
    }

    private func stringFromSlowclaw(_ s: SlowclawString) -> String {
        guard let bytes = s.bytes, s.len > 0 else { return "" }
        return String(bytes: Data(bytes: bytes, count: s.len), encoding: .utf8) ?? ""
    }
}

// ──────────────────────────────────────────────────────────────────────────
// JSON DTO for the recall result (matches the schema produced by ffi.zig's
// serializeEntriesFull).
// ──────────────────────────────────────────────────────────────────────────

private struct MemoryEntryDTO: Decodable {
    let id: String
    let key: String
    let content: String
    let category: String
    let timestamp: String
    let session_id: String?
    let score: Double?

    func toSwift() -> SlowClawMemoryEntry {
        return SlowClawMemoryEntry(id: id, key: key, content: content,
                                   category: category, timestamp: timestamp,
                                   sessionID: session_id, score: score)
    }
}
