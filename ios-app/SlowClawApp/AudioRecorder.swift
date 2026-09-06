// AudioRecorder.swift — audio-first journal capture.
//
// Records a durable m4a to disk while streaming mic audio to a live
// SpeechAnalyzer session (iOS 26+) so the transcript accumulates DURING
// recording — no post-stop batch job, no segmentation, no truncation. This is
// the Voice-Memos-proven path: capture + on-device transcription run together.
//
// Flow:
//   startRecording  → engine tap writes PCM to AVAudioFile (m4a on disk) AND
//                     feeds converted buffers to a SpeechAnalyzer LiveSession;
//                     finals stream into `transcript`.
//   finishRecording → finalize file → stop the session. The caller (JournalView)
//                     auto-saves the journal immediately with the transcript-so-
//                     far (or a "transcribing…" placeholder) and returns to the
//                     list — no review gate.
//
// Timer is wall-clock anchored so backgrounding/foregrounding can never desync
// the displayed elapsed time (the "stuck timer on reopen" bug). A 1s display
// timer just nudges a tick to repaint; the value is always wall-clock correct.
//
// Audio never leaves the device. On-device speech only.

import SwiftUI
import UIKit
import AVFoundation
import Speech

/// Audio recording view model. Records to a file while streaming on-device
/// transcription via SpeechAnalyzer. Wall-clock timer survives backgrounding.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// True when recording is paused (engine stopped, file kept open so resume
    /// appends to the same continuous m4a).
    @Published var isPaused = false
    @Published var isTranscribing = false
    /// True while Stop is flushing the analyzer's final results. The journal
    /// is not auto-saved until this becomes false and `isRecording` flips,
    /// which prevents losing the last spoken phrase.
    @Published var isFinalizing = false
    @Published var transcript = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    /// Display nudge for the recording timer (1s). The real elapsed value is
    /// wall-clock derived (see `elapsedSeconds`), so this only forces a repaint.
    @Published private(set) var tick: Int = 0
    /// Rolling window of recent RMS levels (~60 samples ≈ 6s at 10 Hz) that
    /// drives the waveform during recording. Newest sample is last.
    @Published var samples: [Float] = []
    /// Optional title the user can type while recording (Voice Memos lets you
    /// rename mid-recording). Stored as the journal's first line on save.
    @Published var title = ""

    /// The on-disk m4a URL of the most recent recording. The caller stores the
    /// journal with source="audio_recorded" and media_url = its Documents-
    /// relative path. Reset to nil after the journal is saved.
    @Published var recordedFileURL: URL?

    /// Wall-clock elapsed seconds, derived from the recording start anchor +
    /// accumulated paused time. Always correct across backgrounding/foreground.
    var elapsedSeconds: Int {
        let live = segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        return Int(accumulatedPaused + live)
    }

    /// Wall-clock anchor for the current (unpaused) recording segment. Nil when
    /// not recording or paused.
    private var segmentStartedAt: Date?
    /// Total seconds accumulated across pauses (segments already ended).
    private var accumulatedPaused: TimeInterval = 0

    // Engine-owned state (single mic source for the file write).
    private let audioEngine = AVAudioEngine()
    private var displayTimer: Timer?
    /// True iff the inputNode tap was installed. Tracked so stopRecording only
    /// removes it when present (removeTap on an un-tapped node errors).
    private var tapInstalled = false

    /// The live on-device transcription session (nil when not recording).
    private var liveSession: Transcriber.LiveSession?

    /// Mutable state shared between the main actor (start/stop) and the
    /// audio-thread tap closure (which writes buffers + feeds the analyzer).
    /// These can't live on @MainActor-isolated self because the tap runs off
    /// the main actor.
    private let shared = AudioPipeState()

    /// Where recordings live, as a Documents-relative string. Stored in the
    /// journal's media_url column so the UI can replay it later.
    static let recordingsDirName = "Recordings"

    override init() {
        super.init()
        registerSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Formatted mm:ss for the recording timer.
    var elapsedLabel: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return micGranted && speechGranted
    }

    func startRecording() async {
        guard !isRecording, !isTranscribing, !isFinalizing else { return }
        guard await requestPermissions() else {
            errorMessage = "Microphone and speech recognition permissions are required."
            return
        }

        // Reset state from any prior session.
        transcript = ""
        errorMessage = nil
        recordedFileURL = nil
        audioLevel = 0
        samples = []
        tapInstalled = false
        isPaused = false
        accumulatedPaused = 0

        Self.haptic(.impact)

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord survives backgrounding with the audio background
            // mode and lets us play back later. .defaultToSpeaker avoids the
            // earpiece; .allowBluetooth covers AirPods.
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let key = "journal_\(Int(Date().timeIntervalSince1970))"
            let destDir = Self.recordingsDirectory()
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destURL = destDir.appendingPathComponent("\(key).m4a")

            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)

            // Open the file BEFORE installing the tap so the first buffer is
            // captured. AVAudioFile(forWriting:settings:) derives the channel
            // layout from AVNumberOfChannelsKey. Writing AAC into an .m4a keeps
            // the file small and playable everywhere.
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: micFormat.sampleRate,
                AVNumberOfChannelsKey: micFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            shared.audioFile = try AVAudioFile(forWriting: destURL, settings: fileSettings)
            recordedFileURL = destURL

            // Start the live SpeechAnalyzer session so the transcript streams
            // in during recording (no post-stop batch). Falls back gracefully:
            // if the locale asset is unavailable, recording proceeds without
            // live transcription and the caller stores a placeholder.
            await beginLiveSession(micFormat: micFormat)

            // Capture `shared` strongly so the audio-thread tap doesn't depend
            // on @MainActor-isolated self. The tap writes the buffer to the file
            // and feeds the analyzer (converted).
            let pipe = shared
            let sessionRef = liveSession
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
                do {
                    try pipe.audioFile?.write(from: buffer)
                } catch {
                    // Swallow per-buffer write errors; a gap beats losing the
                    // whole journal.
                }
                // Feed the analyzer the same buffer (converted to its format).
                // A failed conversion drops the buffer (momentary gap) — the
                // original wrong-format buffer is never fed downstream.
                if let sessionRef, let converter = pipe.converter,
                   let converted = Self.convert(buffer, with: converter) {
                    sessionRef.process(converted)
                }
                // Level meter: compute RMS (pure) and throttle the main-actor
                // publish to ~10 Hz via the shared holder's timestamp.
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- pipe.lastLevelTs > 100_000_000 {
                    pipe.lastLevelTs = now
                    let level = Self.rmsLevel(of: buffer)
                    Task { @MainActor in
                        guard let self else { return }
                        self.audioLevel = level
                        // Rolling window for the waveform (keep ~60 samples).
                        self.samples.append(level)
                        if self.samples.count > 60 { self.samples.removeFirst(self.samples.count - 60) }
                    }
                }
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            segmentStartedAt = Date()
            startDisplayTimer()
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            await cleanupFailedStart()
        }
    }

    /// Pause the recording. The engine stops and the tap is removed (no more
    /// buffer writes), but the AVAudioFile is KEPT OPEN so resume appends to
    /// the same continuous m4a. The timer pauses so elapsedSeconds holds.
    /// Use finishRecording() to end the session and finalize.
    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        endSegment() // freeze wall-clock accumulation
        stopDisplayTimer()
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Intentionally do NOT nil shared.audioFile — resume reuses it.
        isPaused = true
        audioLevel = 0
        Self.haptic(.light)
    }

    /// Resume after a pause. Reinstalls the tap and restarts the engine; buffers
    /// keep appending to the same open AVAudioFile, producing one continuous
    /// recording across the pause.
    func resumeRecording() async {
        guard isRecording, isPaused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            let inputNode = audioEngine.inputNode
            let micFormat = inputNode.outputFormat(forBus: 0)
            // Reinstall the tap onto the same open file + analyzer session.
            let pipe = shared
            let sessionRef = liveSession
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
                do {
                    try pipe.audioFile?.write(from: buffer)
                } catch {}
                if let sessionRef, let converter = pipe.converter,
                   let converted = Self.convert(buffer, with: converter) {
                    sessionRef.process(converted)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- pipe.lastLevelTs > 100_000_000 {
                    pipe.lastLevelTs = now
                    let level = Self.rmsLevel(of: buffer)
                    Task { @MainActor in
                        guard let self else { return }
                        self.audioLevel = level
                        self.samples.append(level)
                        if self.samples.count > 60 { self.samples.removeFirst(self.samples.count - 60) }
                    }
                }
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isPaused = false
            segmentStartedAt = Date()
            startDisplayTimer()
            Self.haptic(.light)
        } catch {
            errorMessage = "Could not resume: \(error.localizedDescription)"
            // Fall back to finishing so the partial file is still saved.
            await finishRecording()
        }
    }

    /// End the session: finalize the file and stop the live transcription
    /// session. Sets `transcript` (accumulated from the live session) and
    /// `recordedFileURL`; the caller auto-saves the journal immediately. This
    /// is the "Stop" action — no review gate, full Voice Memos flow.
    func finishRecording() async {
        guard isRecording, !isFinalizing else { return }
        isFinalizing = true
        endSegment()
        stopDisplayTimer()

        // Stop the engine + remove the tap if still installed (pause may have
        // already removed it).
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Finalize the file. Dropping the AVAudioFile reference flushes +
        // closes the m4a.
        shared.audioFile = nil

        audioLevel = 0
        samples = []

        // Flush the live transcription session BEFORE isRecording becomes
        // false. JournalView observes that transition to auto-save, so this
        // ordering guarantees the saved body contains the complete finalized
        // stream rather than a pre-flush preview.
        let session = liveSession
        liveSession = nil
        shared.converter = nil
        if let completed = await session?.stop(), !completed.isEmpty {
            transcript = completed
        } else if session != nil {
            // A failed/undrained live session cannot vouch for a partial
            // preview. Save a placeholder and let the durable file queue use
            // the offline long-form path.
            transcript = ""
        }

        isFinalizing = false
        isRecording = false
        isPaused = false
        Self.haptic(.success)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    /// Legacy alias kept for call sites that mean "end and finalize."
    @inlinable func stopRecording() async { await finishRecording() }

    // MARK: - Live transcription session

    /// Build + start a SpeechAnalyzer LiveSession for the current locale. Sets
    /// up the format converter from the mic format. On final results, appends
    /// to `transcript`. No-op (graceful) if the locale asset is unavailable.
    private func beginLiveSession(micFormat: AVAudioFormat) async {
        isTranscribing = true
        defer { isTranscribing = false }
        let session: Transcriber.LiveSession
        do {
            session = try await Transcriber.makeLiveSession { [weak self] snapshot in
                // Snapshot already combines immutable finals with the latest
                // replaceable volatile phrase, so revisions never duplicate.
                self?.transcript = snapshot
            }
        } catch {
            // Recording remains available even if model installation fails.
            // Stop will enqueue the durable file for offline/fallback STT.
            errorMessage = "Live transcription: \(error.localizedDescription). Audio will be transcribed after saving."
            return
        }
        // Store the mic→analyzer converter on the shared (non-isolated) holder
        // so the audio-thread tap can read it without crossing actor isolation.
        shared.converter = AVAudioConverter(from: micFormat, to: session.analyzerFormat)
        liveSession = session
        session.start()
    }

    /// Tear down resources allocated before `isRecording` became true. A
    /// start failure used to call finishRecording(), whose guard then skipped
    /// cleanup and left the audio session/file open.
    private func cleanupFailedStart() async {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        shared.audioFile = nil
        shared.converter = nil
        let session = liveSession
        liveSession = nil
        _ = await session?.stop()
        isRecording = false
        isPaused = false
        isFinalizing = false
        isTranscribing = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    /// Convert a PCM buffer from the mic format to the analyzer format.
    /// Returns the converted buffer, or nil when the buffer must be DROPPED
    /// (allocation failure, conversion error, or no output produced) — the
    /// original wrong-format buffer is never returned or passed downstream.
    /// Pure — safe from the audio thread.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) *
            (converter.outputFormat.sampleRate / converter.inputFormat.sampleRate)) + 32
        guard outCap > 0, let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outCap) else {
            return nil // allocation failure: drop this buffer
        }
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                // More mic buffers are coming after this one — this is NOT
                // the end of the stream. (Reporting .endOfStream per buffer
                // would tell the reused converter the stream is over and
                // poison every subsequent conversion.)
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        // Yield the converted buffer only when conversion succeeded AND
        // produced data; anything else drops the buffer (a dropped mic
        // buffer is a momentary gap, a wrong-format buffer is a broken
        // transcript).
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    // MARK: - Wall-clock timer

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick &+= 1 }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Freeze the current segment's elapsed time into `accumulatedPaused` and
    /// drop the anchor. Called on pause/finish so the display holds.
    private func endSegment() {
        if let start = segmentStartedAt {
            accumulatedPaused += Date().timeIntervalSince(start)
            segmentStartedAt = nil
        }
    }

    // MARK: - Session observers

    private func registerSessionObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began, isRecording, !isPaused {
            // Another app took audio (call, Siri). PAUSE (don't hard-stop) so
            // the user can resume and keep the same continuous file — Voice
            // Memos behavior. The partial file is on disk and safe.
            pauseRecording()
            errorMessage = "Paused by interruption. Tap resume to continue."
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable, isRecording, !isPaused {
            // Mic physically gone (AirPods unplugged) — pause so the user can
            // reconnect and resume, rather than abruptly ending.
            pauseRecording()
            errorMessage = "Paused — audio device disconnected."
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        Task { @MainActor in
            if isRecording { await finishRecording() }
            errorMessage = "Audio system reset. Please start the recording again."
        }
    }

    // MARK: - Paths + helpers

    /// Absolute URL of Documents/Recordings/.
    static func recordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(recordingsDirName, isDirectory: true)
    }

    /// Documents-relative path for a recording URL, suitable for the journal
    /// media_url column. Returns nil if the URL isn't under Documents.
    static func documentsRelativePath(for url: URL) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let docsPath = docs.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(docsPath) else { return nil }
        let rel = String(urlPath.dropFirst(docsPath.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }

    /// Resolve a stored media_url (e.g. "Recordings/journal_123.m4a") back to
    /// an absolute file URL under Documents. The inverse of
    /// documentsRelativePath(for:). Used by the playback UI to play a saved
    /// recording. Returns nil if the path is empty.
    static func absoluteURL(forMediaRelativePath rel: String?) -> URL? {
        guard let rel, !rel.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(rel)
    }

    /// Decode an audio file and bucket its PCM into ~N RMS levels for a static
    /// playback waveform. `buckets` defaults to 48 to match WaveformView's bar
    /// count. Each level is normalized [0..1]. Runs on the calling thread; the
    /// detail view calls it once on appear via a detached Task.
    static func extractLevels(from url: URL, buckets: Int = 48) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }
        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let framesPerBuffer = AVAudioFrameCount(min(Int(framesPerBucket), 8192))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer) else {
            return []
        }

        var levels: [Float] = []
        var framesRead: AVAudioFrameCount = 0
        var sumSq: Float = 0
        var samplesInBucket: Int = 0

        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let toRead = min(framesPerBuffer, remaining)
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }
            guard let data = buffer.floatChannelData else { break }
            let ch = data[0]
            for i in 0..<Int(toRead) {
                let s = ch[i]
                sumSq += s * s
                samplesInBucket += 1
                if samplesInBucket >= framesPerBucket {
                    let rms = sqrt(sumSq / Float(samplesInBucket))
                    levels.append(min(1, rms * 3.0))
                    sumSq = 0
                    samplesInBucket = 0
                    if levels.count >= buckets { break }
                }
            }
            framesRead += toRead
            if levels.count >= buckets { break }
        }
        // Pad to the requested bucket count so the wave looks symmetric.
        while levels.count < buckets { levels.append(0.04) }
        return levels
    }

    /// Normalized [0..1] level from a PCM buffer's RMS. Pure — safe from the
    /// audio-thread tap; the result is published on main.
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ch = data[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = ch[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        return max(0, min(1, rms * 3.0))
    }

    // MARK: - Haptics

    private enum HapticKind { case impact, light, success }

    /// Physical confirmation that the capture state changed — a big part of why
    /// Voice Memos feels reliable. impact = record start; light = pause/resume;
    /// success = finished (saved).
    private static func haptic(_ kind: HapticKind) {
        switch kind {
        case .impact:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

/// Nonisolated holder for the mutable audio-pipe state shared between the main
/// actor (start/stop) and the AVAudioEngine tap closure (audio thread). The
/// engine serializes tap callbacks, and start/stop run on main before/after
/// the tap's lifetime, so the two sides never mutate the same field concurrently.
final class AudioPipeState: @unchecked Sendable {
    var audioFile: AVAudioFile?
    /// Mic→analyzer format converter, set when the live session starts. Read
    /// from the audio-thread tap to feed converted buffers to the analyzer.
    var converter: AVAudioConverter?
    /// Last level-publish timestamp (uptime nanoseconds); throttles meter
    /// updates from the audio-thread tap to ~10 Hz.
    var lastLevelTs: UInt64 = 0
}


/// A rolling waveform of recent RMS samples — Voice Memos / ChatGPT style.
/// Renders trailing bars that grow with loudness and decay over time. Newest
/// sample is on the right; older samples drift left and shrink.
struct WaveformView: View {
    let samples: [Float]
    var color: Color
    /// Number of bars to render. More bars = denser, finer wave.
    private let barCount: Int = 48

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: barSpacing(width: geo.size.width)) {
                ForEach(0..<barCount, id: \.self) { i in
                    bar(for: mappedSample(at: i))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Map the rolling samples window onto the fixed bar grid. The newest
    /// samples (end of the array) map to the rightmost bars; missing/old
    /// slots on the left fall back to a small floor so the wave looks alive.
    private func mappedSample(at barIndex: Int) -> Float {
        // Right-align: the rightmost bar is the newest sample.
        let offset = barCount - 1 - barIndex
        let idx = samples.count - 1 - offset
        if idx >= 0 && idx < samples.count {
            return samples[idx]
        }
        // Floor for slots without data yet (keeps the wave symmetric).
        return 0.04
    }

    private func bar(for level: Float) -> some View {
        let height = max(3, CGFloat(level) * 64)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(0.55 + CGFloat(level) * 0.45))
            .frame(height: height)
            .animation(.easeOut(duration: 0.08), value: samples)
    }

    private func barSpacing(width: CGFloat) -> CGFloat {
        // ~70% bars, 30% gaps for a clean wave look.
        let totalWidth = width
        let approxBarWidth: CGFloat = 4
        let gap = max(1, (totalWidth - CGFloat(barCount) * approxBarWidth) / CGFloat(barCount))
        return gap
    }
}
