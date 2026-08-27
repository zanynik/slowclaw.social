// SpeechTranscriber.swift — on-device transcription via the modern Speech
// framework (iOS 26+ SpeechAnalyzer / SpeechTranscriber).
//
// IMPORTANT: this file's wrapper type is named `Transcriber` (NOT
// `SpeechTranscriber`) on purpose — Apple's Speech framework already defines a
// `SpeechTranscriber` type, and naming ours the same would shadow it and break
// every reference to the real API below.
//
// Replaces the legacy SFSpeech* request-per-file approach. SpeechAnalyzer
// streams results as buffers are fed in, with no per-task ~60s ceiling and no
// file segmentation — so long audio journals transcribe in full instead of
// being silently truncated at segment boundaries. This is the on-device path
// (Apple Intelligence); audio never leaves the device.
//
// Two entry points:
//   - Transcriber.transcribe(url:)     — transcribe an existing audio FILE to
//                                        a final string (VoiceMemoImporter +
//                                        background drain).
//   - Transcriber.makeLiveSession()    — a streaming session the AudioRecorder
//                                        feeds from its AVAudioEngine tap
//                                        during capture; finals arrive via
//                                        onFinal.
//
// Permission: SpeechAnalyzer still requires SFSpeechRecognizer authorization,
// so callers request it before starting a session.

import Foundation
import AVFoundation
import Speech

/// On-device speech transcription backed by SpeechAnalyzer (iOS 26+). Named
/// `Transcriber` to avoid colliding with Apple's `Speech.SpeechTranscriber`.
enum Transcriber {

    // MARK: - File transcription (VoiceMemoImporter + background-drain path)

    /// Transcribe an existing audio file at `url` to a single string on-device.
    /// Returns "" if nothing was recognized. Reads the file's PCM buffers and
    /// feeds them to a SpeechAnalyzer session, accumulating final results.
    ///
    /// Fallback chain: modern SpeechAnalyzer first; if it is unavailable (older
    /// iOS, non-Apple-Intelligence device, missing locale asset) or produces
    /// no text, falls back to legacy SFSpeechRecognizer (see LegacyTranscriber
    /// below) so a recorded journal never lands as "no transcript" just
    /// because the device lacks Apple Intelligence.
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

    /// The SpeechAnalyzer file path, isolated so the fallback wrapper above
    /// can try it first and discard an empty result cleanly.
    private static func transcribeWithAnalyzer(url: URL) async -> String {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return "" }
        return await transcribe(file: audioFile)
    }

    /// Shared file→string transcription used by transcribe(url:) and the
    /// background drain. Takes an already-opened AVAudioFile.
    ///
    /// Ordering matters here: analyzer.start(inputSequence:) suspends until the
    /// input stream finishes, so the feeder must run concurrently AND be the one
    /// to call finish() on the stream when the file is fully fed. Only after
    /// start returns do we finalize (flushing any late finals) and let the
    /// result-collection task drain to completion. Cancelling the collector
    /// before finalize would drop late finals — the previous empty-transcript bug.
    static func transcribe(file: AVAudioFile) async -> String {
        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return ""
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
            return ""
        }

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Accumulate finals as they stream in (off the main actor). The results
        // sequence throws, so this Task's failure type is Error.
        let collected = FinalCollector()
        let recognizerTask = Task<Void, Error> {
            for try await result in transcriber.results {
                if result.isFinal {
                    collected.append(String(result.text.characters))
                }
            }
        }

        // Feeder: convert + yield the file's PCM, then finish() the stream so
        // analyzer.start can return. Runs concurrently with the analyzer.
        let feeder = Task<Void, Never> {
            await Self.feed(file: file, converter: converter, into: inputBuilder)
            inputBuilder.finish()
        }
        // Analyzer: consumes the stream; returns once the stream is finished.
        // Drive it on its own task so feeder + collector run concurrently.
        let analyzerTask = Task<Void, Error> {
            try await analyzer.start(inputSequence: inputStream)
        }
        // Wait for feeding + analyzing to complete.
        _ = await feeder.value
        do {
            try await analyzerTask.value
            // Flush any late finals, then let the collector drain them.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // On-device unavailable / threw — fall through with whatever we have.
        }
        // The results sequence ENDS on its own after finalize (returning nil
        // ends the for-await loop). Await its natural completion with a
        // bounded timeout — cancelling IMMEDIATELY after finalize dropped
        // finals still queued in the sequence, which is how long files ended
        // up with only their last line / no transcript at all.
        await Self.awaitCollectorCompletion(recognizerTask)
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
        private var recognizerTask: Task<Void, Error>?
        private var analyzerTask: Task<Void, Never>?
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
            // Collect finals off the audio thread. The results sequence throws,
            // so this Task's failure type is Error.
            recognizerTask = Task<Void, Error> { [transcriber] in
                for try await result in transcriber.results {
                    if result.isFinal {
                        let text = String(result.text.characters)
                        await MainActor.run { self.onFinal(text) }
                    }
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
        func stop() async {
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            // Let the finals collector drain to NATURAL completion (bounded)
            // before tearing down — see transcribe(file:) for why an immediate
            // cancel lost late finals.
            if let recognizerTask {
                await Transcriber.awaitCollectorCompletion(recognizerTask)
            }
            recognizerTask = nil
            analyzerTask?.cancel()
            analyzerTask = nil
        }
    }

    /// Build a live session for the current locale. Returns nil if the
    /// analyzer/format can't be constructed. The caller starts it once recording
    /// begins. If on-device speech is unavailable, finals simply never arrive
    /// and the caller stores a placeholder.
    static func makeLiveSession(onFinal: @escaping @MainActor (String) -> Void) async -> LiveSession? {
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

    /// Await a finals-collector task's natural completion, bounded by a
    /// timeout. After `finalizeAndFinishThroughEndOfInput()` the transcriber's
    /// results sequence should finish on its own; if an OS build keeps it
    /// alive, cancel after the bound so the caller can't hang.
    private static func awaitCollectorCompletion(_ task: Task<Void, Error>) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s bound
                task.cancel()
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Read an AVAudioFile's PCM in chunks, convert each to `format`, and yield
    /// to the builder. Conversion uses the standard AVAudioConverter path. The
    /// convert call returns a status (not a frame count); we yield the output
    /// buffer whenever conversion produced data.
    private static func feed(file: AVAudioFile,
                             converter: AVAudioConverter,
                             into builder: AsyncStream<AnalyzerInput>.Continuation) async {
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return }
        let chunkFrames: AVAudioFrameCount = min(8192, totalFrames)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            return
        }
        let outFormat = converter.outputFormat

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
            // sample-rate / channel aware; feed the input block once.
            let ratio = outFormat.sampleRate / file.processingFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(toRead) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { break }
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
            // Yield only when conversion actually produced output data.
            if status == .haveData || outBuffer.frameLength > 0 {
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

// MARK: - Legacy fallback (SFSpeechRecognizer)

/// Legacy on-device transcription via the pre-SpeechAnalyzer Speech framework
/// (`SFSpeechRecognizer`). Used as the automatic fallback when SpeechAnalyzer
/// is unavailable — e.g. iOS versions / devices without Apple Intelligence, or
/// a locale whose SpeechAnalyzer asset hasn't been downloaded. Without this
/// fallback, such devices produced "🎙 ... (no transcript)" placeholders.
///
/// Whole-audio correctness (the classic chunk-overwrite pitfall):
///   - When the recognizer supports on-device recognition, ONE request covers
///     the WHOLE file — on-device requests have no per-request duration limit,
///     so no segmentation is needed and nothing can be dropped or reordered.
///   - Only when on-device is unsupported (server-based recognition, which iOS
///     caps at ~1 minute per request) does the file get split — into ~50s
///     segments, written as temp files, and transcribed STRICTLY SEQUENTIALLY,
///     each segment's result APPENDED in order to the previous one. There is
///     exactly one in-flight request at a time and each result lands exactly
///     once, so no segment can overwrite another's transcript.
enum LegacyTranscriber {

    /// Entry point: authorize, pick a recognizer for the current locale, and
    /// route to whole-file or segmented transcription. Returns "" on failure —
    /// callers already handle the empty case with a placeholder.
    static func transcribe(url: URL) async -> String {
        // SpeechAnalyzer still gates on SFSpeechRecognizer authorization, and
        // so does this legacy path.
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { return "" }

        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return "" }

        if recognizer.supportsOnDeviceRecognition {
            // On-device: one request for the whole file (no 1-minute cap).
            let text = await transcribeFile(url: url, recognizer: recognizer, forceOnDevice: true)
            if !text.isEmpty { return text }
            // Fall through: supportsOnDeviceRecognition can report true while
            // the on-device asset is actually missing or failed mid-request —
            // the server-segmented path is the remaining option.
        }
        // Server-based recognition is ~1 min/request → segment + append.
        return await transcribeSegmented(url: url, recognizer: recognizer)
    }

    /// One SFSpeechURLRecognitionRequest over the whole file. Awaits the final
    /// result (no partials), with a generous timeout so a wedged request can't
    /// hang the import queue forever.
    private static func transcribeFile(url: URL, recognizer: SFSpeechRecognizer, forceOnDevice: Bool) async -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if forceOnDevice { request.requiresOnDeviceRecognition = true }

        // Shared between the recognition child task and the timeout child
        // task: whichever finishes first wins, the continuation resumes
        // exactly once, and the recognition task is cancelled ONLY on a real
        // timeout. (The previous design used an unstructured watcher Task
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
                // Safety valve: whole-file on-device gets 15 min (long journals
                // are fine); server-based segment/short-file gets 90s per
                // request. On expiry, resume with nil (no-op if already done)
                // and cancel the recognition task.
                let budget: UInt64 = forceOnDevice ? 15 * 60 : 90
                try? await Task.sleep(nanoseconds: budget * 1_000_000_000)
                // Cancelled because the recognition finished first — no-op.
                guard !Task.isCancelled else { return nil }
                box.timedOut()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ""
        }
    }

    /// Server-based path (~1 min cap per request): split the audio into ~50s
    /// temp segments and transcribe them STRICTLY IN ORDER, appending each
    /// result to the accumulated transcript. One request in flight at a time;
    /// each segment appends exactly once — no overwrites, no reordering.
    private static func transcribeSegmented(url: URL, recognizer: SFSpeechRecognizer) async -> String {
        guard let segments = try? splitIntoSegments(url: url, segmentSeconds: 50),
              !segments.isEmpty else {
            // Splitting failed — try one whole-file request anyway; short files
            // (under a minute) fit in a single server request.
            return await transcribeFile(url: url, recognizer: recognizer, forceOnDevice: false)
        }
        defer { segments.forEach { try? FileManager.default.removeItem(at: $0) } }
        var parts: [String] = []
        for segment in segments {
            let text = await transcribeFile(url: segment, recognizer: recognizer, forceOnDevice: false)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: " ")
    }

    /// Split an audio file into ~`segmentSeconds` temp .caf files on frame
    /// boundaries (no re-encoding — the source format is written as-is). The
    /// temp files live in the system temp dir; the caller removes them.
    private static func splitIntoSegments(url: URL, segmentSeconds: Double) throws -> [URL] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return [] }
        let framesPerSegment = Int(format.sampleRate * segmentSeconds)
        guard framesPerSegment > 0 else { return [] }

        var segments: [URL] = []
        var frameOffset = 0
        while frameOffset < totalFrames {
            let toRead = AVAudioFrameCount(min(framesPerSegment, totalFrames - frameOffset))
            let segURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("slowclaw-stt-\(UUID().uuidString).caf")
            let out = try AVAudioFile(forWriting: segURL, settings: format.settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
            try file.read(into: buffer, frameCount: toRead)
            try out.write(from: buffer)
            segments.append(segURL)
            frameOffset += Int(toRead)
        }
        return segments
    }
}

/// Single-resume outcome box shared by the recognition callback and the
/// timeout task: the checked continuation resumes exactly once (a recognition
/// error can arrive after a final result), and the SFSpeechRecognitionTask is
/// cancelled only when a real timeout fires (cancelling a finished task would
/// be a harmless no-op, but the guard keeps the intent explicit). All state is
/// behind one lock; safe to touch from the callback queue and both tasks.
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

    /// Timeout fired: resume with nil if not already resumed, and stop the
    /// recognition task so its engine work doesn't continue headless.
    func timedOut() {
        lock.lock()
        let target = cont
        cont = nil
        let task = self.task
        lock.unlock()
        target?.resume(returning: nil)
        task?.cancel()
    }
}
