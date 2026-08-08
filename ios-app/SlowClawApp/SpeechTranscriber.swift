// SpeechTranscriber.swift — on-device transcription via the modern Speech
// framework (iOS 26+ SpeechAnalyzer / SpeechTranscriber).
//
// Replaces the legacy SFSpeech* request-per-file approach. SpeechAnalyzer
// streams results as buffers are fed in, with no per-task ~60s ceiling and no
// file segmentation — so long audio journals transcribe in full instead of
// being silently truncated at segment boundaries. This is the on-device path
// (Apple Intelligence); audio never leaves the device.
//
// Two entry points:
//   - transcribe(url:)            — transcribe an existing audio FILE to a
//                                   final string (used by VoiceMemoImporter).
//   - makeLiveSession(onFinal:)   — a streaming session the AudioRecorder
//                                   feeds from its AVAudioEngine tap during
//                                   capture; finals accumulate via onFinal.
//
// Permission: SpeechAnalyzer still requires SFSpeechRecognizer authorization,
// so callers request it before starting a session.

import Foundation
import AVFoundation
import Speech

/// On-device speech transcription backed by SpeechAnalyzer (iOS 26+).
enum SpeechTranscriber {
    /// Best-effort ensure the on-device language asset for the current locale
    /// is installed. SpeechAnalyzer's models aren't bundled and may need a
    /// one-time download. Returns false if the locale can't be satisfied.
    static func ensureLocaleAsset() async -> Bool {
        let target = Locale.current.identifier(.bcp47)
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if installed.contains(target) { return true }
        let req = AssetInventory.assetInstallationRequest(supporting: [SpeechTranscriber.self])
        do {
            try await req.downloadAndInstall()
            return true
        } catch {
            return false
        }
    }

    // MARK: - File transcription (VoiceMemoImporter + background-drain path)

    /// Transcribe an existing audio file at `url` to a single string on-device.
    /// Returns "" if on-device speech is unavailable / nothing was recognized.
    /// Reads the file's PCM buffers and feeds them to a SpeechAnalyzer session,
    /// accumulating final results. Replaces the legacy 40s-segment + semaphore
    /// approach that could silently drop segments.
    ///
    /// Thread-safe: blocking recognition runs on the calling thread; callers
    /// await it off the main actor (e.g. inside a Task.detached).
    static func transcribe(url: URL) async -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let audioFile = try? AVAudioFile(forReading: url) else { return "" }
        return await transcribe(file: audioFile)
    }

    /// Shared file→string transcription used by transcribe(url:) and the
    /// background drain. Takes an already-opened AVAudioFile.
    static func transcribe(file: AVAudioFile) async -> String {
        guard await ensureLocaleAsset() else { return "" }

        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let analyzerFormat else { return "" }

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat)
        guard let converter else { return "" }

        // Accumulate finals as they stream in (off the main actor).
        let collected = FinalCollector()
        let recognizerTask = Task {
            for try await result in transcriber.results {
                if result.isFinal {
                    collected.append(String(result.text.characters))
                }
            }
        }

        // Feed the file's PCM buffers (converted to the analyzer format) into
        // the input stream. Run feeding + analyzer concurrently: the analyzer
        // consumes the stream while we fill it, then finalize flushes finals.
        async let feedingDone = feed(file: file, converter: converter,
                                     into: inputBuilder, format: analyzerFormat)
        do {
            try await analyzer.start(inputSequence: inputStream)
            await feedingDone
            inputBuilder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            inputBuilder.finish()
        }
        recognizerTask.cancel()
        return collected.text()
    }

    // MARK: - Live transcription session (AudioRecorder path)

    /// A streaming on-device transcription session. The recorder yields
    /// converted mic buffers via `process(_:)`; finalized transcript chunks are
    /// delivered on the main actor through `onFinal`. Call `start()` once, feed
    /// buffers, then `stop()` to flush. `analyzerFormat` is the AVAudioFormat
    /// the recorder must convert its tap buffers to before yielding.
    final class LiveSession {
        private let transcriber: SpeechTranscriber
        private let analyzer: SpeechAnalyzer
        private let inputStream: AsyncStream<AnalyzerInput>
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        private var recognizerTask: Task<Void, Never>?
        let analyzerFormat: AVAudioFormat
        let onFinal: @MainActor (String) -> Void

        init(transcriber: SpeechTranscriber,
             analyzer: SpeechAnalyzer,
             analyzerFormat: AVAudioFormat,
             inputStream: AsyncStream<AnalyzerInput>,
             inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
             onFinal: @escaping @MainActor (String) -> Void) {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.analyzerFormat = analyzerFormat
            self.inputStream = inputStream
            self.inputBuilder = inputBuilder
            self.onFinal = onFinal
        }

        /// Start the analyzer + the result-collection task. Must be called once
        /// before feeding buffers. Non-blocking: the analyzer consumes
        /// `inputStream` on an internal task that lives until `stop()`, so the
        /// caller is free to keep running its AVAudioEngine. Buffers yielded via
        /// `process(_:)` (on the audio thread) drive recognition.
        func start() {
            recognizerTask = Task { [transcriber, analyzer, inputStream] in
                // Collect finals off the audio thread.
                for try await result in transcriber.results {
                    if result.isFinal {
                        let text = String(result.text.characters)
                        await MainActor.run { self.onFinal(text) }
                    }
                }
            }
            // Drive the analyzer for the lifetime of inputStream. It suspends
            // until the stream finishes (stop() calls inputBuilder.finish()).
            Task { try? await analyzer.start(inputSequence: inputStream) }
        }

        /// Feed one converted PCM buffer to the analyzer. The recorder converts
        /// from the mic format to `analyzerFormat` before calling this. Safe to
        /// call from the AVAudioEngine tap thread.
        func process(_ buffer: AVAudioPCMBuffer) {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
        }

        /// Stop the session: finish the stream and finalize so any in-flight
        /// finals flush. Safe to call multiple times.
        func stop() async {
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            recognizerTask?.cancel()
            recognizerTask = nil
        }
    }

    /// Build a live session for the current locale. Returns nil if the on-device
    /// asset can't be installed. The caller starts it once recording begins.
    static func makeLiveSession(onFinal: @escaping @MainActor (String) -> Void) async -> LiveSession? {
        guard await ensureLocaleAsset() else { return nil }
        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }
        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        return LiveSession(transcriber: transcriber,
                           analyzer: analyzer,
                           analyzerFormat: analyzerFormat,
                           inputStream: inputStream,
                           inputBuilder: inputBuilder,
                           onFinal: onFinal)
    }

    // MARK: - File feeding

    /// Read an AVAudioFile's PCM in chunks, convert each to `format`, and yield
    /// to the builder. Conversion uses the standard AVAudioConverter path.
    private static func feed(file: AVAudioFile,
                             converter: AVAudioConverter,
                             into builder: AsyncStream<AnalyzerInput>.Continuation,
                             format: AVAudioFormat) async {
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return }
        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            return
        }

        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let toRead = min(chunkFrames, remaining)
            do {
                try file.read(into: readBuffer, frameCount: toRead)
            } catch {
                break
            }
            // Convert the chunk to the analyzer format. AVAudioConverter is
            // sample-rate / channel aware; we feed the input block once.
            let ratio = format.sampleRate / file.processingFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(toRead) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { break }
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
            let converted = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if converted > 0 {
                builder.yield(AnalyzerInput(buffer: outBuffer))
            }
            framesRead += toRead
        }
    }
}

/// Thread-safe collector for final transcript chunks (file path).
private final class FinalCollector: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        parts.append(s)
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return parts.joined(separator: " ")
    }
}
