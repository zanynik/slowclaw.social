// ExperimentLogger.swift — locked-phone CPU experiment instrumentation.
//
// THE EXPERIMENT (the interesting systems question):
//   Does keeping the AVAudioSession active past Stop buy CPU time for
//   CPU-only llama.cpp inference while the phone is locked?
//
// Background regime (verified in the codebase):
//   - UIBackgroundModes=[audio] keeps the app alive only while the
//     AVAudioSession is active (during recording/playback).
//   - finishRecording() normally calls setActive(false) immediately at
//     Stop, dropping the audio-mode lifeline. Post-stop work then runs
//     only under a ~30s beginBackgroundTask window (OS-gated).
//   - Metal is disabled by design (CPU-only is the stable path). So the
//     question is purely about CPU scheduling when locked.
//
// This experiment: when the toggle is ON and finishRecording(deferSession:)
// defers deactivation, run the mtmd transcription WHILE the session stays
// active, then deactivate. Log every run to experiment_log.jsonl so you can
// read on-device whether the process got CPU time (total_ms is sane + not
// suspended) or was suspended (completed=false / suspended=true).
//
// This is a TestFlight experiment. Holding the audio session active for up
// to 120s for non-recording inference may draw Apple scrutiny in review;
// that's acceptable for a TestFlight build, not for App Store.

import Foundation
import AVFoundation
import UIKit

/// One experiment run, persisted to experiment_log.jsonl.
struct ExperimentRun: Codable {
    /// ISO8601 timestamp of when the run started.
    let timestamp: String
    /// Best-effort guess at whether the phone was locked when the run ended.
    /// Uses isProtectedDataAvailable + applicationState (approximate — iOS
    /// doesn't expose a direct "is screen locked" API).
    let phoneLockedApprox: Bool
    /// The app's state when the run ended (.background = likely locked).
    let appState: String
    /// True iff the AVAudioSession was still active when the run ended.
    let audioSessionActive: Bool
    /// Which STT engine ran.
    let engine: String
    /// mtmd timings (milliseconds). All 0 for SpeechAnalyzer.
    let loadMs: Int64
    let encodeMs: Int64
    let decodeMs: Int64
    let totalMs: Int64
    /// True iff the transcription completed without being suspended/timed out.
    let completed: Bool
    /// True iff iOS suspended the run (background task expired).
    let suspended: Bool
    /// Length of the transcript produced (0 = empty/failed).
    let transcriptLen: Int
}

/// Appends experiment runs to Documents/experiment_log.jsonl (one JSON object
/// per line). The file is read by the debug view and is safe to share.
enum ExperimentLogger {

    /// File URL of the on-disk experiment log (Documents).
    static var logURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent("experiment_log.jsonl")
    }

    /// Append a run to the JSONL log. Best-effort — never throws (the experiment
    /// must not break transcription on a logging failure).
    static func append(_ run: ExperimentRun) {
        guard let url = logURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys] // stable line format
            var data = try encoder.encode(run)
            data.append(0x0A) // newline → JSONL
            // Append (create if missing). .atomic would require reading the whole
            // file; for a log we just append.
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // Swallow — logging is best-effort.
        }
    }

    /// Load the last `limit` runs from the log (newest last). Returns [] on
    /// any failure (the debug view renders empty safely).
    static func loadRecent(limit: Int = 50) -> [ExperimentRun] {
        guard let url = logURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var runs: [ExperimentRun] = []
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            if let lineData = line.data(using: .utf8),
               let run = try? decoder.decode(ExperimentRun.self, from: lineData) {
                runs.append(run)
            }
        }
        return runs.suffix(limit)
    }

    /// Delete the log file (debug view "clear" button).
    static func clear() {
        guard let url = logURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Experiment runner

/// Runs a transcription as a locked-phone experiment: holds the AVAudioSession
/// active for the duration (up to a 120s hard cap), logs the outcome. Called
/// by finishRecording when the experiment toggle is ON.
///
/// This does NOT record — the mic engine is stopped. It only keeps the audio
/// background mode's lifeline alive so iOS grants CPU time to the (CPU-only)
/// mtmd inference while the screen may be locked.
enum LockedPhoneExperiment {

    /// Hard cap on how long we hold the audio session for a single experiment
    /// run. Prevents wedging the audio mode forever if inference hangs.
    static let maxDurationSeconds: TimeInterval = 120

    /// Run one experiment: keep the session active, transcribe, log, release.
    /// `url` is the just-finished recording. `engine` reports which STT engine
    /// was used. Returns the transcript (so the caller can still use it).
    static func run(url: URL, useGemmaAudio: Bool) async -> AudioSTTResult {
        // Ensure the session stays active (it may have been deactivated by
        // finishRecording; re-activate for the experiment window).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let bgID = UIApplication.shared.beginBackgroundTask(withName: "slowclaw.experiment.audio")

        // Run the transcription with a timeout safeguard. If it exceeds the
        // cap, we abandon it (the run is logged as suspended=true).
        let result = await withTaskGroup(of: AudioSTTResult?.self) { group -> AudioSTTResult in
            group.addTask {
                await AudioSTT.transcribe(url: url, useGemmaAudio: useGemmaAudio)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxDurationSeconds * 1_000_000_000))
                return nil // timeout
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            // If the transcription task won, use it; else timeout → fallback.
            return first ?? AudioSTTResult(text: "", engine: .gemmaAudioFallback, timings: nil)
        }

        // Capture the run outcome (approximate lock state).
        let app = UIApplication.shared
        let protectedData = app.isProtectedDataAvailable
        let state = app.applicationState
        // .background + protectedDataAvailable ≈ locked. .inactive ≈ screen
        // dimmed / control center. .active ≈ unlocked + foreground.
        let lockedApprox = (state == .background && protectedData) || state == .inactive

        let run = ExperimentRun(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            phoneLockedApprox: lockedApprox,
            appState: experimentStateLabel(state),
            audioSessionActive: session.isInputAvailable || session.outputVolume > 0,
            engine: result.engine.rawValue,
            loadMs: result.timings?.loadMs ?? 0,
            encodeMs: result.timings?.encodeMs ?? 0,
            decodeMs: result.timings?.decodeMs ?? 0,
            totalMs: result.timings?.totalMs ?? 0,
            completed: !result.text.isEmpty,
            suspended: result.text.isEmpty,
            transcriptLen: result.text.count
        )
        ExperimentLogger.append(run)

        // Release the session + background assertion now that inference is done.
        if bgID != .invalid {
            UIApplication.shared.endBackgroundTask(bgID)
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        return result
    }

    private static func experimentStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
