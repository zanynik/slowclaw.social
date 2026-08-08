// VoiceMemoImporter.swift — import shared voice memos and transcribe them.
//
// Mirrors the reference app's importAndTranscribeVoiceMemos (web/src/App.tsx):
// when iOS delivers a shared audio file (Voice Memos → Share → "Copy to
// SlowClaw"), it arrives as a file URL via .onOpenURL on the App.
//
// Flow:
//   1. enqueue(_:) copies the shared file into Documents/Inbox with a unique
//      timestamped name and appends it to a single serial queue.
//   2. A long-lived Task drains the queue one file at a time, transcribing
//      each on-device via SpeechTranscriber (which segments long audio to
//      dodge SFSpeech's ~1-min per-task limit) and AUTO-STORES the result as
//      a journal entry. No review gate — the user edits from the Journals
//      list afterward, exactly like the reference app.
//   3. The audio file is ALWAYS linked via source="audio_imported" + media_url,
//      even when on-device speech is unavailable (the entry then stores a
//      placeholder). Nothing copied to the Inbox is ever silently dropped.
//
// Audio never leaves the device. Speech recognition is forced on-device.
//
// Concurrency: one serial Task owns the queue (earlier versions raced by
// spawning a Task per incoming URL). @MainActor isolation keeps enqueue/worker
// coordination thread-safe.

import Foundation
import UIKit

/// One pending import. `url` is the copied-into-Inbox destination (already
/// on disk, so it survives app backgrounding/crash before transcription).
struct PendingVoiceMemo: Equatable {
    let url: URL
    let queuedAt: Date
}

@MainActor
final class VoiceMemoImporter: ObservableObject {
    @Published var isImporting = false
    @Published var status: String? = nil

    private var queue: [PendingVoiceMemo] = []
    private var worker: Task<Void, Never>? = nil

    private var inboxURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Copy a shared audio file URL into the workspace Inbox and enqueue it
    /// for transcription + auto-store. Returns the destination URL, or nil if
    /// the source isn't an audio file / copy fails. Safe to call repeatedly;
    /// each call appends one item and ensures the single serial worker runs.
    @discardableResult
    func enqueue(_ sourceURL: URL) -> URL? {
        guard let dest = copyAudio(sourceURL) else {
            // Surface the rejection so the user isn't left wondering why
            // "Preparing" finished with no result (the share sheet shows
            // "Preparing" while iOS copies, then nothing visible happened).
            status = "Couldn't import that file (unsupported audio type)."
            return nil
        }
        // Dedup: don't enqueue the same destination twice (share sheet can
        // re-deliver). Compare by path.
        if !queue.contains(where: { $0.url.path == dest.path }) {
            queue.append(PendingVoiceMemo(url: dest, queuedAt: Date()))
        }
        // Immediate feedback the moment the file lands — don't wait for the
        // worker to start transcribing before telling the user it worked.
        status = "Importing\(queue.count > 1 ? " \(queue.count) voice memos" : " voice memo")…"
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

        let ts = Int(Date().timeIntervalSince1970)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let dest = inboxURL.appendingPathComponent("\(ts)-\(sanitize(base)).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            // Fall back to a move if copy fails across volumes.
            do {
                try FileManager.default.moveItem(at: sourceURL, to: dest)
                return dest
            } catch {
                status = "Import failed: \(error.localizedDescription)"
                return nil
            }
        }
    }

    /// Lazily start the single serial worker if it isn't already running.
    /// The worker drains `queue` newest-first, one file at a time, transcribing
    /// each on-device (via SpeechTranscriber, which segments long audio to dodge
    /// SFSpeech's ~1-min limit) and auto-storing the result as a journal —
    /// matching the reference app (no review gate).
    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            var importedCount = 0
            var skippedCount = 0
            while !Task.isCancelled {
                // Snapshot + sort newest-first by queue time, pick the next.
                guard let next = queue.max(by: { $0.queuedAt < $1.queuedAt }) else { break }
                queue.removeAll { $0.url.path == next.url.path }

                isImporting = true
                let remaining = queue.count
                status = remaining == 0 ? "Transcribing…" : "Transcribing, \(remaining) more queued"

                // Guard: if AppState isn't wired yet (cold launch from share
                // sheet), surface it instead of silently no-op-ing the store.
                guard let state = appState else {
                    status = "Import queued — open SlowClaw to finish."
                    // Wait briefly for appState to attach, then retry this file.
                    queue.append(next)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                // Transcribe off the main actor (SpeechAnalyzer recognition is
                // blocking). SpeechTranscriber returns "" if on-device speech
                // is unavailable for the locale. Wrap in a background-task
                // assertion so iOS grants CPU time to finish if the app
                // backgrounds mid-import (~30s).
                let url = next.url
                let bgID = UIApplication.shared.beginBackgroundTask(withName: "slowclaw.voiceMemo.import")
                let transcript = await Task.detached(priority: .userInitiated) {
                    await Transcriber.transcribe(url: url)
                }.value
                if bgID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgID)
                }

                // Auto-store: the file is on disk and must become a journal
                // entry regardless of whether speech produced text. The user
                // edits from the Journals list afterward (like the reference).
                let content = transcript.isEmpty ? "🎙 Imported audio (no transcript)" : transcript
                let mediaURL = Self.documentsRelativePath(for: next.url)
                let key = "journal_\(Int(Date().timeIntervalSince1970))_vm"
                do {
                    try state.memory.store(key: key, content: content, category: "daily",
                                           sessionID: nil, source: "audio_imported", mediaURL: mediaURL)
                    importedCount += 1
                    await state.refreshJournals()
                } catch {
                    skippedCount += 1
                    status = "Couldn't save an import: \(error.localizedDescription)"
                }
            }
            // Final summary so the user sees the import landed (the "Preparing
            // then nothing" symptom was the absence of this acknowledgment).
            if importedCount > 0 {
                let noun = importedCount == 1 ? "voice memo" : "voice memos"
                status = "Imported \(importedCount) \(noun)\(skippedCount > 0 ? " (\(skippedCount) skipped)" : "")"
            } else if skippedCount > 0 {
                status = "Import failed (\(skippedCount) file\(skippedCount == 1 ? "" : "s"))"
            } else {
                status = nil
            }
            isImporting = false
        }
    }

    /// Weak ref to AppState so the worker can store journals without retaining
    /// it. Set by the App when wiring up the importer.
    weak var appState: AppState?

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
    /// media_url column (e.g. "Inbox/123-name.m4a").
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
