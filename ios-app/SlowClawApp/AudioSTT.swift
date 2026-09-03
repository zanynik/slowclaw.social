// AudioSTT.swift — shared on-device speech-to-text router.
//
// Routes an audio FILE to the right transcription engine, in a FIXED order of
// authority:
//   - Default (proven): iOS SpeechAnalyzer via Transcriber.transcribe(url:)
//     runs FIRST and to COMPLETION — including its legacy forced-on-device
//     SFSpeechRecognizer fallback. A proven Apple Speech result is never
//     preempted by the experimental engine.
//   - Experimental (opt-in): on-device Gemma-audio via the Zig core's mtmd
//     layer (slowClawLocalAudioTranscribe) is consulted ONLY when the complete
//     Apple path produced no text. An experimental, possibly incomplete Gemma
//     result can therefore never replace a proven Apple result.
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

    /// Transcribe an audio file at `url`. The proven Apple path
    /// (SpeechAnalyzer + its forced-on-device legacy fallback) ALWAYS runs
    /// first and to completion; the experimental Gemma-audio engine is tried
    /// only when `useGemmaAudio` is set AND Apple produced no text — an
    /// incomplete experimental result must never preempt a proven one.
    /// Never throws — returns "" with the engine that produced the (possibly
    /// empty) outcome so callers can store a placeholder.
    ///
    /// `gemmaAudioEligible` is read from the caller (AppState) to avoid a tight
    /// coupling to @AppStorage here; the caller decides policy (toggle + status).
    static func transcribe(url: URL, useGemmaAudio: Bool) async -> AudioSTTResult {
        // Proven path first: run the COMPLETE Apple pipeline to completion.
        let appleText = await Transcriber.transcribe(url: url)
        if !appleText.isEmpty {
            return AudioSTTResult(text: appleText, engine: .speechAnalyzer, timings: nil)
        }
        // Apple produced no text (or no engine was available). Only now is
        // the experimental engine allowed to fill the gap.
        guard useGemmaAudio else {
            return AudioSTTResult(text: "", engine: .speechAnalyzer, timings: nil)
        }
        if let gemma = await transcribeWithGemma(url: url), !gemma.text.isEmpty {
            return gemma
        }
        // Nothing recognized anywhere; report that the fallback path ran.
        return AudioSTTResult(text: "", engine: .gemmaAudioFallback, timings: nil)
    }

    // MARK: - Gemma-audio (experimental) via the Zig core's mtmd layer

    /// Transcribe via the on-device Gemma-audio model. Only invoked AFTER the
    /// complete Apple path produced no text. Returns nil on any failure
    /// (caller then keeps the honest empty result). Decodes the audio file
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
    ///
    /// All-or-nothing: any read, conversion, or allocation failure returns nil
    /// — never a partial PCM array that would be handed to the model as if it
    /// were the whole recording.
    ///
    /// AVAudioConverter streaming protocol (contract, not a nicety): one
    /// converter instance spans the whole file, and each convert() call pulls
    /// from the input block as many times as it needs. The block supplies ONE
    /// freshly-read chunk with .haveData; if asked again within that call it
    /// reports .noDataNow ("more is coming") — reporting .endOfStream between
    /// chunks would PERMANENTLY end the stream for this converter instance and
    /// silently drop every chunk after the first. .endOfStream is reported
    /// only once, after the source data is actually drained, so the converter
    /// can flush internally-buffered samples and confirm end-of-output.
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

        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
            return nil
        }

        var output: [Float] = []
        output.reserveCapacity(Int(Double(totalFrames) * (sampleRate / srcFormat.sampleRate)) + 1024)

        var framesRemaining = totalFrames
        var pendingChunk = false // readBuffer holds a chunk not yet supplied
        var inputEnded = false   // source drained: next pull gets .endOfStream
        var streamEnded = false  // converter confirmed output fully drained

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
            // Nothing to supply right now (the loop reads the next chunk) —
            // explicitly NOT the end of the stream.
            outStatus.pointee = .noDataNow
            return nil
        }

        while !streamEnded {
            if !inputEnded {
                // Never overwrite readBuffer while the converter still owns
                // the previous chunk (it may emit buffered output before its
                // next input-block pull).
                if !pendingChunk && framesRemaining > 0 {
                    let toRead = min(chunkFrames, framesRemaining)
                    readBuffer.frameLength = 0
                    do {
                        try file.read(into: readBuffer, frameCount: toRead)
                    } catch {
                        return nil // read failure: no partial PCM
                    }
                    if readBuffer.frameLength == 0 {
                        framesRemaining = 0 // file ended early; drain what's buffered
                    } else {
                        framesRemaining -= readBuffer.frameLength
                        pendingChunk = true
                    }
                }
                if framesRemaining == 0 && !pendingChunk {
                    inputEnded = true // actual final drain: let the converter flush
                }
            }

            let ratio = sampleRate / srcFormat.sampleRate
            let outCap = max(AVAudioFrameCount(Double(readBuffer.frameLength) * ratio) + 32, 1)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
                return nil // allocation failure: no partial PCM
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if status == .error || conversionError != nil {
                return nil // conversion failure: no partial PCM
            }
            if outBuffer.frameLength > 0 {
                // Mono channel 0 is the full output (channels=1, non-interleaved).
                let ch = outBuffer.floatChannelData![0]
                let n = Int(outBuffer.frameLength)
                output.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            }
            // .haveData / .inputRanDry: loop for the next chunk (or another
            // flush pass); .endOfStream terminates the loop.
            if status == .endOfStream {
                streamEnded = true
            }
        }

        // All-or-nothing: a non-empty source that decoded to zero samples is
        // a failure, not an empty success.
        return output.isEmpty ? nil : output
    }
}
