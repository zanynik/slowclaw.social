// SpeechTranscriber.swift — on-device transcription of an audio file.
//
// Ports the proven segmentation logic from the reference Tauri app's
// web/src-tauri/ios/SpeechTranscriber/SpeechTranscriber.swift. On-device
// SFSpeechRecognizer has a hard ~60-second limit per recognitionTask; for
// files longer than that a single request can be truncated or fail silently.
// Fix: split the file into ≤50s segments and run one SFSpeechURLRecognitionRequest
// per segment, concatenating the finals.
//
// Audio never leaves the device (requiresOnDeviceRecognition = true). If the
// locale lacks on-device support, returns an empty string (the caller decides
// whether to store the audio without a transcript).

import Foundation
import AVFoundation
import Speech

/// On-device transcription of an audio file at `url`. Returns the concatenated
/// transcript, or "" if no speech was recognized / on-device unavailable.
///
/// Thread-safe: runs the blocking semaphore-based recognition on the calling
/// thread. Callers should `await` it off the main actor (e.g. inside a
/// `Task.detached` or `Task { await ... }` from MainActor).
enum SpeechTranscriber {
    /// Max segment length. Well below the ~60s per-task SFSpeech ceiling with
    /// margin (40s) so even a slow recognizer can finish before the cap.
    private static let segmentSeconds: TimeInterval = 40
    /// Per-segment safety timeout so a stuck recognizer can't wedge a batch.
    private static let segmentTimeout: Int = 180
    /// Last diagnostic: how many segments were processed. Observable for
    /// surfacing in the UI / status when debugging truncation.
    @MainActor static var lastSegmentCount: Int = 0

    /// Outcome of recognizing a single segment.
    private enum SegmentOutcome {
        case text(String)
        case noSpeech
        case error
        case timedOut
    }

    static func transcribe(url: URL) async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            // No on-device model for this locale — can't transcribe locally.
            return ""
        }

        // Start security-scoped access (share-sheet URLs may need it).
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Decide whether to segment. We must split long audio because on-device
        // SFSpeechRecognizer truncates a single recognitionTask to ~60s. Decide
        // from the FRAME COUNT (via AVAudioFile.length), NOT from the container's
        // duration metadata: m4a files written live by AVAudioFile often lack a
        // readable duration track immediately after close, so audioDuration-
        // Seconds returns 0 and segmentation never triggers — that was the root
        // cause of "only the last few lines were transcribed." Frame count is
        // deterministic and container-independent.
        let needsSegmenting: Bool
        if let probe = try? AVAudioFile(forReading: url) {
            let sampleRate = probe.processingFormat.sampleRate
            let totalFrames = probe.length
            if sampleRate > 0 {
                let duration = Double(totalFrames) / sampleRate
                needsSegmenting = duration > segmentSeconds
            } else {
                // Fallback: if the format is unreadable, trust container metadata.
                needsSegmenting = audioDurationSeconds(url) > segmentSeconds
            }
        } else {
            // Can't open to probe — try container duration, else single-shot.
            needsSegmenting = audioDurationSeconds(url) > segmentSeconds
        }

        var tempDir: URL? = nil
        let segmentURLs: [URL]
        if needsSegmenting {
            let (segs, dir) = splitAudioIntoSegments(url, maxSeconds: segmentSeconds)
            segmentURLs = segs
            tempDir = dir
        } else {
            segmentURLs = [url]
        }
        defer {
            if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        }

        guard !segmentURLs.isEmpty else {
            await MainActor.run { Self.lastSegmentCount = 0 }
            return ""
        }

        // Recognize each segment sequentially, concatenating finals.
        var parts: [String] = []
        for segmentURL in segmentURLs {
            switch recognizeSingleSegment(at: segmentURL, with: recognizer) {
            case .text(let s):
                parts.append(s)
            case .noSpeech:
                continue  // skip empty segments; don't fail the whole transcript
            case .error, .timedOut:
                // A bad segment shouldn't abort the rest; keep what we have.
                continue
            }
        }
        await MainActor.run { Self.lastSegmentCount = segmentURLs.count }
        return parts.joined(separator: " ")
    }

    // MARK: - Helpers (ported from the reference SpeechTranscriber.swift)

    /// Read the playback duration of an audio file in seconds. Returns 0 if it
    /// cannot be determined (caller then takes the single-file path).
    private static func audioDurationSeconds(_ url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .audio).first {
            let duration = track.timeRange.duration
            if duration.isValid, !duration.isIndefinite {
                return CMTimeGetSeconds(duration)
            }
        }
        let duration = asset.duration
        if duration.isValid, !duration.isIndefinite {
            return CMTimeGetSeconds(duration)
        }
        return 0
    }

    /// Split an audio file into ≤`maxSeconds` segments written as temporary
    /// `.caf` files. Returns `(segmentURLs, tempDir)`; the caller removes
    /// `tempDir`. Returns `([], nil)` if the source can't be opened.
    private static func splitAudioIntoSegments(_ sourceURL: URL, maxSeconds: TimeInterval) -> ([URL], URL?) {
        guard let audioFile = try? AVAudioFile(forReading: sourceURL) else {
            return ([], nil)
        }
        let processingFormat = audioFile.processingFormat
        let totalFrames = AVAudioFramePosition(audioFile.length)
        guard totalFrames > 0 else { return ([], nil) }
        let sampleRate = processingFormat.sampleRate
        let framesPerSegment = AVAudioFramePosition(maxSeconds * sampleRate)
        guard framesPerSegment > 0 else { return ([], nil) }
        let segmentCount = Int((totalFrames + framesPerSegment - 1) / framesPerSegment)

        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slowclaw-transcribe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            return ([], nil)
        }

        var segmentURLs: [URL] = []
        var startFrame: AVAudioFramePosition = 0
        for index in 0..<segmentCount {
            let remaining = totalFrames - startFrame
            let chunkFrames = AVAudioFrameCount(min(framesPerSegment, remaining))
            guard chunkFrames > 0 else { break }
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else { break }
            do {
                audioFile.framePosition = startFrame
                try audioFile.read(into: readBuffer, frameCount: chunkFrames)
            } catch {
                break
            }
            let segmentURL = sessionDir.appendingPathComponent("segment-\(index).caf")
            do {
                // Write as CAF in the processing format — lossless and reliably
                // accepted by SFSpeechURLRecognitionRequest.
                let outFile = try AVAudioFile(
                    forWriting: segmentURL,
                    settings: processingFormat.settings,
                    commonFormat: processingFormat.commonFormat,
                    interleaved: processingFormat.isInterleaved
                )
                try outFile.write(from: readBuffer)
            } catch {
                break
            }
            segmentURLs.append(segmentURL)
            startFrame += AVAudioFramePosition(chunkFrames)
        }
        return (segmentURLs, sessionDir)
    }

    /// Run one recognition task on a single segment URL. Captures the
    /// best-transcription text from EVERY result callback (iOS often delivers
    /// the full text in a non-`isFinal` result, then ends with `result == nil`),
    /// so the prior version that only read `isFinal` results returned nothing
    /// for most segments — the root cause of "only the last sentence."
    /// A 0.8s settle after the last result lets late finals arrive.
    private static func recognizeSingleSegment(
        at url: URL,
        with recognizer: SFSpeechRecognizer
    ) -> SegmentOutcome {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let resultSemaphore = DispatchSemaphore(value: 0)
        final class ResultBox {
            var text: String?
            var error: Error?
        }
        let box = ResultBox()
        let settleQueue = DispatchQueue.global(qos: .userInitiated)
        let settleTimer = DispatchSource.makeTimerSource(queue: settleQueue)
        var signaled = false
        let signalOnce: () -> Void = {
            if !signaled {
                signaled = true
                resultSemaphore.signal()
            }
        }
        settleTimer.schedule(deadline: .now() + .seconds(segmentTimeout), repeating: .never)
        settleTimer.setEventHandler { signalOnce() }
        settleTimer.activate()
        func rearmSettle(_ delay: TimeInterval) {
            settleTimer.schedule(deadline: .now() + delay, repeating: .never)
        }

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                box.error = error
                settleTimer.cancel()
                signalOnce()
                return
            }
            if let result = result {
                // Capture the full running transcript from EVERY result, final
                // or not. iOS frequently delivers the complete text in a
                // non-final result and then signals end via result == nil;
                // reading only isFinal misses it entirely.
                let text = result.bestTranscription.formattedString
                if !text.isEmpty { box.text = text }
                if result.isFinal {
                    // Final result: arm a short settle for any straggler, then done.
                    rearmSettle(0.8)
                }
            } else {
                // result == nil, error == nil → recognition finished. Done.
                settleTimer.cancel()
                signalOnce()
            }
        }

        let waitResult = resultSemaphore.wait(timeout: .now() + .seconds(segmentTimeout))
        if waitResult == .timedOut {
            task.cancel()
            return .timedOut
        }
        if box.error != nil {
            return .error
        }
        guard let transcript = box.text, !transcript.isEmpty else {
            return .noSpeech
        }
        return .text(transcript)
    }
}
