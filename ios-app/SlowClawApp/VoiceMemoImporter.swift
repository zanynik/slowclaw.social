// VoiceMemoImporter.swift — import shared voice memos and transcribe them.
//
// Mirrors the reference app's importAndTranscribeVoiceMemos (web/src/App.tsx):
// when iOS delivers a shared audio file (Voice Memos → Share → "Copy to
// SlowClaw"), it arrives as a file URL via .onOpenURL on the App.
//
// Flow:
//   1. enqueue(_:) copies the shared file into Documents/Inbox under a
//      UUID-based name (collision-proof even for same-second imports) and
//      IMMEDIATELY records the import in a durable queue file
//      (Documents/pending_voice_imports.json, atomic write) — before any
//      store attempt. Each record carries a stable journalKey, assigned at
//      enqueue time. A process kill at any point after the copy therefore
//      leaves an app-visible intent that the next launch retries.
//   2. When AppState is wired, the placeholder journal is stored right away
//      under the record's journalKey (durable SQLite row linked via
//      source="audio_imported" + media_url) and the queued record is dropped;
//      transcription is handed to AppState's persisted pending queue (the
//      same path recordings use). The queued record is removed ONLY after
//      that store succeeds — and because retries reuse the same journalKey
//      (memory.store is an upsert by key), even a crash between store and
//      removal re-stores the SAME row on relaunch instead of duplicating it.
//   3. The queue is mirrored into memory for the serial worker, which
//      retries failed stores with backoff (attempts are persisted; they
//      reset on the next launch). When AppState attaches (its weak property
//      didSet), the persisted queue is loaded once and the worker starts —
//      so cold-launch and post-kill imports recover without user action.
//
// If the atomic queue write fails, the crash-safety promise is broken for
// that import and the status discloses it; the in-memory common path still
// proceeds. The external share-sheet source is only ever COPIED — never
// moved or deleted; imported audio is never deleted either, even when a
// store keeps failing. Audio never leaves the device; speech recognition is
// forced on-device.
//
// Concurrency: one serial Task owns the queue (earlier versions raced by
// spawning a Task per incoming URL). @MainActor isolation keeps enqueue/worker
// coordination thread-safe.

import Foundation
import UIKit

/// One pending import. `url` is the copied-into-Inbox destination (already on
/// disk). The queue is mirrored to Documents/pending_voice_imports.json after
/// every change, so an entry — and its retry budget — survive process death;
/// attempts reset on the next launch.
struct PendingVoiceMemo: Codable, Equatable {
    let url: URL
    let queuedAt: Date
    /// Stable journal key for the placeholder store. Assigned at enqueue
    /// time so every (re)store of this record UPSERTS one row — a crash
    /// after store but before queue removal cannot create a duplicate
    /// journal on relaunch. Optional for backward compatibility with queue
    /// JSON written before this field existed (missing → nil, assigned and
    /// persisted before the first store).
    var journalKey: String? = nil
    /// Consecutive failed journal-store attempts (drives retry backoff).
    var storeAttempts: Int = 0
}

@MainActor
final class VoiceMemoImporter: ObservableObject {
    @Published var isImporting = false
    @Published var status: String? = nil

    /// In-memory working copy of the durable queue. Every mutation goes
    /// through the enqueueItem/removeQueuedItem/updateQueuedItem helpers so
    /// the JSON shadow in Documents never diverges from what the worker sees.
    private var queue: [PendingVoiceMemo] = []
    private var worker: Task<Void, Never>? = nil

    /// How many times the worker retries a failed journal store before ending
    /// its drain pass. The item stays queued (and persisted); attempts reset
    /// on the next launch.
    private static let maxStoreAttempts = 3

    /// Source URLs handed to enqueue recently (absolute string → time). Guards
    /// double delivery of ONE share: on a cold launch the same URL can arrive
    /// via launchOptions[.url] AND SwiftUI's .onOpenURL (and potentially the
    /// app delegate), and iOS reuses the same copied-file path for every
    /// delivery. Without this, one share imported twice (each enqueue makes a
    /// fresh UUID-named copy → two journal entries).
    private var recentlyEnqueuedSources: [String: Date] = [:]
    /// How long a source URL counts as "already handed to us".
    private static let enqueueDedupWindow: TimeInterval = 15

    /// Durable shadow of `queue`, following the same convention as AppState's
    /// pending_transcriptions.json (a small JSON file in Documents).
    private static let queueFileURL: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("pending_voice_imports.json")
    }()
    @MainActor private static let queueEncoder = JSONEncoder()
    @MainActor private static let queueDecoder = JSONDecoder()

    /// Set once per process when the persisted queue has been merged in, so
    /// repeated AppState attachments don't clobber live in-memory state with
    /// a stale file.
    private var didLoadPersistedQueue = false

    /// Stable, collision-proof journal key. Keeps the `journal_<epoch>_vm`
    /// prefix shape (other code parses the leading epoch out of keys for
    /// sorting/date fallbacks); the UUID suffix makes every import unique.
    private static func makeJournalKey() -> String {
        "journal_\(Int(Date().timeIntervalSince1970))_vm_\(UUID().uuidString)"
    }

    private var inboxURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Copy a shared audio file URL into the workspace Inbox, durably queue
    /// it, and store it as a journal. Returns the destination URL, or nil if
    /// the source isn't an audio file / copy fails. Safe to call repeatedly;
    /// each accepted call imports exactly one item (same-share re-delivery is
    /// deduped within a short window).
    @discardableResult
    func enqueue(_ sourceURL: URL) -> URL? {
        // Prune expired entries, then ignore a re-delivery of a share we
        // accepted moments ago. Silently return nil WITHOUT touching `status`
        // — the first delivery is already importing; this is not an error.
        let sourceKey = sourceURL.absoluteString
        let now = Date()
        recentlyEnqueuedSources = recentlyEnqueuedSources.filter {
            now.timeIntervalSince($0.value) < Self.enqueueDedupWindow
        }
        if recentlyEnqueuedSources[sourceKey] != nil { return nil }

        guard let dest = copyAudio(sourceURL) else {
            // Surface the rejection so the user isn't left wondering why
            // "Preparing" finished with no result (the share sheet shows
            // "Preparing" while iOS copies, then nothing visible happened).
            status = "Couldn't import that file (unsupported audio type)."
            return nil
        }
        // Only record the source as handled once the copy actually landed —
        // a failed import stays retryable within the window.
        recentlyEnqueuedSources[sourceKey] = now

        // Persist the queued import BEFORE attempting any store. The stable
        // journalKey is fixed here so every future (re)store upserts one row.
        // From this point the intent is app-visible even across a process
        // kill — unless the atomic write fails, which the fall-through path
        // discloses.
        let item = PendingVoiceMemo(url: dest, queuedAt: Date(),
                                    journalKey: Self.makeJournalKey())
        let persisted = enqueueItem(item)

        // Common path: AppState attached → store the placeholder journal
        // right away. Once the store returns, the SQLite row — not this
        // queue — is the record, and the queued intent can be dropped.
        if let state = appState {
            let mediaURL = Self.documentsRelativePath(for: dest)
            if let key = storePlaceholderJournal(item, mediaURL: mediaURL) {
                removeQueuedItem(urlPath: dest.path)
                status = "Imported — transcribing"
                Task { await self.followUpAfterStore(state, key: key, mediaURL: mediaURL) }
                // Drain any backlog (cold launch / failed stores). A no-op
                // drain leaves `status` untouched, so this message survives.
                ensureWorker()
                return dest
            }
            // Store failed: the item is already persisted; the worker
            // retries it below.
        }

        // Cold launch (AppState not wired yet) or store failure: start the
        // worker to retry. The item is already durably queued — unless the
        // write failed, in which case say so: a crash before the store would
        // lose this import, so the user should keep the app open. The common
        // path proceeds either way (in-memory queue + SQLite still work).
        status = persisted
            ? "Importing\(queue.count > 1 ? " \(queue.count) voice memos" : " voice memo")…"
            : "Importing — couldn't save crash-safe retry info; keep SlowClaw open…"
        isImporting = true
        ensureWorker()
        return dest
    }

    private func copyAudio(_ sourceURL: URL) -> URL? {
        guard isAudioFile(sourceURL) else {
            status = "Import skipped: '\(sourceURL.pathExtension)' isn't an audio file."
            return nil
        }
        // Re-resolve security-scoped URLs (share-sheet imports are scoped).
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        // Timestamp keeps Inbox listings roughly chronological; the UUID makes
        // the name collision-proof (same-second imports, identical titles).
        let ts = Int(Date().timeIntervalSince1970)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let dest = inboxURL.appendingPathComponent("\(ts)-\(sanitize(base))-\(UUID().uuidString).\(ext)")
        do {
            // Copy ONLY. The source is an external file iOS owns (often a
            // temp file outside our sandbox) and must never be moved or
            // deleted by an import; a cross-volume move would do exactly
            // that, so it is intentionally not a fallback here.
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            status = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Store the placeholder journal row for a copied memo (title + linked
    /// audio, content = AppState.transcribingPlaceholder) under the record's
    /// STABLE journalKey. Returns the key on success; nil on failure (status
    /// is set; the copied file stays on disk and retryable). Because the key
    /// never changes per record and memory.store upserts by key, every retry
    /// is an idempotent upsert: a crash after a successful store but before
    /// queue removal re-writes the same row on relaunch — no duplicate. The
    /// `journal_<epoch>` prefix shape is preserved because other code parses
    /// the leading epoch out of keys for sorting/date fallbacks. Records from
    /// an older queue JSON (no key yet) get one assigned and persisted here,
    /// before the first store.
    private func storePlaceholderJournal(_ item: PendingVoiceMemo, mediaURL: String?) -> String? {
        guard let state = appState else { return nil }
        var item = item
        if item.journalKey == nil {
            item.journalKey = Self.makeJournalKey()
            updateQueuedItem(item) // persist before store so the key survives a crash
        }
        guard let key = item.journalKey else { return nil }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, h:mm a"
        let title = "Imported · \(f.string(from: Date()))"
        do {
            try state.memory.store(key: key,
                                   content: "\(title)\n\n\(AppState.transcribingPlaceholder)",
                                   category: "daily", sessionID: nil,
                                   source: "audio_imported", mediaURL: mediaURL)
            return key
        } catch {
            status = "Couldn't save an import: \(error.localizedDescription)"
            return nil
        }
    }

    /// Post-store follow-up: refresh the journal list and hand the audio to
    /// AppState's persisted pending-transcription queue (pending_
    /// transcriptions.json — survives app kills, drained newest-first at
    /// launch/foreground). Takes the state explicitly so a strong reference
    /// lives for the whole follow-up even if `appState` weaks out mid-flow.
    private func followUpAfterStore(_ state: AppState, key: String, mediaURL: String?) async {
        await state.refreshJournals()
        if let mediaPath = mediaURL {
            await state.enqueuePendingTranscription(key: key, mediaPath: mediaPath,
                                                    generateTitleAfter: false)
        }
    }

    /// Lazily start the single serial worker if it isn't already running. The
    /// worker drains `queue` newest-first, one file at a time. Items stay
    /// queued (in memory AND on disk) until their journal store succeeds, so
    /// an interruption mid-store never loses the import — and every retry
    /// upserts the SAME journal row via the record's stable journalKey.
    /// Retries use backoff; the Inbox file is never deleted, so a failing
    /// import stays recoverable.
    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            var importedCount = 0
            var skippedCount = 0
            while !Task.isCancelled {
                // Peek newest-first. The item deliberately STAYS queued while
                // it is processed; removal happens only after its store
                // succeeds (durable record kept until then).
                guard let next = queue.max(by: { $0.queuedAt < $1.queuedAt }) else { break }

                isImporting = true
                let remaining = queue.count - 1
                status = remaining == 0 ? "Importing…" : "Importing, \(remaining) more queued"

                // Cold launch: AppState attaches once the App finishes
                // launching (or via the appState didSet recovery). Surface
                // it, then wait and retry. The item itself is durably queued,
                // so even a process death here is recoverable.
                guard let state = appState else {
                    status = "Import queued — open SlowClaw to finish."
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                // Store the placeholder journal (durable once the store
                // returns), then hand transcription to AppState's persisted
                // pending queue. The user sees the memo in the Journal list
                // immediately, audio linked even if transcription is slow or
                // interrupted.
                var item = next
                let mediaURL = Self.documentsRelativePath(for: item.url)
                if let key = storePlaceholderJournal(item, mediaURL: mediaURL) {
                    importedCount += 1
                    // Durable removal — only after the store landed. If the
                    // queue write fails here it's benign: a relaunch reloads
                    // the record and re-stores the SAME journalKey (upsert).
                    removeQueuedItem(urlPath: item.url.path)
                    await followUpAfterStore(state, key: key, mediaURL: mediaURL)
                    continue
                }

                // Store failed: bump and persist the attempt (never delete
                // the file), back off, and after too many consecutive
                // failures end this pass — the item stays queued and
                // persisted for the next drain or the next launch.
                item.storeAttempts += 1
                updateQueuedItem(item)
                if item.storeAttempts < Self.maxStoreAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(item.storeAttempts) * 500_000_000)
                    continue
                }
                skippedCount += 1
                status = "Couldn't save an import — its audio file stays in the Inbox."
                break
            }
            // Final summary so the user sees the import landed. A drain that
            // processed nothing (started just to check a possibly-empty
            // backlog) intentionally leaves the current status untouched —
            // e.g. enqueue's "Imported — transcribing" must survive it.
            if importedCount > 0 {
                let noun = importedCount == 1 ? "voice memo" : "voice memos"
                status = "Imported \(importedCount) \(noun)\(skippedCount > 0 ? " (\(skippedCount) skipped)" : "") — transcribing"
            } else if skippedCount > 0 {
                status = "Import failed (\(skippedCount) file\(skippedCount == 1 ? "" : "s"))"
            }
            // Always false on worker exit — even when a failing item stays
            // queued: the spinner must never outlive the live worker.
            isImporting = false
        }
    }

    // MARK: - Durable queue bookkeeping

    /// Append an item to the queue and persist the queue (atomic write).
    /// Returns false when persistence failed — the caller promises durable
    /// intent at enqueue time and must disclose the failure (status).
    @discardableResult
    private func enqueueItem(_ item: PendingVoiceMemo) -> Bool {
        queue.append(item)
        return saveQueue()
    }

    /// Remove an item (matched by destination path) from the queue and
    /// persist. Called only after that item's journal store succeeded, so a
    /// failed persistence is benign: a relaunch reloads the record and its
    /// stable journalKey makes the re-store an idempotent upsert.
    @discardableResult
    private func removeQueuedItem(urlPath: String) -> Bool {
        queue.removeAll { $0.url.path == urlPath }
        return saveQueue()
    }

    /// Replace an item in place (retry-attempt / key assignment updates) and
    /// persist. Failure only rolls the bookkeeping back a step; the store
    /// itself is idempotent via the stable key.
    @discardableResult
    private func updateQueuedItem(_ item: PendingVoiceMemo) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.url.path == item.url.path }) else {
            return enqueueItem(item)
        }
        queue[idx] = item
        return saveQueue()
    }

    /// Rewrite the durable queue file in one atomic write. Returns whether
    /// persistence succeeded: false means the on-disk intent is stale until
    /// the next successful save, so callers relying on crash-safety must
    /// disclose it.
    @discardableResult
    private func saveQueue() -> Bool {
        guard let url = Self.queueFileURL else { return false }
        do {
            let data = try Self.queueEncoder.encode(queue)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Merge the persisted queue into memory exactly once per process,
    /// resetting retry attempts so a fresh launch gets a full retry budget,
    /// then normalize the file. Items already in memory (enqueued before
    /// AppState attached) win the dedup. Legacy records without a journalKey
    /// get one assigned and persisted here, before any store. Corrupt or
    /// unreadable files start fresh — worst case is losing recovery of
    /// pre-kill imports, never losing audio (Inbox files are never deleted).
    /// A failed normalize write is benign: keys would simply be re-assigned
    /// on the next load, before any store used them.
    private func loadPersistedQueueOnce() {
        guard !didLoadPersistedQueue else { return }
        didLoadPersistedQueue = true
        guard let url = Self.queueFileURL,
              let data = try? Data(contentsOf: url),
              let persisted = try? Self.queueDecoder.decode([PendingVoiceMemo].self, from: data)
        else { return }
        for var item in persisted {
            item.storeAttempts = 0
            if item.journalKey == nil {
                item.journalKey = Self.makeJournalKey()
            }
            if !queue.contains(where: { $0.url.path == item.url.path }) {
                queue.append(item)
            }
        }
        saveQueue()
    }

    /// Weak ref to AppState so the worker can store journals without retaining
    /// it. Set by the App when wiring up the importer. On attachment, recover
    /// anything persisted by a previous process (cold launch or a kill after
    /// copy but before store): load the durable queue once and start the
    /// worker. Idempotent — repeated attachments are no-ops.
    weak var appState: AppState? {
        didSet {
            guard appState != nil else { return }
            loadPersistedQueueOnce()
            ensureWorker()
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        // Keep in sync with Info.plist LSItemContentTypes. mp4 audio (e.g.
        // .m4a is the common case) is covered; .mov/.mp4 containers are video
        // and intentionally excluded here even though the share sheet accepts
        // public.mpeg4-audio — accept only audio-only extensions at runtime.
        let exts: Set<String> = ["m4a", "mp3", "aac", "wav", "flac", "caf", "aiff"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else { out.append("-") }
        }
        return out.isEmpty ? "voice-memo" : out
    }

    /// Documents-relative path for an imported file, suitable for the journal
    /// media_url column (e.g. "Inbox/1725000000-memo-<UUID>.m4a").
    static func documentsRelativePath(for url: URL) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let docsPath = docs.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(docsPath) else { return nil }
        let rel = String(urlPath.dropFirst(docsPath.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }
}
