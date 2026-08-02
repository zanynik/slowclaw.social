// VoiceMemoImporter.swift — import shared voice memos and transcribe them.
//
// Mirrors the reference app's importAndTranscribeVoiceMemos (web/src/App.tsx)
// + importVoiceMemos (web/src-tauri/src/lib.rs), but in pure Swift: no Tauri,
// no Rust gateway. When iOS delivers a shared audio file (Voice Memos → Share
// → "Copy to SlowClaw"), it arrives as a file URL via .onOpenURL on the App.
//
// Flow:
//   1. enqueue(_:) copies the shared file into Documents/Inbox with a unique
//      timestamped name (so re-imports don't collide) and appends it to a
//      single serial queue owned by this importer.
//   2. A long-lived Task drains the queue one file at a time (newest-first),
//      transcribing each off the main actor with SFSpeechURLRecognitionRequest,
//      FORCING on-device recognition (no cloud fallback — see hardening note).
//   3. Each finished transcript is published via `pendingTranscript`; the App
//      observes it and presents an edit/preview step (same TranscriptSheet
//      live recordings use), instead of auto-storing. Audio never leaves the
//      device.
//
// Hardening (vs. the original auto-store design):
//   - Serial queue: previously every incoming URL appended to a shared array
//     AND spawned a fresh Task that transcribed the whole array, so two files
//     shared in quick succession were double-transcribed and a later task
//     could clear items an earlier task hadn't processed. Now one Task owns
//     the queue; enqueue is O(1) and thread-safe via @MainActor isolation.
//   - On-device speech: `requiresOnDeviceRecognition = true` (was false). If
//     the locale lacks on-device support, the import surfaces a clear status
//     instead of silently sending audio to Apple servers. Aligns with the
//     local-first vision contract and the NSSpeechRecognitionUsageDescription
//     copy ("on-device speech recognition").
//   - Edit step: imported transcripts are no longer auto-stored; the caller
//     decides whether to save (matching the live-recording UX).

import Foundation
import AVFoundation
import Speech

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

    /// A freshly-transcribed import awaiting user review, or nil. The App
    /// observes this via `.onChange` and presents TranscriptSheet when set to
    /// a non-empty value. Set back to nil after the sheet saves/cancels.
    @Published var pendingTranscript: String? = nil

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
    /// for transcription. Returns the destination URL, or nil if the source
    /// isn't an audio file / copy fails. Safe to call repeatedly; each call
    /// appends one item and ensures the single serial worker is running.
    @discardableResult
    func enqueue(_ sourceURL: URL) -> URL? {
        guard let dest = copyAudio(sourceURL) else { return nil }
        // Dedup: don't enqueue the same destination twice (share sheet can
        // re-deliver). Compare by path.
        if !queue.contains(where: { $0.url.path == dest.path }) {
            queue.append(PendingVoiceMemo(url: dest, queuedAt: Date()))
        }
        ensureWorker()
        return dest
    }

    private func copyAudio(_ sourceURL: URL) -> URL? {
        guard isAudioFile(sourceURL) else { return nil }
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
            try? FileManager.default.moveItem(at: sourceURL, to: dest)
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        }
    }

    /// Lazily start the single serial worker if it isn't already running.
    /// The worker drains `queue` newest-first, one file at a time, until empty.
    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            while !Task.isCancelled {
                // Snapshot + sort newest-first by queue time, pick the next.
                guard let next = queue.max(by: { $0.queuedAt < $1.queuedAt }) else { break }
                queue.removeAll { $0.url.path == next.url.path }

                isImporting = true
                let remaining = queue.count
                status = remaining == 0 ? "Transcribing…" : "Transcribing, \(remaining) more queued"

                let transcript = await transcribeFile(next.url) ?? ""
                // Hand the transcript to the App for review/edit. Only present
                // if there's something to show; failures keep the status msg.
                if !transcript.isEmpty {
                    pendingTranscript = transcript
                    // Wait for the UI to consume this one before pulling the
                    // next file, so sheets don't stack / overwrite each other.
                    while pendingTranscript != nil && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
            }
            status = nil
            isImporting = false
        }
    }

    /// Transcribe one audio file via SFSpeechURLRecognitionRequest, forcing
    /// on-device recognition. Returns the full transcript, or nil.
    private func transcribeFile(_ url: URL) async -> String? {
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer = recognizer, recognizer.isAvailable else {
            status = "Speech recognition unavailable."
            return nil
        }
        // On-device gate: refuse to fall back to cloud (local-first).
        if #available(iOS 13, *), !SFSpeechRecognizer.supportsOnDeviceRecognition(for: Locale.current) {
            status = "On-device speech not downloaded for this language. Add it in Settings → Accessibility → Spoken Content."
            return nil
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if #available(iOS 13, *) { request.requiresOnDeviceRecognition = true }
            request.taskHint = .dictation
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    cont.resume(returning: nil)
                    return
                }
                if let result = result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if result == nil {
                    cont.resume(returning: nil)
                }
            }
            // Fallback timeout: long audio files can take a while, but never hang.
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                if task.state != .completed && task.state != .canceling {
                    task.cancel()
                    cont.resume(returning: nil)
                }
            }
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
}
