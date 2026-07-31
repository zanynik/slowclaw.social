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
        return String(data: Data(bytes: UnsafeRawPointer(bytes), count: s.len), encoding: .utf8) ?? ""
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

// MARK: - RSS Feed Parsing + Ranking

/// A ranked feed item returned by the Zig core.
///
/// `id` is a Swift-synthesized stable identifier — NOT the raw `link`. The Zig
/// core sets `FeedItem.id = guid ?? link` (`rss_parser.zig`), and real-world RSS
/// (HN, The Verge) routinely yields items with empty or duplicate links/guids.
/// SwiftUI's `ForEach` traps fatally on duplicate/empty `Identifiable` ids, so
/// `id` here is synthesized to be unique and never empty (see
/// `RankedFeedItemDTO.toRanked`). This is what makes the Reads list crash-safe.
public struct RankedFeedItem: Identifiable, Codable {
    public let id: String
    public let title: String
    public let link: String
    public let description: String
    public let sourceLabel: String
    public let score: Double
    public let readMinutes: Int
    /// "rss" | "youtube" | "nostr". Derived in Swift from the link (YouTube
    /// detection) or set by the fetcher (Nostr). The Zig ranker tags every RSS
    /// item "rss"; the Swift layer re-tags YouTube links, mirroring the
    /// reference app's toUnifiedFromWorldFeed.
    public let sourcePlatform: String
    /// Optional cover image (YouTube thumbnail or Nostr article image).
    public let thumbnailURL: String?

    public init(id: String, title: String, link: String, description: String,
                sourceLabel: String, score: Double, readMinutes: Int,
                sourcePlatform: String = "rss", thumbnailURL: String? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.description = description
        self.sourceLabel = sourceLabel
        self.score = score
        self.readMinutes = readMinutes
        self.sourcePlatform = sourcePlatform
        self.thumbnailURL = thumbnailURL
    }
}

/// Decodable mirror of the JSON `serializeRankedFeed` (ffi.zig) emits. The Zig
/// JSON never contains a guaranteed-unique id (it uses `link`), so we decode into
/// this DTO and then synthesize a crash-safe `RankedFeedItem.id`.
private struct RankedFeedItemDTO: Decodable {
    let title: String
    let link: String
    let description: String
    let sourceLabel: String
    let score: Double
    let readMinutes: Int

    enum CodingKeys: String, CodingKey {
        case title, link, description, sourceLabel, score, readMinutes
    }

    /// Build a crash-safe `RankedFeedItem`. Prefers `link` for identity; falls
    /// back to a stable hash of title+description+source when link is empty, and
    /// disambiguates collisions with the item's index in the batch. Also detects
    /// YouTube links (mirroring the reference's extractYouTubeId) and tags them
    /// sourcePlatform="youtube" with an i.ytimg.com thumbnail.
    func toRanked(index: Int) -> RankedFeedItem {
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeId: String
        if !trimmedLink.isEmpty {
            // Still append the index to guarantee uniqueness across feeds that
            // share a link (rare, but HN comment threads sometimes do).
            safeId = "l:\(trimmedLink)#\(index)"
        } else {
            // Deterministic fallback so the same item is stable across reloads.
            var hasher = Hasher()
            hasher.combine(title)
            hasher.combine(description)
            hasher.combine(sourceLabel)
            safeId = "h:\(hasher.finalize())#\(index)"
        }
        // YouTube detection (re-tag rss -> youtube, synthesize thumbnail).
        let ytID = SlowClawFeedSource.youTubeID(from: trimmedLink)
        let platform = (ytID != nil) ? "youtube" : "rss"
        let thumb = ytID.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" }
        return RankedFeedItem(
            id: safeId,
            title: title,
            link: trimmedLink,
            description: description,
            sourceLabel: sourceLabel,
            score: score,
            readMinutes: readMinutes,
            sourcePlatform: platform,
            thumbnailURL: thumb
        )
    }
}

/// Parse RSS XML and rank it by the user's interests. The XML is fetched by
/// Swift (via URLSession); the parsing + ranking happens in the Zig core.
public func slowClawParseAndRankRSS(
    xml: String,
    sourceLabel: String,
    topics: [SlowClawTopic] = []
) -> [RankedFeedItem]? {
    // Build topics JSON.
    let topicsJson: String?
    if topics.isEmpty {
        topicsJson = nil
    } else {
        let arr = topics.map { "{\"label\":\"\(escapeJson($0.label))\",\"weight\":\($0.weight)}" }.joined(separator: ",")
        topicsJson = "[\(arr)]"
    }

    var result = SlowclawRankResult()
    let nowEpoch = Date().timeIntervalSince1970

    let status: Int32
    if let tj = topicsJson {
        status = xml.withCString { xmlPtr in
            sourceLabel.withCString { srcPtr in
                tj.withCString { tjPtr in
                    slowclaw_feed_parse_and_rank(
                        xmlPtr, xml.utf8.count,
                        srcPtr, sourceLabel.utf8.count,
                        tjPtr, tj.utf8.count,
                        nowEpoch,
                        &result
                    )
                }
            }
        }
    } else {
        status = xml.withCString { xmlPtr in
            sourceLabel.withCString { srcPtr in
                slowclaw_feed_parse_and_rank(
                    xmlPtr, xml.utf8.count,
                    srcPtr, sourceLabel.utf8.count,
                    nil, 0,
                    nowEpoch,
                    &result
                )
            }
        }
    }

    guard status == SLOWCLAW_OK else { return nil }
    defer { slowclaw_feed_rank_result_free(&result) }

    guard let bytes = result.items_json.bytes else { return [] }
    let data = Data(bytes: UnsafeRawPointer(bytes), count: result.items_json.len)
    // Decode into the DTO, then synthesize crash-safe ids (see RankedFeedItemDTO).
    guard let dtos = try? JSONDecoder().decode([RankedFeedItemDTO].self, from: data) else {
        return nil
    }
    return dtos.enumerated().map { $0.element.toRanked(index: $0.offset) }
}

/// A topic for feed ranking (from the user's journal interests).
public struct SlowClawTopic {
    public let label: String
    public let weight: Double
    public init(label: String, weight: Double = 1.0) {
        self.label = label
        self.weight = weight
    }
}

// MARK: - Feed catalog

/// A default Reads feed source. Mirrors the Rust catalog
/// (src/gateway/feed_web_sources.rs) 1:1 — the same sources the reference app
/// reads. The iOS app fetches each `xmlURL` client-side and parses+ranks via
/// `slowClawParseAndRankRSS`.
public struct SlowClawFeedSource: Decodable, Equatable {
    public let title: String
    public let domain: String
    public let htmlURL: String
    public let xmlURL: String

    enum CodingKeys: String, CodingKey {
        case title, domain
        case htmlURL = "htmlUrl"
        case xmlURL = "xmlUrl"
    }

    /// Label shown in the Reads card source row. The catalog's YouTube entries
    /// are already prefixed "YouTube — …"; otherwise use the domain.
    public var displayLabel: String { title.isEmpty ? domain : title }

    /// Extract the 11-char YouTube video id from a watch/embed/shorts/live/v/
    /// education URL on youtube.com / youtube-nocookie.com / youtu.be.
    /// Mirrors the reference app's extractYouTubeId (web/src/lib/socialFeed.ts).
    /// Returns nil for non-YouTube URLs or unrecognized shapes.
    public static func youTubeID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let isYT = host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
        guard isYT else { return nil }
        let idPattern = "^[A-Za-z0-9_-]{11}$"
        if host == "youtu.be" {
            let seg = url.path.split(separator: "/").first.map(String.init) ?? ""
            return seg.range(of: idPattern, options: .regularExpression) != nil ? seg : nil
        }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value,
           v.range(of: idPattern, options: .regularExpression) != nil {
            return v
        }
        let segs = url.path.split(separator: "/").map(String.init)
        if segs.count >= 2, ["embed", "shorts", "live", "v", "education"].contains(segs[0]),
           segs[1].range(of: idPattern, options: .regularExpression) != nil {
            return segs[1]
        }
        return nil
    }
}

/// Return the default Reads feed catalog (114 sources). Nil on FFI/decode error.
public func slowClawFeedCatalog() -> [SlowClawFeedSource]? {
    var out = SlowclawString(bytes: nil, len: 0)
    let status = slowclaw_feed_catalog_json(&out)
    guard status == SLOWCLAW_OK, let bytes = out.bytes, out.len > 0 else {
        if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) }
        return nil
    }
    defer { if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) } }
    let data = Data(bytes: UnsafeRawPointer(bytes), count: out.len)
    return try? JSONDecoder().decode([SlowClawFeedSource].self, from: data)
}

// MARK: - On-device LLM (llama.cpp)

/// On-device LLM availability. The llama.cpp backend is not linked into the
/// build yet; `available` is false until it is.
public struct LocalLLMStatus: Decodable {
    public let available: Bool
    public let reason: String?
}

/// The two Gemma models the reference app offers for on-device download.
public struct LocalModelPreset: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String

    public static let presets: [LocalModelPreset] = [
        .init(id: "unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL",
              title: "Gemma 4 E2B (Q2_K_XL)",
              detail: "Smaller, faster. ~1.6 GB. Best for older devices."),
        .init(id: "unsloth/gemma-4-E2B-it-qat-UD-Q4_K_XL",
              title: "Gemma 4 E2B (Q4_K_XL)",
              detail: "Higher quality. ~2.2 GB. Best for iPhone 15 Pro+."),
    ]
}

/// Read on-device LLM status from the Zig core. Returns a not-available status
/// on any error (so callers can render safely).
public func slowClawLocalLLMStatus() -> LocalLLMStatus {
    var out = SlowclawString(bytes: nil, len: 0)
    let status = slowclaw_feed_local_llm_status(&out)
    guard status == SLOWCLAW_OK, let bytes = out.bytes, out.len > 0 else {
        if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) }
        return LocalLLMStatus(available: false, reason: "Status unavailable.")
    }
    defer { if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) } }
    let data = Data(bytes: UnsafeRawPointer(bytes), count: out.len)
    return (try? JSONDecoder().decode(LocalLLMStatus.self, from: data))
        ?? LocalLLMStatus(available: false, reason: "Status decode failed.")
}

private func escapeJson(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - LLM Provider

/// A closure that performs an HTTP POST and returns the response body.
/// Swift implements this via URLSession. The Zig core calls it for every
/// LLM API request.
public typealias SlowClawHttpPostHandler = (_ url: String, _ authHeader: String,
    _ contentType: String, _ body: Data) -> Data?

/// An LLM provider that talks to any OpenAI-compatible endpoint (OpenAI,
/// OpenRouter, Ollama, LM Studio, etc.) via an injected HTTP handler.
public final class SlowClawLLMProvider {

    private var handle: OpaquePointer?
    private let httpHandler: SlowClawHttpPostHandler
    /// Persistent context block for the C callback (keeps the handler alive).
    private let contextBox: SlowClawHttpContextBox

    public init(baseURL: String, apiKey: String, httpHandler: @escaping SlowClawHttpPostHandler) {
        self.httpHandler = httpHandler
        self.contextBox = SlowClawHttpContextBox(handler: httpHandler)

        let boxPtr = Unmanaged.passRetained(contextBox).toOpaque()
        let h = baseURL.withCString { urlPtr in
            apiKey.withCString { keyPtr in
                slowclaw_feed_provider_new(
                    urlPtr, baseURL.utf8.count,
                    keyPtr, apiKey.utf8.count,
                    boxPtr,
                    slowClawHttpPostTrampoline
                )
            }
        }
        self.handle = h
    }

    deinit {
        if let h = handle {
            slowclaw_feed_provider_free(h)
        }
    }

    /// One-shot chat: optional system prompt + user message → LLM text.
    public func chat(systemPrompt: String?, message: String, model: String,
                     temperature: Double = 0.7) throws -> String {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }

        let result: SlowclawChatResult
        if let sys = systemPrompt {
            result = sys.withCString { sysPtr in
                message.withCString { msgPtr in
                    model.withCString { modelPtr in
                        slowclaw_feed_provider_chat(h, sysPtr, sys.utf8.count,
                                                    msgPtr, message.utf8.count,
                                                    modelPtr, model.utf8.count,
                                                    temperature)
                    }
                }
            }
        } else {
            result = message.withCString { msgPtr in
                model.withCString { modelPtr in
                    slowclaw_feed_provider_chat(h, nil, 0,
                                                msgPtr, message.utf8.count,
                                                modelPtr, model.utf8.count,
                                                temperature)
                }
            }
        }
        return try processChatResult(result)
    }

    /// Journal synthesis: transcript → clean journal entry.
    public func synthesizeJournal(transcript: String, model: String) throws -> String {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let result = transcript.withCString { tPtr in
            model.withCString { mPtr in
                slowclaw_feed_synthesize_journal(h, tPtr, transcript.utf8.count, mPtr, model.utf8.count)
            }
        }
        return try processChatResult(result)
    }

    /// Interest extraction: journal text → comma-separated keywords.
    public func extractInterests(journalText: String, model: String) throws -> [String] {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let result = journalText.withCString { jPtr in
            model.withCString { mPtr in
                slowclaw_feed_extract_interests(h, jPtr, journalText.utf8.count, mPtr, model.utf8.count)
            }
        }
        let csv = try processChatResult(result)
        return csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Post drafting: journal text → short-form post draft.
    public func draftPost(journalText: String, model: String, maxChars: Int = 300) throws -> String {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let result = journalText.withCString { jPtr in
            model.withCString { mPtr in
                slowclaw_feed_draft_post(h, jPtr, journalText.utf8.count, mPtr, model.utf8.count, maxChars)
            }
        }
        return try processChatResult(result)
    }

    private func processChatResult(_ result: SlowclawChatResult) throws -> String {
        var mutableResult = result
        defer { slowclaw_feed_chat_result_free(&mutableResult) }
        if result.status != SLOWCLAW_OK {
            throw SlowClawFeedError.internalError("LLM call failed with status \(result.status)")
        }
        guard let bytes = result.text.bytes, result.text.len > 0 else { return "" }
        let data = Data(bytes: UnsafeRawPointer(bytes), count: result.text.len)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Box to keep the Swift HTTP handler alive across the C callback boundary.
private final class SlowClawHttpContextBox {
    let handler: SlowClawHttpPostHandler
    init(handler: @escaping SlowClawHttpPostHandler) {
        self.handler = handler
    }
}

/// C-callable trampoline that routes the HTTP POST to the Swift handler.
private let slowClawHttpPostTrampoline: SlowclawHttpPostFn = { ctx, urlPtr, urlLen, authPtr, authLen, ctPtr, ctLen, bodyPtr, bodyLen in
    guard let ctx else { return SlowclawString(bytes: nil, len: 0) }
    let box = Unmanaged<SlowClawHttpContextBox>.fromOpaque(ctx).takeUnretainedValue()

    let urlData = Data(bytes: UnsafeRawPointer(urlPtr!), count: urlLen)
    let authData = Data(bytes: UnsafeRawPointer(authPtr!), count: authLen)
    let ctData = Data(bytes: UnsafeRawPointer(ctPtr!), count: ctLen)
    let body = Data(bytes: UnsafeRawPointer(bodyPtr!), count: bodyLen)
    let url = String(data: urlData, encoding: .utf8) ?? ""
    let auth = String(data: authData, encoding: .utf8) ?? ""
    let contentType = String(data: ctData, encoding: .utf8) ?? ""

    guard let response = box.handler(url, auth, contentType, body) else {
        return SlowclawString(bytes: nil, len: 0)
    }

    // Allocate the response via the Zig allocator (malloc) so Zig can free it.
    let len = response.count
    let buf = malloc(len)!
    response.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: len)
    return SlowclawString(bytes: buf.assumingMemoryBound(to: UInt8.self), len: len)
}
