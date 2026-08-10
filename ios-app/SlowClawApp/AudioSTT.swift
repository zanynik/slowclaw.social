// AudioSTT.swift — shared on-device speech-to-text router.
//
// Routes an audio FILE to the right transcription engine:
//   - Default (proven): iOS SpeechAnalyzer via Transcriber.transcribe(url:).
//   - Experimental (opt-in): on-device Gemma-audio via the Zig core's mtmd
//     layer (slowClawLocalAudioTranscribe), with SpeechAnalyzer as the
//     automatic fallback on any error or empty result.
//
// The experimental engine is gated by `experimentalAudioEngine` (default
// OFF) AND requires an audio mmproj to be loaded (checked via the status
// JSON). When the toggle is off OR no mmproj is loaded, this is a thin
// pass-through to Transcriber — zero behavior change.
//
// PCM extraction reuses the AVAudioConverter pattern from SpeechTranscriber
// to produce mono F32 at the sample rate the projector expects (typically
// 16000). The audio file is the source of truth; we never persist raw PCM.

import Foundation
import AVFoundation

/// Shared result type for file transcription across both engines.
struct AudioSTTResult {
    /// The transcribed text ("" if nothing was recognized).
    let text: String
    /// Engine that produced this result (for diagnostics / experiment log).
    let engine: AudioSTTEngine
    /// Timings from the mtmd path (nil for SpeechAnalyzer).
    let timings: AudioTimings?
}

/// Which engine produced a transcription.
enum AudioSTTEngine: String {
    case speechAnalyzer = "SpeechAnalyzer"
    case gemmaAudio = "GemmaAudio (mtmd)"
    case gemmaAudioFallback = "GemmaAudio→fallback"
}

enum AudioSTT {

    /// Transcribe an audio file at `url`. Routes to the experimental Gemma-audio
    /// engine when it's enabled + loaded, else (or on failure) to SpeechAnalyzer.
    /// Never throws — returns "" with engine=fallback on total failure so callers
    /// can store a placeholder.
    ///
    /// `gemmaAudioEligible` is read from the caller (AppState) to avoid a tight
    /// coupling to @AppStorage here; the caller decides policy (toggle + status).
    static func transcribe(url: URL, useGemmaAudio: Bool) async -> AudioSTTResult {
        if useGemmaAudio {
            // Try the experimental path first. Any failure → SpeechAnalyzer.
            let gemma = await transcribeWithGemma(url: url)
            if let gemma, !gemma.text.isEmpty {
                return gemma
            }
            // Fall through to SpeechAnalyzer.
            let text = await Transcriber.transcribe(url: url)
            return AudioSTTResult(text: text, engine: .gemmaAudioFallback, timings: gemma?.timings)
        }
        let text = await Transcriber.transcribe(url: url)
        return AudioSTTResult(text: text, engine: .speechAnalyzer, timings: nil)
    }

    // MARK: - Gemma-audio (experimental) via the Zig core's mtmd layer

    /// Transcribe via the on-device Gemma-audio model. Returns nil on any
    /// failure (caller falls back to SpeechAnalyzer). Decodes the audio file
    /// to mono PCM F32 at the projector's expected sample rate, then hands
    /// the PCM to the Zig core.
    private static func transcribeWithGemma(url: URL) async -> AudioSTTResult? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Read the projector's expected sample rate (0 = no mmproj loaded).
        let status = slowClawLocalAudioStatus()
        guard status.available, status.supported, status.sampleRate > 0 else {
            return nil
        }
        let targetRate = Double(status.sampleRate)

        // Decode + resample to mono F32 at the target rate.
        let pcmOpt = await Task.detached(priority: .userInitiated) {
            decodeToMonoF32(url: url, sampleRate: targetRate)
        }.value
        guard let pcm = pcmOpt, !pcm.isEmpty else {
            return nil
        }

        // Hand the PCM to the Zig core. This runs the full mtmd pipeline
        // (audio encoder → projector → LLM decode → transcript generation).
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try slowClawLocalAudioTranscribe(pcm: pcm, maxTokens: 256, temperature: 0.0)
            }.value
            return AudioSTTResult(text: result.text, engine: .gemmaAudio, timings: result.timings)
        } catch {
            // Inference failed (RAM, crash, unsupported). Caller falls back.
            return nil
        }
    }

    // MARK: - PCM extraction (AVAudioFile → mono F32 at target rate)

    /// Decode an audio file to a flat array of mono F32 samples at `sampleRate`.
    /// Reuses the AVAudioConverter pattern from SpeechTranscriber.feed. Returns
    /// nil on any decode failure. The result is owned by the caller (passed into
    /// the Zig core, which copies it into the mtmd bitmap).
    ///
    /// Nonisolated so it can run in a detached Task off the main actor.
    nonisolated static func decodeToMonoF32(url: URL, sampleRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return decodeToMonoF32(file: file, sampleRate: sampleRate)
    }

    /// Shared decoder: AVAudioFile → mono F32 [n_samples] at `sampleRate`.
    /// Converts the file's native format to the target rate + mono, then
    /// flattens the interleaved channel data to a single channel.
    nonisolated static func decodeToMonoF32(file: AVAudioFile, sampleRate: Double) -> [Float]? {
        let srcFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 1, interleaved: false) else {
            return nil
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            return nil
        }

        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }

        // Read + convert in chunks (mirrors SpeechTranscriber.feed's loop).
        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
            return nil
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(totalFrames) * (sampleRate / srcFormat.sampleRate)) + 1024)

        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let toRead = min(chunkFrames, remaining)
            do {
                try file.read(into: readBuffer, frameCount: toRead)
            } catch {
                break
            }

            // Convert this chunk to the target format (mono F32).
            let ratio = sampleRate / srcFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(toRead) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { break }
            var consumedAll = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumedAll {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                consumedAll = true
                outStatus.pointee = .haveData
                return readBuffer
            }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if status == .haveData || outBuffer.frameLength > 0 {
                // Mono channel 0 is the full output (channels=1, non-interleaved).
                let ch = outBuffer.floatChannelData![0]
                let n = Int(outBuffer.frameLength)
                output.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            }
            framesRead += toRead
        }

        return output.isEmpty ? nil : output
    }
}
