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
public struct SlowClawMemoryEntry: Identifiable, Equatable {
    public let id: String
    public let key: String
    public let content: String
    public let category: String
    public let timestamp: String
    public let sessionID: String?
    public let score: Double?
    /// Provenance: "audio_recorded" (in-app recorder), "audio_imported"
    /// (Voice Memos share-sheet), or "text". Nil for legacy rows.
    public let source: String?
    /// Documents-relative path to the linked audio file, or nil.
    public let mediaURL: String?

    public init(id: String, key: String, content: String, category: String,
                timestamp: String, sessionID: String?, score: Double?,
                source: String? = nil, mediaURL: String? = nil) {
        self.id = id
        self.key = key
        self.content = content
        self.category = category
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.score = score
        self.source = source
        self.mediaURL = mediaURL
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
    /// `source`/`mediaURL` are optional provenance fields (see SlowClawMemoryEntry).
    public func store(key: String, content: String, category: String,
                      sessionID: String? = nil, source: String? = nil,
                      mediaURL: String? = nil) throws {
        guard let h = handle else { throw SlowClawFeedError.internalError("closed") }
        let status = key.withCString { keyPtr in
            content.withCString { contentPtr in
                category.withCString { catPtr in
                    withOptionalCString(sessionID) { sidPtr, sidLen in
                        withOptionalCString(source) { srcPtr, srcLen in
                            withOptionalCString(mediaURL) { mediaPtr, mediaLen in
                                slowclaw_feed_sqlite_store(h, keyPtr, key.utf8.count,
                                                           contentPtr, content.utf8.count,
                                                           catPtr, category.utf8.count,
                                                           sidPtr, sidLen,
                                                           srcPtr, srcLen,
                                                           mediaPtr, mediaLen)
                            }
                        }
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
                      sessionID: String? = nil, source: String? = nil,
                      mediaURL: String? = nil) throws {
        try store(key: key, content: content, category: category.rawValue,
                  sessionID: sessionID, source: source, mediaURL: mediaURL)
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
        let source: String? = entry.source.bytes.map { _ in stringFromSlowclaw(entry.source) }
        let mediaURL: String? = entry.media_url.bytes.map { _ in stringFromSlowclaw(entry.media_url) }
        let score = entry.score.isNaN ? nil : entry.score
        return SlowClawMemoryEntry(id: id, key: key, content: content, category: category,
                                   timestamp: timestamp, sessionID: sessionID, score: score,
                                   source: source, mediaURL: mediaURL)
    }

    private func stringFromSlowclaw(_ s: SlowclawString) -> String {
        guard let bytes = s.bytes, s.len > 0 else { return "" }
        return String(data: Data(bytes: UnsafeRawPointer(bytes), count: s.len), encoding: .utf8) ?? ""
    }
}

/// Bridge an optional Swift String to the C ABI's `(ptr, len)` convention.
/// Absent → `(nil, 0)`; present → the string's UTF-8 pointer + byte count,
/// valid for the duration of `body`. Mirrors how the recall/store paths pass
/// optional session_id/source/media_url across the boundary.
@inline(__always)
private func withOptionalCString<R>(_ s: String?,
                                    _ body: (UnsafePointer<CChar>?, Int) -> R) -> R {
    guard let s else { return body(nil, 0) }
    return s.withCString { ptr in body(ptr, s.utf8.count) }
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
    let source: String?
    let media_url: String?
    let score: Double?

    func toSwift() -> SlowClawMemoryEntry {
        return SlowClawMemoryEntry(id: id, key: key, content: content,
                                   category: category, timestamp: timestamp,
                                   sessionID: session_id, score: score,
                                   source: source, mediaURL: media_url)
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
    /// Cover image URL extracted by the Zig core (media:thumbnail /
    /// media:content / image enclosure / first <img>). "" when none —
    /// older core builds omit the key entirely, hence decodeIfPresent.
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case title, link, description, sourceLabel, score, readMinutes, thumbnail
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
        let ytThumb = ytID.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" }
        let rssThumb = thumbnail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RankedFeedItem(
            id: safeId,
            title: title,
            link: trimmedLink,
            description: description,
            sourceLabel: sourceLabel,
            score: score,
            readMinutes: readMinutes,
            sourcePlatform: platform,
            thumbnailURL: ytThumb ?? (rssThumb?.isEmpty == false ? rssThumb : nil)
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

/// Post-merge production filter (the curation the iOS app was missing — the
/// reference does this in the Rust gateway ranker.rs). Runs on the merged,
/// score-sorted batch from many feeds:
///   1. Quality gate — drop items with no title AND no body (spam/empty).
///   2. Dedup by link, keeping the highest-scored (input must be score-sorted
///      desc so first occurrence wins). Collapses cross-feed reposts.
///   3. Per-source cap + round-robin so one feed can't dominate the output.
/// Mirrors the Zig feeds_ranking.filterAndDiversify (kept in Swift because the
/// merge happens client-side across many Zig-ranked feeds).
public func slowClawFilterAndDiversify(
    _ items: [RankedFeedItem],
    maxPerSource: Int = 6,
    limit: Int = 80
) -> [RankedFeedItem] {
    guard !items.isEmpty else { return [] }

    // (1) Quality gate + (2) dedup by link (first wins, input is score-sorted).
    var seen = Set<String>()
    var deduped: [RankedFeedItem] = []
    deduped.reserveCapacity(items.count)
    for item in items {
        let hasTitle = !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasTitle || hasBody else { continue } // drop empty/spam
        // Dedup key: the link when present, else a synthetic per-id key (no dedup).
        let key = item.link.isEmpty ? "id:\(item.id)" : "link:\(item.link)"
        if seen.insert(key).inserted { deduped.append(item) }
    }

    // (3) Per-source cap + round-robin interleave.
    // Group by sourceLabel preserving score order, cap each, then round-robin.
    var queues: [[RankedFeedItem]] = []
    var queueLabels: [String] = []
    var bySource: [String: [RankedFeedItem]] = [:]
    for item in deduped {
        if bySource[item.sourceLabel] == nil { queueLabels.append(item.sourceLabel) }
        var q = bySource[item.sourceLabel] ?? []
        if q.count < maxPerSource { q.append(item) }
        bySource[item.sourceLabel] = q
    }
    for label in queueLabels { queues.append(bySource[label] ?? []) }

    var out: [RankedFeedItem] = []
    out.reserveCapacity(min(deduped.count, limit))
    var anyLeft = true
    while out.count < limit && anyLeft {
        anyLeft = false
        for qi in queues.indices where out.count < limit {
            let taken = out.filter { $0.sourceLabel == queueLabels[qi] }.count
            if taken >= maxPerSource { continue }
            if queues[qi].count > taken {
                out.append(queues[qi][taken])
                anyLeft = true
            }
        }
    }
    return out
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

/// On-device LLM status reported by the Zig core. `available` means the
/// llama.cpp backend is linked into the build; `loaded` means a GGUF model is
/// currently in memory and chat calls will run on-device.
public struct LocalLLMStatus: Decodable {
    public let available: Bool
    public let loaded: Bool
    public let modelId: String?
    public let reason: String?

    public init(available: Bool, loaded: Bool = false, modelId: String? = nil, reason: String? = nil) {
        self.available = available
        self.loaded = loaded
        self.modelId = modelId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case available, loaded, modelId, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A downloadable on-device model. The two Gemma 4 E2B QAT quants the
/// reference app offers, hosted on Hugging Face (unsloth).
public struct LocalModelPreset: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let fileName: String
    public let downloadURL: URL
    /// Approximate download size, for free-space checks and progress fallback.
    public let sizeBytes: Int64
    public let sizeLabel: String
    /// Optional multimodal projector (mmproj) for audio/vision models. When
    /// present, activating the model also downloads + loads the mmproj so the
    /// Zig core's mtmd layer can ingest audio. nil for text-only models.
    public let mmprojFileName: String?
    public let mmprojDownloadURL: URL?
    public let mmprojSizeLabel: String?
    /// Approximate mmproj download size in bytes (drives combined download
    /// progress + the delegate's fallback size). nil when unknown.
    public let mmprojSizeBytes: Int64?

    public init(id: String, title: String, detail: String, fileName: String,
                downloadURL: URL, sizeBytes: Int64, sizeLabel: String,
                mmprojFileName: String? = nil, mmprojDownloadURL: URL? = nil,
                mmprojSizeLabel: String? = nil, mmprojSizeBytes: Int64? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sizeLabel = sizeLabel
        self.mmprojFileName = mmprojFileName
        self.mmprojDownloadURL = mmprojDownloadURL
        self.mmprojSizeLabel = mmprojSizeLabel
        self.mmprojSizeBytes = mmprojSizeBytes
    }

    /// True when this preset carries an audio mmproj (mtmd-capable).
    public var hasAudioMmproj: Bool { mmprojFileName != nil }

    public static let presets: [LocalModelPreset] = [
        .init(id: "unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL",
              title: "Gemma 4 E2B (Q2_K_XL)",
              detail: "Smaller, faster. ~2.1 GB. Best for older devices.",
              fileName: "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
              downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf")!,
              sizeBytes: 2_190_000_000,
              sizeLabel: "2.1 GB"),
        .init(id: "unsloth/gemma-4-E2B-it-qat-UD-Q4_K_XL",
              title: "Gemma 4 E2B (Q4_K_XL)",
              detail: "Higher quality. ~2.5 GB. Best for iPhone 15 Pro+.",
              fileName: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
              downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf")!,
              sizeBytes: 2_620_000_000,
              sizeLabel: "2.5 GB"),
        // 🔬 Experimental audio model: Gemma 4 E2B (multimodal: text + audio).
        // Pairs the SAME text GGUF as the proven presets above with unsloth's
        // official mmproj from the same repo (clip.has_audio_encoder=true,
        // clip.audio.projector_type=gemma4a — the audio type the vendored mtmd
        // version actually supports; gemma-3n's "gemma3na" is NOT supported by
        // init_audio() there, so a Gemma 3n mmproj can never load).
        // The mmproj URL is revision-pinned so a later upstream change can't
        // break the download; bump the pin deliberately when re-vendoring.
        .init(id: "unsloth/gemma-4-E2B-it-qat-audio",
              title: "Gemma 4 E2B Audio (experimental)",
              detail: "Multimodal: text + audio. On-device transcription via mtmd. Also downloads the ~1.0 GB audio mmproj (mmproj-F16).",
              fileName: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
              downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf")!,
              sizeBytes: 2_620_000_000,
              sizeLabel: "2.5 GB",
              // Revision-pinned: repo sha 66a399f68ddd113b06dff02fca9523e55465d11d
              mmprojFileName: "gemma-4-E2B-it-mmproj-F16.gguf",
              mmprojDownloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/66a399f68ddd113b06dff02fca9523e55465d11d/mmproj-F16.gguf")!,
              mmprojSizeLabel: "1.0 GB",
              mmprojSizeBytes: 985_654_080),
    ]
}

/// On-device model file management: GGUFs live in Documents/Models/.
public enum LocalModelStore {
    public static func modelsDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func fileURL(for preset: LocalModelPreset) throws -> URL {
        try modelsDirectory().appendingPathComponent(preset.fileName)
    }

    /// A file counts as downloaded when it exists, clears the Zig core's own
    /// 1 KiB sanity floor by a wide margin, AND starts with the GGUF magic
    /// bytes — a corrupt or error-page file left by an older build must not
    /// count as downloaded (that would bypass download validation).
    public static func isDownloaded(_ preset: LocalModelPreset) -> Bool {
        guard let url = try? fileURL(for: preset) else { return false }
        return isPlausibleGGUF(at: url, minimumBytes: 1_000_000)
    }

    /// Download the preset to Documents/Models/ with progress (0...1). Runs
    /// in a BACKGROUND URLSession so the multi-GB transfer KEEPS GOING while
    /// the app is backgrounded or the phone is locked (iOS's nsurlsessiond
    /// owns the transfer, not the app process — no manual pause/resume
    /// bookkeeping; only a user force-quit cancels it, and the download
    /// restarts cleanly on the next request). The completed file is moved
    /// into place by the download delegate only after a 2xx transfer that
    /// validates as a real GGUF (magic bytes + expected-size floor) — a
    /// partial file or error page never masquerades as a valid model, and a
    /// valid model on disk is replaced only by a validated download (the
    /// GGUF magic check in the Zig core is the second line of defense).
    public static func download(_ preset: LocalModelPreset,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = try fileURL(for: preset)
        if isDownloaded(preset) {
            progress(1.0)
            return dest
        }
        try await ModelDownloadCoordinator.shared.run(url: preset.downloadURL, destination: dest,
                                                      fallbackSize: preset.sizeBytes, progress: progress)
        progress(1.0)
        return dest
    }

    public static func delete(_ preset: LocalModelPreset) throws {
        let url = try fileURL(for: preset)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Multimodal projector (mmproj) for audio/vision models

    /// File URL for a preset's mmproj (audio encoder + projector). Same
    /// Documents/Models/ dir as the text GGUF.
    public static func mmprojFileURL(for preset: LocalModelPreset) throws -> URL? {
        guard let name = preset.mmprojFileName else { return nil }
        return try modelsDirectory().appendingPathComponent(name)
    }

    /// True when the mmproj is downloaded (for presets that have one).
    public static func isMmprojDownloaded(_ preset: LocalModelPreset) -> Bool {
        guard preset.hasAudioMmproj,
              let url = try? mmprojFileURL(for: preset) else { return false }
        return isPlausibleGGUF(at: url, minimumBytes: 100_000)
    }

    /// Shared download-state check: the file must exist, clear `minimumBytes`,
    /// AND start with the GGUF magic bytes. Mirrors the coordinator's stricter
    /// post-download validation (validateGGUF) so a corrupt or error-page file
    /// already on disk is never mistaken for a downloaded model/projector —
    /// pre-existing garbage re-triggers a download instead of bypassing it.
    private static func isPlausibleGGUF(at url: URL, minimumBytes: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > minimumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == Data("GGUF".utf8)
    }

    /// Download the mmproj for a preset. Same background-URLSession path as
    /// the text model download (continues while backgrounded/locked).
    /// Throws if the preset has no mmproj or no hosted mmproj URL (the Gemma
    /// 3n mmproj must be generated + hosted first).
    public static func downloadMmproj(_ preset: LocalModelPreset,
                                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let name = preset.mmprojFileName,
              let srcURL = preset.mmprojDownloadURL else {
            throw NSError(domain: "SlowClawFeed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This model's mmproj has no hosted download URL yet."])
        }
        let dest = try modelsDirectory().appendingPathComponent(name)
        if isMmprojDownloaded(preset) {
            progress(1.0)
            return dest
        }
        try await ModelDownloadCoordinator.shared.run(url: srcURL, destination: dest,
                                                      fallbackSize: preset.mmprojSizeBytes ?? 500_000_000,
                                                      progress: progress)
        progress(1.0)
        return dest
    }

    /// Delete the mmproj file for a preset (no-op if the preset has none).
    public static func deleteMmproj(_ preset: LocalModelPreset) throws {
        guard let url = try? mmprojFileURL(for: preset) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
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

/// Load a GGUF model into the on-device engine. Returns nil on success, else
/// a human-readable error. Slow (seconds) and memory-heavy — call off the
/// main thread.
public func slowClawLocalLLMLoad(path: String) -> String? {
    let code = path.withCString { ptr in
        slowclaw_feed_local_llm_load(ptr, path.utf8.count)
    }
    switch code {
    case SLOWCLAW_OK: return nil
    case SLOWCLAW_ERR_INVALID_ARGUMENT:
        return "The file is missing, truncated, or not a GGUF model. Delete and re-download it."
    case SLOWCLAW_ERR_OUT_OF_MEMORY:
        return "Not enough memory to load the model."
    default:
        return "llama.cpp could not load this model (unsupported architecture or too large for this device)."
    }
}

/// Unload the on-device model (frees RAM).
public func slowClawLocalLLMUnload() {
    slowclaw_feed_local_llm_unload()
}

private func processLocalChatResult(_ result: SlowclawChatResult) throws -> String {
    var mutableResult = result
    defer { slowclaw_feed_chat_result_free(&mutableResult) }
    switch result.status {
    case SLOWCLAW_OK: break
    case SLOWCLAW_ERR_INVALID_ARGUMENT:
        throw SlowClawFeedError.internalError("No on-device model is loaded.")
    default:
        throw SlowClawFeedError.internalError("On-device inference failed (status \(result.status))")
    }
    guard let bytes = result.text.bytes, result.text.len > 0 else { return "" }
    let data = Data(bytes: UnsafeRawPointer(bytes), count: result.text.len)
    return String(data: data, encoding: .utf8) ?? ""
}

/// Chat completion on the loaded on-device model. Mirrors
/// `SlowClawLLMProvider.chat` so call sites can swap transports.
public func slowClawLocalLLMChat(systemPrompt: String?, message: String,
                                 maxTokens: UInt32 = 512, temperature: Double = 0.7) throws -> String {
    let result: SlowclawChatResult
    if let sys = systemPrompt {
        result = sys.withCString { sysPtr in
            message.withCString { msgPtr in
                var out = SlowclawChatResult()
                slowclaw_feed_local_llm_chat(sysPtr, sys.utf8.count, msgPtr, message.utf8.count,
                                             maxTokens, temperature, &out)
                return out
            }
        }
    } else {
        result = message.withCString { msgPtr in
            var out = SlowclawChatResult()
            slowclaw_feed_local_llm_chat(nil, 0, msgPtr, message.utf8.count,
                                         maxTokens, temperature, &out)
            return out
        }
    }
    return try processLocalChatResult(result)
}

/// Journal synthesis on-device: transcript → clean journal entry. Uses the
/// same prompt as the HTTP provider path (built in the Zig core).
public func slowClawLocalSynthesizeJournal(transcript: String) throws -> String {
    let result = transcript.withCString { ptr in
        var out = SlowclawChatResult()
        slowclaw_feed_local_llm_synthesize_journal(ptr, transcript.utf8.count, &out)
        return out
    }
    return try processLocalChatResult(result)
}

/// Interest extraction on-device: journal text → keywords.
public func slowClawLocalExtractInterests(journalText: String) throws -> [String] {
    let result = journalText.withCString { ptr in
        var out = SlowclawChatResult()
        slowclaw_feed_local_llm_extract_interests(ptr, journalText.utf8.count, &out)
        return out
    }
    let csv = try processLocalChatResult(result)
    return csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// Post drafting on-device: journal text → short-form post draft.
public func slowClawLocalDraftPost(journalText: String, maxChars: Int = 300) throws -> String {
    let result = journalText.withCString { ptr in
        var out = SlowclawChatResult()
        slowclaw_feed_local_llm_draft_post(ptr, journalText.utf8.count, maxChars, &out)
        return out
    }
    return try processLocalChatResult(result)
}

/// Title generation on-device: transcript/text → concise title.
public func slowClawLocalGenerateTitle(transcript: String) throws -> String {
    let result = transcript.withCString { ptr in
        var out = SlowclawChatResult()
        slowclaw_feed_local_llm_generate_title(ptr, transcript.utf8.count, &out)
        return out
    }
    return try processLocalChatResult(result)
}

// MARK: - On-device audio transcription (mtmd / multimodal)

/// On-device audio engine status. `available` reflects whether the mtmd
/// backend is linked; `supported` whether an audio-capable mmproj is loaded;
/// `sampleRate` the rate the projector expects (0 if none).
public struct LocalAudioStatus: Decodable {
    public let available: Bool
    public let supported: Bool
    public let sampleRate: Int
    public let reason: String?

    public init(available: Bool = false, supported: Bool = false,
                sampleRate: Int = 0, reason: String? = nil) {
        self.available = available
        self.supported = supported
        self.sampleRate = sampleRate
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case available, supported, sampleRate, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Per-transcription timing (milliseconds). The locked-phone experiment reads
/// these to determine whether the process got CPU time while the screen was
/// locked. Mirrors SlowclawAudioTimings in the C header.
public struct AudioTimings {
    public let loadMs: Int64
    public let encodeMs: Int64
    public let decodeMs: Int64
    public let totalMs: Int64

    public init(loadMs: Int64 = 0, encodeMs: Int64 = 0, decodeMs: Int64 = 0, totalMs: Int64 = 0) {
        self.loadMs = loadMs
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.totalMs = totalMs
    }
}

/// Result of an on-device transcription: the transcript text + timings.
public struct LocalAudioTranscription {
    public let text: String
    public let timings: AudioTimings
}

/// Read on-device audio engine status from the Zig core. Returns a
/// not-available status on any error (so callers can render safely).
public func slowClawLocalAudioStatus() -> LocalAudioStatus {
    var out = SlowclawString(bytes: nil, len: 0)
    let status = slowclaw_feed_local_audio_status(&out)
    guard status == SLOWCLAW_OK, let bytes = out.bytes, out.len > 0 else {
        if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) }
        return LocalAudioStatus(available: false, reason: "Status unavailable.")
    }
    defer { if let b = out.bytes { slowclaw_feed_free(UnsafeMutableRawPointer(mutating: b)) } }
    let data = Data(bytes: UnsafeRawPointer(bytes), count: out.len)
    return (try? JSONDecoder().decode(LocalAudioStatus.self, from: data))
        ?? LocalAudioStatus(available: false, reason: "Status decode failed.")
}

/// Load the audio multimodal projector (mmproj GGUF). The text model must be
/// loaded first via slowClawLocalLLMLoad. Returns nil on success, else a
/// human-readable error. Slow + memory-heavy — call off the main thread.
public func slowClawLocalAudioLoadMMProj(path: String) -> String? {
    let code = path.withCString { ptr in
        slowclaw_feed_local_audio_load_mmproj(ptr, path.utf8.count)
    }
    switch code {
    case SLOWCLAW_OK: return nil
    case SLOWCLAW_ERR_INVALID_ARGUMENT:
        return "The mmproj is missing, invalid, or does not support audio. Load the text model first."
    case SLOWCLAW_ERR_OUT_OF_MEMORY:
        return "Not enough memory to load the audio projector."
    default:
        return "mtmd could not load this projector (unsupported or too large for this device)."
    }
}

/// Unload the audio mmproj (frees RAM).
public func slowClawLocalAudioUnload() {
    slowclaw_feed_local_audio_unload()
}

/// Transcribe mono PCM F32 samples into text on-device. `pcm` is raw 32-bit
/// float samples at the rate from slowClawLocalAudioStatus().sampleRate
/// (typically 16000). The caller decodes + resamples the audio file to this
/// format before calling. Returns the transcript + timings; throws on error.
public func slowClawLocalAudioTranscribe(pcm: [Float], maxTokens: UInt32 = 256,
                                          temperature: Double = 0.0) throws -> LocalAudioTranscription {
    precondition(MemoryLayout<Float>.size == 4, "Float must be 32-bit")
    var out = SlowclawChatResult()
    var timings = SlowclawAudioTimings()
    let code: Int32 = pcm.withUnsafeBufferPointer { buf in
        let ptr = buf.baseAddress
        return slowclaw_feed_local_audio_transcribe(
            ptr, pcm.count, maxTokens, temperature, &out, &timings)
    }
    let text = try processLocalChatResult(SlowclawChatResult(
        text: out.text, status: code == SLOWCLAW_OK ? SLOWCLAW_OK : out.status))
    return LocalAudioTranscription(
        text: text,
        timings: AudioTimings(
            loadMs: timings.load_ms,
            encodeMs: timings.encode_ms,
            decodeMs: timings.decode_ms,
            totalMs: timings.total_ms
        )
    )
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

public extension Notification.Name {
    /// Posted when a model file lands on disk via the background download
    /// coordinator (object: the file's lastPathComponent). Covers the orphan
    /// path — a download that finished after the app was relaunched with no
    /// `download()` call awaiting it — so the app can re-render the model
    /// rows (a landed file counts as downloaded).
    static let slowClawModelFileLanded = Notification.Name("slowclaw.model.file-landed")
}

/// Long-lived coordinator for the on-device model downloads, backed by ONE
/// background URLSession (identifier-pinned) so multi-GB GGUF transfers keep
/// running while the app is backgrounded, suspended, or the phone is locked:
/// iOS's nsurlsessiond owns the transfer, not the app process. That makes the
/// "background download" answer YES on iOS via background session configs —
/// no manual pause-when-backgrounded/resume-when-open logic is needed. The OS
/// also resumes automatically after transient network loss. (iOS cancels the
/// transfer only when the user force-quits the app; it restarts on the next
/// download request.)
///
/// The coordinator survives app relaunches: when the system relaunches the
/// app for session events, `handleEventsForBackgroundURLSession` reconnects
/// this delegate (see slowClawHandleBackgroundModelSession). In-flight tasks
/// carry their destination path in `taskDescription`, so an orphaned download
/// (relaunched app, nobody awaiting) still lands its file on disk — and the
/// next `download()` for the same file ATTACHES to the in-flight task instead
/// of duplicating it. Attach matching is destination-first (stable across
/// redirects and relaunches), then the ORIGINAL request URL; `currentRequest`
/// alone never matches a redirected transfer (Hugging Face resolve URLs
/// redirect to a CDN).
///
/// Nothing is installed into the destination until the transfer is proven
/// good: a 2xx HTTP status, GGUF magic bytes, and a size floor derived from
/// the expected download size. A validated replacement is swapped in without
/// ever pre-deleting the destination, so an existing valid model survives a
/// failed or bogus download. Completion surfaces every failure — transport,
/// HTTP status, validation, and move — to ALL awaiters, and orphan
/// completions stash the combined outcome; a second caller joins
/// an already-awaited task instead of overwriting it (overwriting would leak
/// the first caller's continuation, leaving it suspended forever).
private final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ModelDownloadCoordinator()
    static let sessionIdentifier = "com.slowclaw.app.model-download"

    /// GGUF files begin with the ASCII magic "GGUF".
    private static let ggufMagic = Data("GGUF".utf8)
    /// Hard floor for accepted files even when no expected size is known
    /// (orphaned completions carry no fallbackSize). Far above any error-page
    /// body, far below any real model or projector.
    private static let minimumFileBytes: Int64 = 1_000_000

    private struct DownloadRecord {
        var destination: URL
        var fallbackSize: Int64
        /// All progress sinks attached to the task (first caller + joiners).
        var progressHandlers: [@Sendable (Double) -> Void]
        /// Every caller awaiting this task, each resumed exactly once at
        /// completion. Callers JOIN (append) — replacing the record would
        /// orphan the previous continuation and hang that caller forever.
        var waiters: [CheckedContinuation<Void, Error>]
    }

    private let lock = NSLock()
    private var records: [Int: DownloadRecord] = [:]
    /// Post-transfer failures recorded by the download delegate for tasks
    /// whose bytes arrived but could not be persisted as a valid model:
    /// rejected HTTP status, failed validation, failed install/move. Stored
    /// independently of `records` (keyed by task id) so ORPHANED completions
    /// — no record, nobody awaiting — still carry the failure into their
    /// stashed outcome instead of reporting transport success. Consumed and
    /// cleared in didCompleteWithError.
    private var delegateErrors: [Int: Error] = [:]
    /// Task ids whose delegate DID install a validated file at the
    /// destination (set after a successful install in didFinishDownloadingTo).
    /// Success is only ever reported for tasks present here — a transfer that
    /// completes without the delegate installing anything (didFinish absent /
    /// non-HTTP response edge) must not resume awaiters with success.
    /// Consumed in didCompleteWithError.
    private var installedTaskIDs: Set<Int> = []
    /// Final outcomes for tasks that completed with nobody awaiting (orphan
    /// completions): the transport/HTTP outcome COMBINED with any delegate-
    /// recorded validation/install failure. A caller that discovers an
    /// in-flight task and registers its waiter AFTER the task finished would
    /// otherwise hang forever — the stashed outcome lets `run()` fail/succeed
    /// immediately instead. Entries are consumed (removed) on read; growth is
    /// bounded by the handful of completed model downloads per session.
    private var finishedTaskResults: [Int: Result<Void, Error>] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    /// The background session — a static let so initialization is thread-safe
    /// (downloads start from the main actor but complete on session queues).
    /// Creating it with the pinned identifier re-associates this delegate with
    /// any tasks still in flight from before a relaunch/suspension.
    static let session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: ModelDownloadCoordinator.sessionIdentifier)
        // Deliver (and relaunch for) session events after the app goes away.
        config.sessionSendsLaunchEvents = true
        // A 2.5 GB transfer should wait for connectivity rather than fail fast.
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        // Multi-GB GGUFs stay off metered/scarce networks by default: no
        // cellular, no expensive links (hotspots, pay-per-byte), no Low Data
        // Mode. Combined with waitsForConnectivity, the transfer waits for
        // Wi-Fi instead of failing fast or silently consuming a data plan.
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: config, delegate: shared, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Download `url` to `destination`, reporting progress (0...1). Attaches
    /// to an already in-flight task for the same destination/URL (the
    /// relaunch case) rather than starting a duplicate transfer; a second
    /// caller for an already-awaited task JOINS it (all joined continuations
    /// are resumed exactly once) instead of overwriting the record.
    func run(url: URL, destination: URL, fallbackSize: Int64,
             progress: (@Sendable (Double) -> Void)?) async throws {
        let existing = await Self.session.allTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .first { Self.isAttachable($0, url: url, destination: destination) }
        if let task = existing {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                // The transfer completed between discovery and registration:
                // honor the stashed outcome instead of registering a waiter
                // that no future completion event would ever resume. The
                // entry is consumed (removed) on read.
                if let outcome = finishedTaskResults.removeValue(forKey: task.taskIdentifier) {
                    lock.unlock()
                    cont.resume(with: outcome)
                    return
                }
                // NOTE: no "destination file exists → succeed" shortcut here.
                // A leftover corrupt/error-page file can sit at the
                // destination while a valid replacement is still downloading;
                // only the task's own combined outcome — which requires a
                // proven validated install — may resolve this awaiter. The
                // stash above already covers the completion race, so waiting
                // cannot hang.
                if var record = records[task.taskIdentifier] {
                    // Second caller joining an awaited task: append the
                    // waiter; never overwrite the record (that would leak the
                    // first caller's continuation).
                    if let progress { record.progressHandlers.append(progress) }
                    record.waiters.append(cont)
                    records[task.taskIdentifier] = record
                } else {
                    // Orphaned in-flight task (app relaunched, nobody
                    // awaiting): adopt it so completion reaches this caller.
                    records[task.taskIdentifier] = DownloadRecord(
                        destination: destination,
                        fallbackSize: fallbackSize,
                        progressHandlers: progress.map { [$0] } ?? [],
                        waiters: [cont])
                }
                lock.unlock()
            }
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            // A same-destination task may have been created concurrently
            // (double tap / two callers racing the task scan): join it
            // instead of duplicating the transfer for one destination.
            if let existingID = records.first(where: { $0.value.destination == destination })?.key {
                // Join fully: append the progress handler too, so the second
                // caller both awaits completion and receives progress updates.
                if let progress { records[existingID]?.progressHandlers.append(progress) }
                records[existingID]?.waiters.append(cont)
                lock.unlock()
                return
            }
            let task = Self.session.downloadTask(with: url)
            // Destination travels with the task so an orphaned completion
            // (app relaunched, nobody awaiting) still lands the file — and so
            // reattachment matches by destination first (stable across
            // redirects, unlike the request URL).
            task.taskDescription = destination.path
            records[task.taskIdentifier] = DownloadRecord(
                destination: destination,
                fallbackSize: fallbackSize,
                progressHandlers: progress.map { [$0] } ?? [],
                waiters: [cont])
            lock.unlock()
            task.resume()
        }
    }

    /// Whether an in-flight download task should be attached to instead of
    /// starting a duplicate transfer. Matched most-stable-first: the
    /// destination path tag (survives redirects and relaunches), then the
    /// ORIGINAL request URL (the pre-redirect URL, stable across the CDN
    /// hop), and only as a last resort the current (possibly redirected)
    /// request URL. A task tagged with a DIFFERENT destination is never
    /// adopted, even when its URL matches (two destinations may share one
    /// source URL — e.g. the audio preset reuses the Q4 text GGUF).
    private static func isAttachable(_ task: URLSessionDownloadTask,
                                     url: URL, destination: URL) -> Bool {
        guard task.state == .running || task.state == .suspended else { return false }
        if task.taskDescription == destination.path { return true }
        // URL-based matching only applies when the task carries no
        // conflicting destination tag.
        guard task.taskDescription == nil || task.taskDescription == destination.path else {
            return false
        }
        if task.originalRequest?.url == url { return true }
        if task.currentRequest?.url == url { return true }
        return false
    }

    /// Store the system's background-relaunch completion handler and
    /// reconnect this coordinator to the session's events (touching
    /// `session` is what re-associates the delegate).
    func acceptBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = Self.session
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let record = records[downloadTask.taskIdentifier]
        lock.unlock()
        // No record → orphaned progress (relaunched app, nobody attached yet):
        // nothing to report; the file still lands on completion.
        guard let record else { return }
        var expected = totalBytesExpectedToWrite
        if expected <= 0 { expected = record.fallbackSize }
        guard expected > 0 else { return }
        let fraction = min(1.0, Double(totalBytesWritten) / Double(expected))
        for handler in record.progressHandlers { handler(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Destination: the registered record's, else the path the task was
        // created with (orphaned completion after relaunch). Orphans carry no
        // expected size; they still get the magic check + the hard floor.
        lock.lock()
        let record = records[downloadTask.taskIdentifier]
        let dest = record?.destination
            ?? downloadTask.taskDescription.map { URL(fileURLWithPath: $0) }
        let fallbackSize = record?.fallbackSize ?? 0
        lock.unlock()
        guard let dest else { return }

        // (1) Only 2xx bodies may be installed. Error pages (404/5xx) arrive
        // here as nominally "successful" transfers — they must never become
        // (or overwrite) a model. The temp file is discarded when this method
        // returns; the destination is left untouched.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            recordCompletionError(downloadTask.taskIdentifier, SlowClawFeedError.internalError(
                "Model download failed (HTTP \(http.statusCode))."))
            return
        }

        // (2) Validate content BEFORE anything touches the destination: GGUF
        // magic + a size floor derived from the expected download size. The
        // install only proceeds once the temp file is proven good, so an
        // existing valid model can never be clobbered by a bad body.
        let minimumBytes = fallbackSize > 0
            ? max(Self.minimumFileBytes, fallbackSize / 2)
            : Self.minimumFileBytes
        if let validationError = Self.validateGGUF(at: location, minimumBytes: minimumBytes) {
            recordCompletionError(downloadTask.taskIdentifier, SlowClawFeedError.internalError(
                "Downloaded model failed validation: \(validationError.localizedDescription)"))
            return
        }

        // (3) Persist: ensure the directory exists, then move the validated
        // file into place WITHOUT pre-deleting the destination — an existing
        // file is swapped atomically, so a valid model is only replaced once
        // a valid replacement is ready. The temp URL is invalidated the
        // moment this method returns, so the move must be synchronous.
        do {
            try Self.install(validatedAt: location, to: dest)
            lock.lock()
            installedTaskIDs.insert(downloadTask.taskIdentifier)
            lock.unlock()
            // Tell the app a model file landed (the orphan path has no
            // awaiter to surface it) so status UI can re-render.
            NotificationCenter.default.post(name: .slowClawModelFileLanded,
                                            object: dest.lastPathComponent)
        } catch {
            recordCompletionError(downloadTask.taskIdentifier, error)
        }
    }

    /// Record a post-transfer failure for the task so completion reports it
    /// to every waiter — and to the orphan-outcome stash — instead of a false
    /// success. Stored independently of any DownloadRecord so it also covers
    /// orphaned completions (no record, nobody awaiting).
    private func recordCompletionError(_ taskIdentifier: Int, _ error: Error) {
        lock.lock()
        delegateErrors[taskIdentifier] = error
        lock.unlock()
    }

    /// Validate a downloaded file is plausibly a GGUF model: it must start
    /// with the GGUF magic bytes and clear a minimum-size floor. Returns nil
    /// when valid, else an error describing the rejection.
    private static func validateGGUF(at url: URL, minimumBytes: Int64) -> Error? {
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return error
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minimumBytes else {
            return SlowClawFeedError.internalError(
                "File is \(size) bytes, below the expected minimum (\(minimumBytes)).")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return SlowClawFeedError.internalError("Downloaded file is unreadable.")
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: ggufMagic.count)
        guard magic == ggufMagic else {
            return SlowClawFeedError.internalError("File is not a GGUF model (bad magic bytes).")
        }
        return nil
    }

    /// Move a validated download into its final destination. The destination
    /// is never deleted first: an existing file is replaced via
    /// `replaceItemAt` (atomic swap — the old file survives until the new one
    /// is in place), a fresh destination gets a plain move. Ensures the
    /// destination directory exists either way.
    private static func install(validatedAt location: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
        } else {
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Outcome from the transfer itself (transport error / HTTP status).
        let transferOutcome: Result<Void, Error>
        if let error {
            transferOutcome = .failure(error)
        } else if let http = task.response as? HTTPURLResponse,
                  !(200...299).contains(http.statusCode) {
            transferOutcome = .failure(SlowClawFeedError.internalError(
                "Model download failed (HTTP \(http.statusCode))."))
        } else {
            transferOutcome = .success(())
        }

        let waiters: [CheckedContinuation<Void, Error>]
        lock.lock()
        // Combine the transfer outcome with the delegate's ground truth: any
        // recorded validation/install failure, and whether a validated file
        // was actually installed. All state entries are consumed (cleaned
        // up) here.
        let outcome: Result<Void, Error>
        if let delegateError = delegateErrors.removeValue(forKey: task.taskIdentifier) {
            outcome = .failure(delegateError)
        } else if case .failure = transferOutcome {
            outcome = transferOutcome
        } else if installedTaskIDs.remove(task.taskIdentifier) == nil {
            // Transfer reported success but the delegate never installed a
            // validated file (didFinish absent / non-HTTP response edge):
            // never report success without a file at the destination.
            outcome = .failure(SlowClawFeedError.internalError(
                "Download finished without producing a model file."))
        } else {
            outcome = transferOutcome
        }
        if let record = records.removeValue(forKey: task.taskIdentifier) {
            waiters = record.waiters
        } else {
            // Nobody awaited this task (orphan completion): stash the COMBINED
            // outcome so a caller attaching in the discovery→register race
            // window fails/succeeds fast instead of waiting forever — and so
            // it never sees transport success for a file that failed
            // validation or could not be installed.
            finishedTaskResults[task.taskIdentifier] = outcome
            waiters = []
        }
        lock.unlock()
        // Resume outside the lock; each waiter is resumed exactly once.
        for waiter in waiters { waiter.resume(with: outcome) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All tasks done → release the launch completion handler the system
        // handed us (required for the app to snapshot back down cleanly).
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}

/// Forward the system's background-URLSession relaunch callback
/// (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`)
/// to the model-download coordinator. Returns true when the identifier
/// belongs to the model session (the handler is stored and invoked when the
/// session goes idle); false for any other session, in which case the caller
/// should invoke the handler itself.
public func slowClawHandleBackgroundModelSession(identifier: String,
                                                 completionHandler: @escaping () -> Void) -> Bool {
    guard identifier == ModelDownloadCoordinator.sessionIdentifier else { return false }
    ModelDownloadCoordinator.shared.acceptBackgroundEvents(completionHandler: completionHandler)
    return true
}
