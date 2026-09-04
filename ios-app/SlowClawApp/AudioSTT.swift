// AudioSTT.swift — shared on-device speech-to-text router.
//
// File transcription is local-first when the user enables Gemma audio:
//   1. Gemma 4 + its audio projector (mtmd) runs first.
//   2. Apple's on-device Speech framework is used only if mtmd is unavailable
//      or fails to produce a complete result.
// With Gemma audio disabled, Apple Speech remains the only path. Every run is
// persisted by TranscriptionLogger so Profile → Audio Transcription shows the
// requested engine, actual engine, result, segment count, and timings.

import Foundation
import AVFoundation

/// Why a file transcription was started. Persisted in Recent Runs.
enum AudioSTTContext: String, Codable {
    case automatic = "Automatic journal"
    case retranscribe = "Re-transcribe"
    case lockedPhone = "Locked-phone test"
}

/// Shared result type for file transcription across both engines.
struct AudioSTTResult {
    let text: String
    let engine: AudioSTTEngine
    let timings: AudioTimings?
    /// User-facing explanation of routing/success/failure.
    let diagnostic: String?
    /// Number of sequential audio segments submitted to the producing engine.
    let segmentCount: Int
}

/// Which engine produced the returned transcription.
enum AudioSTTEngine: String {
    case appleSpeech = "Apple Speech (on-device)"
    case gemmaAudio = "Gemma 4 Audio (mtmd)"
    case appleAfterGemmaFailure = "Apple fallback (mtmd failed)"
}

enum AudioSTT {
    /// Keep each mtmd request comfortably within its 4096-token iOS context.
    /// Gemma audio consumes roughly 25 embedding tokens/second, so 45 seconds
    /// leaves room for the prompt and up to 512 generated transcript tokens.
    private static let gemmaSegmentSeconds = 45
    private static let gemmaMaxTokensPerSegment: UInt32 = 512

    /// Transcribe a file and record an observable run. When `useGemmaAudio` is
    /// true, mtmd is authoritative and Apple is fallback-only. This makes the
    /// toggle meaningful and keeps re-transcription device-independent.
    static func transcribe(
        url: URL,
        useGemmaAudio: Bool,
        context: AudioSTTContext = .automatic,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> AudioSTTResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let audioSeconds = audioDurationSeconds(url: url)
        let result: AudioSTTResult

        if useGemmaAudio {
            progress?("Preparing Gemma 4 Audio…")
            let gemma = await transcribeWithGemma(url: url, progress: progress)
            if !gemma.text.isEmpty {
                result = gemma
            } else {
                progress?("Gemma could not complete; trying Apple Speech…")
                let appleText = await Transcriber.transcribe(url: url)
                let detail = [gemma.diagnostic, appleText.isEmpty
                    ? "Apple fallback also produced no transcript."
                    : "Apple fallback completed after mtmd failed."]
                    .compactMap { $0 }.joined(separator: " ")
                result = AudioSTTResult(
                    text: appleText,
                    engine: .appleAfterGemmaFailure,
                    timings: gemma.timings,
                    diagnostic: detail,
                    segmentCount: gemma.segmentCount)
            }
        } else {
            progress?("Running Apple's long-form on-device transcription…")
            let appleText = await Transcriber.transcribe(url: url)
            result = AudioSTTResult(
                text: appleText,
                engine: .appleSpeech,
                timings: nil,
                diagnostic: appleText.isEmpty
                    ? "Apple's on-device recognizer produced no transcript."
                    : "Apple's long-form on-device recognizer completed.",
                segmentCount: 1)
        }

        let elapsedMs = Int64((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        progress?(result.text.isEmpty
                  ? "Transcription failed."
                  : "Completed with \(result.engine.rawValue).")
        TranscriptionLogger.append(TranscriptionRun(
            context: context,
            requestedEngine: useGemmaAudio ? "Gemma 4 Audio (mtmd)" : "Apple Speech",
            engine: result.engine.rawValue,
            succeeded: !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            detail: result.diagnostic ?? "",
            audioSeconds: audioSeconds ?? 0,
            segmentCount: result.segmentCount,
            loadMs: result.timings?.loadMs ?? 0,
            encodeMs: result.timings?.encodeMs ?? 0,
            decodeMs: result.timings?.decodeMs ?? 0,
            totalMs: result.timings?.totalMs ?? elapsedMs,
            transcriptLen: result.text.count))
        return result
    }

    // MARK: - Gemma audio (mtmd)

    /// Decode once, split into bounded requests, and transcribe sequentially.
    /// All-or-nothing: one failed/empty segment invalidates the Gemma result so
    /// the router can use Apple over the original complete file. This avoids
    /// the Zig engine's context ceiling silently dropping trailing audio.
    private static func transcribeWithGemma(
        url: URL,
        progress: (@Sendable (String) -> Void)?
    ) async -> AudioSTTResult {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let status = slowClawLocalAudioStatus()
        guard status.available else {
            return gemmaFailure(status.reason ?? "The mtmd backend is not linked.")
        }
        guard status.supported, status.sampleRate > 0 else {
            return gemmaFailure(status.reason ?? "The Gemma audio projector is not loaded.")
        }
        let targetRate = Double(status.sampleRate)
        let pcmOpt = await Task.detached(priority: .userInitiated) {
            decodeToMonoF32(url: url, sampleRate: targetRate)
        }.value
        guard let pcm = pcmOpt, !pcm.isEmpty else {
            return gemmaFailure("mtmd could not decode the audio file.")
        }

        let samplesPerSegment = max(1, Int(targetRate) * gemmaSegmentSeconds)
        let segmentCount = Int(ceil(Double(pcm.count) / Double(samplesPerSegment)))
        var parts: [String] = []
        parts.reserveCapacity(segmentCount)
        var loadMs: Int64 = 0
        var encodeMs: Int64 = 0
        var decodeMs: Int64 = 0
        var totalMs: Int64 = 0

        for index in 0..<segmentCount {
            progress?("Gemma segment \(index + 1) of \(segmentCount)…")
            if Task.isCancelled {
                return gemmaFailure("Gemma transcription was cancelled.", segmentCount: index)
            }
            let start = index * samplesPerSegment
            let end = min(start + samplesPerSegment, pcm.count)
            let segment = Array(pcm[start..<end])
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try slowClawLocalAudioTranscribe(
                        pcm: segment,
                        maxTokens: gemmaMaxTokensPerSegment,
                        temperature: 0.0)
                }.value
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return gemmaFailure(
                        "Gemma returned no text for segment \(index + 1) of \(segmentCount).",
                        timings: AudioTimings(loadMs: loadMs, encodeMs: encodeMs,
                                              decodeMs: decodeMs, totalMs: totalMs),
                        segmentCount: index + 1)
                }
                parts.append(text)
                loadMs += item.timings.loadMs
                encodeMs += item.timings.encodeMs
                decodeMs += item.timings.decodeMs
                totalMs += item.timings.totalMs
            } catch {
                return gemmaFailure(
                    "Gemma failed on segment \(index + 1) of \(segmentCount): \(error.localizedDescription)",
                    timings: AudioTimings(loadMs: loadMs, encodeMs: encodeMs,
                                          decodeMs: decodeMs, totalMs: totalMs),
                    segmentCount: index + 1)
            }
        }

        return AudioSTTResult(
            text: parts.joined(separator: " "),
            engine: .gemmaAudio,
            timings: AudioTimings(loadMs: loadMs, encodeMs: encodeMs,
                                  decodeMs: decodeMs, totalMs: totalMs),
            diagnostic: "Gemma completed \(segmentCount) local segment\(segmentCount == 1 ? "" : "s").",
            segmentCount: segmentCount)
    }

    private static func gemmaFailure(_ message: String,
                                     timings: AudioTimings? = nil,
                                     segmentCount: Int = 0) -> AudioSTTResult {
        AudioSTTResult(text: "", engine: .gemmaAudio, timings: timings,
                       diagnostic: message, segmentCount: segmentCount)
    }

    private static func audioDurationSeconds(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - PCM extraction (AVAudioFile → mono F32 at target rate)

    nonisolated static func decodeToMonoF32(url: URL, sampleRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return decodeToMonoF32(file: file, sampleRate: sampleRate)
    }

    /// All-or-nothing streaming conversion. A converter instance spans the
    /// whole file; endOfStream is sent only after the source is truly drained.
    nonisolated static func decodeToMonoF32(file: AVAudioFile, sampleRate: Double) -> [Float]? {
        let srcFormat = file.processingFormat
        guard sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: targetFormat)
        else { return nil }

        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }
        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
            return nil
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(totalFrames) * (sampleRate / srcFormat.sampleRate)) + 1024)
        var framesRemaining = totalFrames
        var pendingChunk = false
        var inputEnded = false
        var streamEnded = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputEnded {
                outStatus.pointee = .endOfStream
                return nil
            }
            if pendingChunk {
                pendingChunk = false
                outStatus.pointee = .haveData
                return readBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        while !streamEnded {
            if !inputEnded {
                if !pendingChunk && framesRemaining > 0 {
                    let toRead = min(chunkFrames, framesRemaining)
                    readBuffer.frameLength = 0
                    do {
                        try file.read(into: readBuffer, frameCount: toRead)
                    } catch {
                        return nil
                    }
                    if readBuffer.frameLength == 0 {
                        framesRemaining = 0
                    } else {
                        framesRemaining -= readBuffer.frameLength
                        pendingChunk = true
                    }
                }
                if framesRemaining == 0 && !pendingChunk { inputEnded = true }
            }

            let ratio = sampleRate / srcFormat.sampleRate
            let outCap = max(AVAudioFrameCount(Double(readBuffer.frameLength) * ratio) + 32, 1)
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: outCap) else { return nil }
            var conversionError: NSError?
            let conversion = converter.convert(
                to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if conversion == .error || conversionError != nil { return nil }
            if outBuffer.frameLength > 0 {
                guard let channels = outBuffer.floatChannelData else { return nil }
                output.append(contentsOf: UnsafeBufferPointer(
                    start: channels[0], count: Int(outBuffer.frameLength)))
            }
            if conversion == .endOfStream { streamEnded = true }
        }
        return output.isEmpty ? nil : output
    }
}
