// SpeechTranscriber.swift — on-device transcription via the modern Speech
// framework (iOS 26+ SpeechAnalyzer / SpeechTranscriber).
//
// IMPORTANT: this file's wrapper type is named `Transcriber` (NOT
// `SpeechTranscriber`) on purpose — Apple's Speech framework already defines a
// `SpeechTranscriber` type, and naming ours the same would shadow it and break
// every reference to the real API below.
//
// Live capture and completed files use SpeechAnalyzer's purpose-built live and
// offline presets. Before either session starts, the app asks AssetInventory to
// install the current locale's on-device model — the same required setup used
// by Apple's Notes and Voice Memos transcription flow. Legacy
// SFSpeechRecognizer is retained only as a compatibility fallback.
// Both paths require on-device recognition, so audio never leaves the device.
//
// Two entry points:
//   - Transcriber.transcribe(url:)     — transcribe an existing audio FILE to
//                                        a final string (VoiceMemoImporter +
//                                        background drain).
//   - Transcriber.makeLiveSession()    — a streaming session the AudioRecorder
//                                        feeds from its AVAudioEngine tap
//                                        during capture; revised snapshots
//                                        arrive via onTranscript.
//
// Permission: SpeechAnalyzer still requires SFSpeechRecognizer authorization,
// so callers request it before starting a session.

import Foundation
import AVFoundation
import Speech

/// On-device speech transcription backed by SpeechAnalyzer (iOS 26+). Named
/// `Transcriber` to avoid colliding with Apple's `Speech.SpeechTranscriber`.
enum Transcriber {

    private enum SetupError: LocalizedError {
        case unsupportedLocale
        case unavailableAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                return "Speech transcription is not available for the current language."
            case .unavailableAudioFormat:
                return "Speech transcription could not prepare an audio format."
            }
        }
    }

    // MARK: - File transcription (VoiceMemoImporter + background-drain path)

    /// Transcribe an existing audio file at `url` to a single string on-device.
    /// Returns "" if nothing was recognized. Reads the file's PCM buffers and
    /// feeds them to a SpeechAnalyzer session, accumulating final results.
    ///
    /// File path: SpeechAnalyzer's `.offlineTranscription` preset processes the
    /// whole recording as one time-coded stream. This is Apple's long-form
    /// path and avoids application-level slicing. The forced-on-device legacy
    /// recognizer is only a fallback if the modern model cannot run.
    /// Audio never leaves the device on either path.
    ///
    /// Thread-safe: blocking recognition runs on the calling thread; callers
    /// await it off the main actor (e.g. inside a Task.detached).
    static func transcribe(url: URL) async -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let modern = await transcribeWithAnalyzer(url: url)
        if !modern.isEmpty { return modern }
        return await LegacyTranscriber.transcribe(url: url)
    }

    /// The SpeechAnalyzer file fallback, isolated so the wrapper above can
    /// discard an empty result cleanly.
    private static func transcribeWithAnalyzer(url: URL) async -> String {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return "" }
        return await transcribe(file: audioFile)
    }

    /// Shared file→string transcription used by transcribe(url:) and the
    /// background drain. Takes an already-opened AVAudioFile.
    ///
    /// All-or-nothing: feeding, analysis, finalization, AND result collection
    /// must ALL succeed — any failure (including the results sequence throwing
    /// or failing to end within the collector timeout) discards everything
    /// collected and returns "", letting the caller's on-device legacy
    /// fallback handle the file. Partial finals are never returned after an
    /// error or timeout.
    ///
    /// Uses SpeechAnalyzer.analyzeSequence(from:) rather than a hand-written
    /// AVAudioConverter loop. The framework owns file reading, timecodes and
    /// end-of-input, which prevents a converter status mistake from silently
    /// dropping the middle or tail of a long recording.
    static func transcribe(file: AVAudioFile) async -> String {
        guard let transcriber = try? await preparedOfflineTranscriber() else {
            return ""
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collected = FinalCollector()
        let recognizerTask = Task<Void, Error> {
            for try await result in transcriber.results {
                if result.isFinal {
                    collected.append(String(result.text.characters))
                }
            }
        }
        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: file) else {
                await analyzer.cancelAndFinishNow()
                recognizerTask.cancel()
                return ""
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
        } catch {
            await analyzer.cancelAndFinishNow()
            recognizerTask.cancel()
            _ = await Self.awaitCollectorCompletion(recognizerTask)
            return ""
        }
        // The results sequence ENDS on its own after finalize (returning nil
        // ends the for-await loop). Await its natural completion with a
        // bounded timeout — cancelling IMMEDIATELY after finalize dropped
        // finals still queued in the sequence, which is how long files ended
        // up with only their last line / no transcript at all.
        //
        // The completion must SUCCEED: if the sequence threw, or never ended
        // within the timeout, the collected text is a partial (e.g. a lone
        // 2-line chunk) — discard it and return "" so the caller's
        // forced-on-device legacy fallback re-transcribes the file honestly.
        let collectorDrained = await Self.awaitCollectorCompletion(recognizerTask)
        guard collectorDrained else { return "" }
        return collected.text()
    }

    // MARK: - Live transcription session (AudioRecorder path)

    /// A streaming on-device transcription session. The recorder yields
    /// converted mic buffers via `process(_:)`; finalized transcript chunks are
    /// delivered on the main actor through `onTranscript`. Call `start()` once, feed
    /// buffers, then `stop()` to flush. `analyzerFormat` is the AVAudioFormat
    /// the recorder must convert its tap buffers to before yielding.
    final class LiveSession {
        private let transcriber: SpeechTranscriber
        private let analyzer: SpeechAnalyzer
        private let inputStream: AsyncStream<AnalyzerInput>
        private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
        private var recognizerTask: Task<Void, Error>?
        private var analyzerTask: Task<Void, Never>?
        let analyzerFormat: AVAudioFormat
        let onTranscript: @MainActor (String) -> Void
        private let accumulator = LiveTranscriptAccumulator()

        init(transcriber: SpeechTranscriber,
             analyzer: SpeechAnalyzer,
             analyzerFormat: AVAudioFormat,
             inputStream: AsyncStream<AnalyzerInput>,
             inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
             onTranscript: @escaping @MainActor (String) -> Void) {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.analyzerFormat = analyzerFormat
            self.inputStream = inputStream
            self.inputBuilder = inputBuilder
            self.onTranscript = onTranscript
        }

        /// Start the analyzer + the result-collection task. Must be called once
        /// before feeding buffers. Non-blocking: the analyzer consumes
        /// `inputStream` on an internal task that lives until `stop()`, so the
        /// caller is free to keep running its AVAudioEngine. Buffers yielded via
        /// `process(_:)` (on the audio thread) drive recognition.
        func start() {
            // Collect finals off the audio thread. The results sequence throws,
            // so this Task's failure type is Error.
            recognizerTask = Task<Void, Error> { [transcriber] in
                for try await result in transcriber.results {
                    let snapshot = self.accumulator.apply(
                        String(result.text.characters), isFinal: result.isFinal)
                    await MainActor.run { self.onTranscript(snapshot) }
                }
            }
            // Drive the analyzer for the lifetime of inputStream. It suspends
            // until the stream finishes (stop() calls inputBuilder.finish()).
            analyzerTask = Task { [analyzer, inputStream] in
                try? await analyzer.start(inputSequence: inputStream)
            }
        }

        /// Feed one converted PCM buffer to the analyzer. The recorder converts
        /// from the mic format to `analyzerFormat` before calling this. Safe to
        /// call from the AVAudioEngine tap thread.
        func process(_ buffer: AVAudioPCMBuffer) {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
        }

        /// Stop the session: finish the stream and finalize so any in-flight
        /// finals flush. Safe to call multiple times.
        func stop() async -> String {
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            // Let the finals collector drain to NATURAL completion (bounded)
            // before tearing down — see transcribe(file:) for why an immediate
            // cancel lost late finals. The live path has no aggregate to
            // withhold (snapshots were already streamed via onTranscript).
            // The completion outcome determines whether the accumulated
            // finals are trustworthy enough to save as the journal body.
            let completed = if let recognizerTask {
                await Transcriber.awaitCollectorCompletion(recognizerTask)
            } else { false }
            recognizerTask = nil
            analyzerTask?.cancel()
            analyzerTask = nil
            return completed ? accumulator.finalizedText() : ""
        }
    }

    /// Build a live session for the current locale. Returns nil if the
    /// analyzer/format can't be constructed. The caller starts it once recording
    /// begins. If on-device speech is unavailable, finals simply never arrive
    /// and the caller stores a placeholder.
    static func makeLiveSession(onTranscript: @escaping @MainActor (String) -> Void) async throws -> LiveSession {
        let transcriber = try await preparedLiveTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SetupError.unavailableAudioFormat
        }
        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        return LiveSession(transcriber: transcriber,
                           analyzer: analyzer,
                           analyzerFormat: analyzerFormat,
                           inputStream: inputStream,
                           inputBuilder: inputBuilder,
                           onTranscript: onTranscript)
    }

    /// Resolve a SpeechTranscriber locale equivalent to the user's current
    /// locale and ensure its system-managed model is installed. AssetInventory
    /// keeps the model outside the app bundle and updates it independently.
    private static func supportedCurrentLocale() async throws -> Locale {
        let requested = Locale.current
        let requestedID = requested.identifier(.bcp47)
        let requestedLanguage = requested.language.languageCode?.identifier
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == requestedID })
            ?? supported.first(where: {
                $0.language.languageCode?.identifier == requestedLanguage
            }) else {
            throw SetupError.unsupportedLocale
        }
        return locale
    }

    private static func preparedOfflineTranscriber() async throws -> SpeechTranscriber {
        let locale = try await supportedCurrentLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)
        try await installModel(for: transcriber)
        return transcriber
    }

    private static func preparedLiveTranscriber() async throws -> SpeechTranscriber {
        let locale = try await supportedCurrentLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveLiveTranscription)
        try await installModel(for: transcriber)
        return transcriber
    }

    private static func installModel(for transcriber: SpeechTranscriber) async throws {
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installation.downloadAndInstall()
        }
    }

    // MARK: - File feeding

    /// Await a finals-collector task's natural completion, bounded by a
    /// timeout. After `finalizeAndFinishThroughEndOfInput()` the transcriber's
    /// results sequence should finish on its own; if an OS build keeps it
    /// alive, cancel after the bound so the caller can't hang.
    ///
    /// Returns true IFF the results sequence ENDED on its own without throwing
    /// (the collector drained to natural completion). Returns false when the
    /// sequence THREW or was still alive after the 10s bound — in both cases
    /// the text collected so far is a partial at best, and the caller must
    /// DISCARD it (and take the on-device legacy fallback) rather than return
    /// it. A collector that never ended cannot vouch for its text.
    private static func awaitCollectorCompletion(_ task: Task<Void, Error>) async -> Bool {
        let outcome = await withTaskGroup(of: Bool.self) { group -> Bool? in
            group.addTask {
                do {
                    // Rethrows the results sequence's error, if it threw.
                    try await task.value
                    return true
                } catch {
                    return false // sequence threw: collected text is incomplete
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s bound
                task.cancel()
                return false // never ended in time: collected text is incomplete
            }
            let first = await group.next()
            group.cancelAll()
            return first
        }
        return outcome ?? false
    }

    /// Read an AVAudioFile's PCM in chunks, convert each to the analyzer
    /// format, and yield to the builder. Returns false if the file could not
    /// be FULLY read + converted — the caller must then discard everything
    /// fed so far instead of transcribing a partial file.
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
    private static func feed(file: AVAudioFile,
                             converter: AVAudioConverter,
                             into builder: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return true } // empty source: nothing to feed
        let inFormat = file.processingFormat
        let outFormat = converter.outputFormat
        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames) else {
            return false
        }

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
                        return false // read failure: caller discards the run
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

            // Fresh output buffer per pass: the analyzer may retain yielded
            // buffers, so they must not alias each other.
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let outCap = max(AVAudioFrameCount(Double(readBuffer.frameLength) * ratio) + 32, 1)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
                return false
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if status == .error || conversionError != nil {
                return false // conversion failure: caller discards the run
            }
            if outBuffer.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: outBuffer))
            }
            // .haveData / .inputRanDry: loop for the next chunk (or another
            // flush pass); .endOfStream terminates the loop.
            if status == .endOfStream {
                streamEnded = true
            }
        }
        return true
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

/// Lock-protected live transcript state. SpeechTranscriber may revise the
/// current volatile phrase several times; finalized phrases append exactly
/// once and the volatile phrase is replaced rather than duplicated.
private final class LiveTranscriptAccumulator: @unchecked Sendable {
    private var finalParts: [String] = []
    private var volatilePart = ""
    private let lock = NSLock()

    func apply(_ text: String, isFinal: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty { finalParts.append(trimmed) }
            volatilePart = ""
        } else {
            volatilePart = trimmed
        }
        return (finalParts + (volatilePart.isEmpty ? [] : [volatilePart]))
            .joined(separator: " ")
    }

    func finalizedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return finalParts.joined(separator: " ")
    }
}

// MARK: - Legacy fallback (SFSpeechRecognizer)

/// Legacy on-device transcription via the pre-SpeechAnalyzer Speech framework
/// (`SFSpeechRecognizer`). Used as the automatic fallback when SpeechAnalyzer
/// is unavailable — e.g. iOS versions / devices without Apple Intelligence, or
/// a locale whose SpeechAnalyzer asset hasn't been downloaded. Without this
/// fallback, such devices produced "🎙 ... (no transcript)" placeholders.
///
/// Privacy: on-device ONLY. Every request sets
/// `requiresOnDeviceRecognition = true`; when the recognizer can't guarantee
/// on-device recognition there is no server fallback — transcribe returns ""
/// and the caller keeps its placeholder. Audio never leaves the device.
///
/// Long-audio robustness + all-or-nothing aggregation:
///   - Short files (≤ 45s) go through as ONE whole-file on-device request.
///   - Longer files are split into ~40s temp segments (frame boundaries, no
///     re-encoding) transcribed STRICTLY SEQUENTIALLY, each result appended in
///     order — exactly one in-flight request at a time, each result lands
///     exactly once, so no segment can overwrite or reorder another's text.
///     The threshold sits safely BELOW the recognizer's ~1min flakiness point,
///     and segments are ~40s, so a one-minute journal is always TWO sequential
///     requests — never one request at the unreliable duration.
///   - If any segment fails (or the split itself fails) the partial aggregate
///     is discarded and transcribe returns "" — a half-transcribed journal is
///     worse than an honest placeholder.
enum LegacyTranscriber {

    // On-device request sizing: the on-device recognizer degrades on
    // whole-file requests approaching the ~1min mark, so anything longer
    // than 45s is segmented into ~40s sequential requests.
    private static let segmentThresholdSeconds: Double = 45
    private static let segmentSeconds: Double = 40
    /// Per-segment budget: a ~40s segment should finish well inside 90s.
    private static let segmentTimeoutSeconds: UInt64 = 90
    /// Whole-file budget: on-device requests have no duration cap, but a
    /// wedged request still must not hang the import queue forever.
    private static let wholeFileTimeoutSeconds: UInt64 = 15 * 60

    /// Local failure reasons for segmentation (trigger temp-file cleanup).
    private enum SplitFailure: Error {
        case segmentBufferAllocationFailed
        case unexpectedEndOfFile
    }

    /// Entry point: authorize, pick a recognizer for the current locale, and
    /// route to whole-file (short) or segmented (long) on-device
    /// transcription. Returns "" on failure — callers already handle the
    /// empty case with a placeholder.
    static func transcribe(url: URL) async -> String {
        // SpeechAnalyzer still gates on SFSpeechRecognizer authorization, and
        // so does this legacy path.
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { return "" }

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return "" }

        // Privacy gate: no on-device support → no transcription at all. The
        // server path is never used (iOS caps it at ~1 min/request, and audio
        // must not leave the device).
        guard recognizer.supportsOnDeviceRecognition else { return "" }

        if let duration = audioDurationSeconds(url: url),
           duration > segmentThresholdSeconds {
            return await transcribeSegmented(url: url, recognizer: recognizer)
        }
        guard let text = await transcribeFile(url: url,
                                              recognizer: recognizer,
                                              timeoutSeconds: wholeFileTimeoutSeconds) else {
            return ""
        }
        return text
    }

    /// Best-effort duration in seconds of the audio at `url`; nil if the file
    /// can't be opened (the caller then uses the whole-file path, which fails
    /// cleanly on its own).
    private static func audioDurationSeconds(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// One ON-DEVICE SFSpeechURLRecognitionRequest over the given file. Awaits
    /// the final result (no partials). Returns nil on failure, error, or
    /// timeout — distinguished from a legitimate "recognized nothing" success
    /// ("") so segmented aggregation can refuse partial results.
    private static func transcribeFile(url: URL,
                                       recognizer: SFSpeechRecognizer,
                                       timeoutSeconds: UInt64) async -> String? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Hard privacy requirement for EVERY request issued by this file.
        request.requiresOnDeviceRecognition = true

        // Shared between the recognition child task and the timeout child
        // task: whichever finishes first wins, the continuation resumes
        // exactly once, and the recognition task is stopped on expiry or
        // cancellation. (The previous design used an unstructured watcher Task
        // polling Task.isCancelled — but nothing ever cancelled it, leaking a
        // 200ms poll loop per transcription. This structure has no watcher.)
        let box = RecognitionOutcome()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    box.setContinuation(cont)
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let result, result.isFinal {
                            box.resume(returning: result.bestTranscription.formattedString)
                        } else if error != nil {
                            box.resume(returning: nil)
                        }
                        // Non-final results with no error: keep waiting.
                    }
                    box.setTask(task)
                }
            }
            group.addTask {
                // Safety valve AND cancellation handler. This child finishes
                // on budget expiry, on group.cancelAll() after a delivered
                // result, or on cancellation inherited from the caller — and
                // in EVERY case it must resume the checked continuation and
                // stop the recognition task. (A guard on Task.isCancelled
                // here would skip that on caller cancellation, leaving the
                // recognition child hung on the continuation forever.)
                // box resumes at most once, so the already-finished cases
                // are harmless no-ops.
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                box.cancelAndResume()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// On-device path for LONG files: split into ~40s temp segments and
    /// transcribe them STRICTLY IN ORDER, appending each result to the
    /// accumulated transcript. One request in flight at a time; each segment
    /// appends exactly once — no overwrites, no reordering.
    ///
    /// All-or-nothing: a failed/timed-out segment or a failed split discards
    /// the aggregate and returns "" — never a partial transcript.
    private static func transcribeSegmented(url: URL, recognizer: SFSpeechRecognizer) async -> String {
        guard let segments = try? splitIntoSegments(url: url, segmentSeconds: segmentSeconds),
              !segments.isEmpty else {
            // Split failed (or empty source): refuse to guess from a partial
            // read — an empty result keeps the caller's placeholder honest.
            return ""
        }
        defer { segments.forEach { try? FileManager.default.removeItem(at: $0) } }
        var parts: [String] = []
        for segment in segments {
            guard let text = await transcribeFile(url: segment,
                                                  recognizer: recognizer,
                                                  timeoutSeconds: segmentTimeoutSeconds) else {
                // Any segment failure invalidates the whole aggregate.
                return ""
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: " ")
    }

    /// Split an audio file into ~`segmentSeconds` temp .caf files on frame
    /// boundaries (no re-encoding — the source format is written as-is). The
    /// temp files live in the system temp dir; the caller removes them.
    ///
    /// Failure hygiene: on any error, every segment created so far is removed
    /// before rethrowing — a failed split never leaks temp files.
    private static func splitIntoSegments(url: URL, segmentSeconds: Double) throws -> [URL] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }
        let framesPerSegment = Int(format.sampleRate * segmentSeconds)
        guard framesPerSegment > 0 else { return [] }

        var segments: [URL] = []
        do {
            var frameOffset = 0
            while frameOffset < totalFrames {
                let toRead = AVAudioFrameCount(min(framesPerSegment, totalFrames - frameOffset))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else {
                    throw SplitFailure.segmentBufferAllocationFailed
                }
                // Read BEFORE creating the segment file so a read error can't
                // leave an empty .caf behind.
                try file.read(into: buffer, frameCount: toRead)
                let framesRead = Int(buffer.frameLength)
                guard framesRead > 0 else { throw SplitFailure.unexpectedEndOfFile }
                let segURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("slowclaw-stt-\(UUID().uuidString).caf")
                // Track immediately so the catch below can remove it even if
                // the write below fails partway.
                segments.append(segURL)
                let out = try AVAudioFile(forWriting: segURL, settings: format.settings)
                try out.write(from: buffer)
                frameOffset += framesRead
            }
        } catch {
            segments.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return segments
    }
}

/// Single-resume outcome box shared by the recognition callback and the
/// timeout/cancellation child task: the checked continuation resumes exactly
/// once (a recognition error can arrive after a final result), and the
/// SFSpeechRecognitionTask is stopped whenever the budget expires OR the
/// surrounding task is cancelled (cancelling an already-finished task would
/// be a harmless no-op). All state is behind one lock; safe to touch from the
/// callback queue and both tasks.
private final class RecognitionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String?, Never>?
    private var task: SFSpeechRecognitionTask?

    func setContinuation(_ cont: CheckedContinuation<String?, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.cont = cont
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func resume(returning value: String?) {
        lock.lock()
        let target = cont
        cont = nil
        lock.unlock()
        target?.resume(returning: value)
    }

    /// Expiry or cancellation: resume with nil if not already resumed, and
    /// stop the recognition task so its engine work doesn't continue
    /// headless. Both steps are no-ops after a delivered result.
    func cancelAndResume() {
        lock.lock()
        let target = cont
        cont = nil
        let task = self.task
        lock.unlock()
        target?.resume(returning: nil)
        task?.cancel()
    }
}
