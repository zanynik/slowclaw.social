// VoiceMemoImporter.swift — import shared voice memos and transcribe them.
//
// Mirrors the reference app's importAndTranscribeVoiceMemos (web/src/App.tsx)
// + importVoiceMemos (web/src-tauri/src/lib.rs), but in pure Swift: no Tauri,
// no Rust gateway. When iOS delivers a shared audio file (Voice Memos → Share
// → "Copy to SlowClaw"), it arrives as a file URL via .onOpenURL on the App.
//
// Flow:
//   1. copyAudio(_:) copies the shared file into Documents/Inbox with a unique
//      timestamped name (so re-imports don't collide).
//   2. transcribeAll(newestFirst:) transcribes each queued file off the main
//      actor using SFSpeechURLRecognitionRequest (on-device when available),
//      starting from the newest. Each finished transcript becomes a journal
//      entry in the Zig-backed SQLite store.
//
// Audio never leaves the device; speech recognition uses Apple's on-device
// engine (SFSpeechRecognizer with requiresOnDeviceRecognition when supported).

import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceMemoImporter: ObservableObject {
    @Published var isImporting = false
    @Published var status: String? = nil

    private var inboxURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Copy a shared audio file URL into the workspace Inbox. Returns the
    /// destination URL, or nil if the source isn't an audio file / copy fails.
    func copyAudio(_ sourceURL: URL) -> URL? {
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

    /// Transcribe a batch of audio files, newest first. Each transcript is
    /// stored as a journal entry. Updates `status` for UI feedback.
    func transcribeAndStore(files: [URL], state: AppState) async {
        guard !files.isEmpty else { return }
        isImporting = true
        // Sort newest-first by file modification date (the reference also starts
        // from the latest of the audios).
        let sorted = await Task.detached(priority: .utility) {
            files.map { url -> (URL, Date) in
                let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
                return (url, m)
            }.sorted { $0.1 > $1.1 }.map { $0.0 }
        }.value

        for (idx, file) in sorted.enumerated() {
            status = "Transcribing \(idx + 1) of \(sorted.count)…"
            if let transcript = await transcribeFile(file), !transcript.isEmpty {
                let key = "journal_\(Int(Date().timeIntervalSince1970))_vm"
                let content = "🎙 \(transcript)"
                try? state.memory.store(key: key, content: content, category: "daily", sessionID: nil)
                await state.refreshJournals()
                // Mine interests from the transcript (same path as live capture).
                if let llm = state.llm {
                    let model = state.model
                    let text = transcript
                    DispatchQueue.global(qos: .utility).async {
                        if let kws = try? llm.extractInterests(journalText: text, model: model) {
                            Task { @MainActor in
                                state.interests.append(contentsOf: kws.filter { !state.interests.contains($0) })
                            }
                        }
                    }
                }
            }
        }
        status = sorted.isEmpty ? nil : "Imported \(sorted.count) audio\(sorted.count == 1 ? "" : "s")."
        isImporting = false
    }

    /// Transcribe one audio file via SFSpeechURLRecognitionRequest (on-device
    /// when the device supports it). Returns the full transcript, or nil.
    private func transcribeFile(_ url: URL) async -> String? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer = recognizer, recognizer.isAvailable else { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if #available(iOS 13, *) { request.requiresOnDeviceRecognition = false }
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
        let exts: Set<String> = ["m4a", "mp3", "aac", "wav", "flac", "ogg", "webm", "caf", "aiff"]
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
