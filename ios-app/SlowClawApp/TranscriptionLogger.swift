// TranscriptionLogger.swift — durable transcription observability and the
// optional locked-phone execution experiment.

import Foundation
import AVFoundation
import UIKit

extension Notification.Name {
    static let slowClawTranscriptionRunAdded = Notification.Name(
        "com.slowclaw.app.transcription-run-added")
}

/// One real file-transcription run shown in Profile → Audio Transcription.
struct TranscriptionRun: Codable, Identifiable {
    let id: String
    let timestamp: String
    let context: AudioSTTContext
    let requestedEngine: String
    let engine: String
    let succeeded: Bool
    let detail: String
    let audioSeconds: Double
    let segmentCount: Int
    let loadMs: Int64
    let encodeMs: Int64
    let decodeMs: Int64
    let totalMs: Int64
    let transcriptLen: Int

    init(context: AudioSTTContext, requestedEngine: String, engine: String,
         succeeded: Bool, detail: String, audioSeconds: Double,
         segmentCount: Int, loadMs: Int64, encodeMs: Int64,
         decodeMs: Int64, totalMs: Int64, transcriptLen: Int) {
        self.id = UUID().uuidString
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.context = context
        self.requestedEngine = requestedEngine
        self.engine = engine
        self.succeeded = succeeded
        self.detail = detail
        self.audioSeconds = audioSeconds
        self.segmentCount = segmentCount
        self.loadMs = loadMs
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.totalMs = totalMs
        self.transcriptLen = transcriptLen
    }
}

/// JSONL audit log for every automatic and manual transcription. The log never
/// contains transcript text — only routing, timings, lengths, and errors.
enum TranscriptionLogger {
    private static let lock = NSLock()

    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("transcription_runs.jsonl")
    }

    static func append(_ run: TranscriptionRun) {
        guard let url = logURL else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(run)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .slowClawTranscriptionRunAdded,
                                                object: nil)
            }
        } catch {
            // Diagnostics must never break or delay journal persistence.
        }
    }

    static func loadRecent(limit: Int = 30) -> [TranscriptionRun] {
        guard let url = logURL else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let runs = text.split(separator: "\n").compactMap { line -> TranscriptionRun? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(TranscriptionRun.self, from: data)
        }
        return Array(runs.suffix(limit))
    }

    static func clear() {
        guard let url = logURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Optional locked-phone execution experiment

enum LockedPhoneExperiment {
    static let maxDurationSeconds: TimeInterval = 10 * 60

    /// Hold the audio session while mtmd/Apple processes the just-recorded
    /// file. AudioSTT writes the same observable run as every other path.
    static func run(url: URL, useGemmaAudio: Bool,
                    progress: (@Sendable (String) -> Void)? = nil) async -> AudioSTTResult {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let bgID = UIApplication.shared.beginBackgroundTask(
            withName: "slowclaw.experiment.audio")

        let result = await withTaskGroup(of: AudioSTTResult?.self) { group -> AudioSTTResult in
            group.addTask {
                await AudioSTT.transcribe(url: url, useGemmaAudio: useGemmaAudio,
                                          context: .lockedPhone, progress: progress)
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(maxDurationSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? AudioSTTResult(
                text: "", engine: .gemmaAudio, timings: nil,
                diagnostic: "Locked-phone transcription exceeded the time limit.",
                segmentCount: 0)
        }

        if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return result
    }
}
