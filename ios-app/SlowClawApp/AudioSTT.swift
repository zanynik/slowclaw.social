// AudioSTT.swift — shared Apple on-device speech-to-text path.
//
// SpeechAnalyzer is the only transcription engine. Keeping speech separate
// from the local text model avoids a second multi-gigabyte download and lets
// journals, drafts, and Reads use Gemma independently of audio processing.

import Foundation
import AVFoundation

/// Why a file transcription was started. Persisted in Recent Runs.
enum AudioSTTContext: String, Codable {
    case automatic = "Automatic journal"
    case retranscribe = "Re-transcribe"
    case lockedPhone = "Locked-phone test"
}

struct AudioSTTResult {
    let text: String
    let engine: AudioSTTEngine
    let diagnostic: String?
    let segmentCount: Int
}

enum AudioSTTEngine: String {
    case appleSpeech = "Apple Speech (on-device)"
}

enum AudioSTT {
    static func transcribe(
        url: URL,
        context: AudioSTTContext = .automatic,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> AudioSTTResult {
        let started = DispatchTime.now().uptimeNanoseconds
        progress?("Running Apple's long-form on-device transcription…")
        let text = await Transcriber.transcribe(url: url)
        let result = AudioSTTResult(
            text: text,
            engine: .appleSpeech,
            diagnostic: text.isEmpty
                ? "Apple's on-device recognizer produced no transcript."
                : "Apple's long-form on-device recognizer completed.",
            segmentCount: 1)

        let elapsedMs = Int64((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        progress?(text.isEmpty ? "Transcription will retry automatically." : "Transcription completed.")
        TranscriptionLogger.append(TranscriptionRun(
            context: context,
            requestedEngine: "Apple Speech",
            engine: result.engine.rawValue,
            succeeded: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            detail: result.diagnostic ?? "",
            audioSeconds: audioDurationSeconds(url: url) ?? 0,
            segmentCount: result.segmentCount,
            loadMs: 0,
            encodeMs: 0,
            decodeMs: 0,
            totalMs: elapsedMs,
            transcriptLen: text.count))
        return result
    }

    private static func audioDurationSeconds(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
