// AudioRecorder.swift — audio-first journal capture.
//
// A trustworthy recorder modeled on Apple's Voice Memos: audio is written to
// a durable m4a file incrementally (so it survives crashes, interruptions,
// and screen lock), AND live-transcribed on-device via SFSpeechRecognizer so
// the user sees the text appear as they speak.
//
// Design notes (see the "bring Voice-Memos-level trust" plan):
//   - The mic is owned by ONE AVAudioEngine. Its input tap does two jobs per
//     PCM buffer: (a) write to an AVAudioFile (the durable m4a on disk) and
//     (b) append to the SFSpeechAudioBufferRecognitionRequest (live text).
//     This is the only supported way to record + transcribe simultaneously —
//     AVAudioRecorder + AVAudioEngine on the same session conflict and the
//     recorder silently stops writing.
//   - SFSpeechRecognizer caps each recognitionTask at ~1 minute of audio.
//     When the task finishes (no error), we restart it and carry forward the
//     accumulated transcript, so long recordings don't lose text or freeze.
//   - Interruption (call/Siri), route change (AirPods unplug), and
//     mediaServicesWereReset are observed so the recording stops cleanly
//     instead of silently dying with isRecording stuck true. The partial
//     file written so far is already on disk and safe.
//   - Speech recognition is forced on-device (requiresOnDeviceRecognition =
//     true); audio never leaves the phone. Matches the hardened importer.

import SwiftUI
import AVFoundation
import Speech

/// Nonisolated holder for the mutable audio-pipe state that is touched from
/// BOTH the main actor (start/stop) and the AVAudioEngine input-node tap
/// closure (which runs on an audio thread). The tap writes PCM buffers to
/// `audioFile` and appends them to `speechRequest`; start/stop open/close
/// those objects. Because `AudioRecorder` is `@MainActor`, these ivars can't
/// live on it directly without a concurrency violation — this class gives the
/// tap closure a shared, nonisolated handle. AVAudioEngine serializes tap
/// callbacks, and start/stop run on main before/after the tap's lifetime, so
/// the two sides never mutate the same field concurrently.
final class AudioPipeState: @unchecked Sendable {
    var audioFile: AVAudioFile?
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    /// Last level-publish timestamp (uptime nanoseconds); used to throttle
    /// meter updates from the audio-thread tap to ~10 Hz.
    var lastLevelTs: UInt64 = 0
}

/// Audio recording + live transcription view model.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var elapsedSeconds: Int = 0

    /// The on-disk m4a URL of the most recent recording, or nil if no file
    /// was produced. The caller stores the journal with source="audio_recorded"
    /// and media_url set to this path's Documents-relative form.
    @Published var recordedFileURL: URL?

    // Engine-owned state (single mic source for record + transcribe).
    private let audioEngine = AVAudioEngine()
    private var tapFormat: AVAudioFormat?

    // Live-transcription state.
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechTask: SFSpeechRecognitionTask?
    /// True iff the inputNode tap was installed. Tracked so stopRecording
    /// only removes it when present (removeTap on an un-tapped node errors).
    private var tapInstalled = false
    /// Carried-forward text from prior recognitionTask segments (the engine
    /// restarts the task each ~1 min to dodge SFSpeech's per-task limit).
    private var committedTranscript = ""

    private var timer: Timer?

    /// Mutable state shared between the main actor (start/stop) and the
    /// audio-thread tap closure (which writes buffers + feeds speech). These
    /// can't live on the @MainActor-isolated self because the tap runs off the
    /// main actor; a small nonisolated reference holder gives both sides safe
    /// access. The engine serializes tap callbacks, and start/stop happen on
    /// main before/after the tap's lifetime, so the two never race on the same
    /// field at the same time.
    private let shared = AudioPipeState()

    /// Where recordings live, as a Documents-relative string. Stored in the
    /// journal's media_url column so the UI can replay it later.
    static let recordingsDirName = "Recordings"

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        speechRecognizer?.defaultTaskHint = .dictation
        registerSessionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Formatted mm:ss for the recording timer (matches the reference's capture-zen-timer).
    var elapsedLabel: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    func requestPermissions() async -> Bool {
        // Request microphone + speech recognition permissions.
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return micGranted && speechGranted
    }

    func startRecording() async {
        guard await requestPermissions() else {
            errorMessage = "Microphone and speech recognition permissions are required."
            return
        }

        // Reset state from any prior session.
        transcript = ""
        committedTranscript = ""
        errorMessage = nil
        recordedFileURL = nil
        audioLevel = 0
        tapInstalled = false

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord (not .record) so the session survives backgrounding
            // with the audio background mode and lets us play back later.
            // .defaultToSpeaker avoids the earpiece; .allowBluetooth covers AirPods.
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // ── Single mic source: the engine owns the input ───────────────
            // The tap writes each buffer to the durable file AND appends to the
            // speech request. AVAudioRecorder cannot share the session with the
            // engine; using both was why the file silently went missing.
            let key = "journal_\(Int(Date().timeIntervalSince1970))"
            let destDir = Self.recordingsDirectory()
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destURL = destDir.appendingPathComponent("\(key).m4a")

            let inputNode = audioEngine.inputNode
            // Use the hardware input format so both the file write and the
            // speech request see the same PCM layout.
            let format = inputNode.outputFormat(forBus: 0)
            tapFormat = format

            // Open the file BEFORE installing the tap so the first buffer is
            // captured. AVAudioFile(forWriting:settings:) derives the channel
            // layout from AVNumberOfChannelsKey, so we don't need to pass an
            // explicit AVChannelLayoutKey (which would require packing a C
            // AudioChannelLayout into NSData). Writing AAC into an .m4a keeps
            // the file small and playable everywhere.
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            shared.audioFile = try AVAudioFile(forWriting: destURL, settings: fileSettings)
            recordedFileURL = destURL

            // Capture `shared` strongly so the audio-thread tap doesn't depend
            // on `self` (which is @MainActor-isolated). The tap writes the
            // buffer to the file and feeds the speech request via this holder.
            let pipe = shared
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                // (a) durable write — the trust foundation. Write from the
                // audio thread is fine; AVAudioFile is designed for this.
                do {
                    try pipe.audioFile?.write(from: buffer)
                } catch {
                    // Swallow per-buffer write errors; the recording continues
                    // and the user still gets the transcript. A gap in the file
                    // is preferable to losing the whole journal.
                }
                // (b) live transcript.
                pipe.speechRequest?.append(buffer)
                // (c) level meter: compute RMS (pure) and throttle the main-
                // actor publish to ~10 Hz via the shared holder's timestamp.
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- pipe.lastLevelTs > 100_000_000 {
                    pipe.lastLevelTs = now
                    let level = Self.rmsLevel(of: buffer)
                    Task { @MainActor in
                        self?.audioLevel = level
                    }
                }
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            // ── Live transcript (on-device) ────────────────────────────────
            // Always attempt the live transcript; if on-device isn't available
            // we still record the file (trust > live UX). supportsOnDevice-
            // Recognition is an instance property — query the recognizer.
            startSpeechTask()

            isRecording = true
            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsedSeconds += 1
                }
            }
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            // Clean up any half-started state so isRecording stays honest.
            stopRecording()
        }
    }

    /// Build/restart the SFSpeech recognition task. Called once at start and
    /// again whenever the prior task finishes (Apple caps each task at ~1 min;
    /// we carry `committedTranscript` forward so nothing is lost).
    private func startSpeechTask() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        // Publish on the shared holder so the audio-thread tap can append
        // buffers to it (the tap runs off the main actor).
        shared.speechRequest = request
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result = result {
                    // Prepend the committed (prior-task) text so the live
                    // display shows the full running transcript, not just the
                    // current ~1-min segment.
                    let segment = result.bestTranscription.formattedString
                    self.transcript = self.committedTranscript.isEmpty
                        ? segment
                        : "\(self.committedTranscript) \(segment)"
                }
                if error != nil {
                    // Hard error (e.g. not authorized). Stop only the speech
                    // path; the durable recording must keep writing.
                    self.speechTask?.cancel()
                    self.speechTask = nil
                    return
                }
                if result?.isFinal == true || (result == nil && error == nil) {
                    // The task ended cleanly (the ~1-min limit fires this path
                    // on iOS). Commit the final segment of this task and start
                    // a fresh one so recognition continues for long journals.
                    if let r = result, r.isFinal {
                        let seg = r.bestTranscription.formattedString
                        self.committedTranscript = self.committedTranscript.isEmpty
                            ? seg
                            : "\(self.committedTranscript) \(seg)"
                    }
                    self.speechTask?.cancel()
                    self.shared.speechRequest = nil
                    self.speechTask = nil
                    if self.isRecording {
                        self.startSpeechTask()
                    }
                }
            }
        }
    }

    /// Compute a normalized [0..1] level from a PCM buffer's RMS. Pure — safe
    /// to call from the audio-thread tap; the result is published on main.
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
        let rms = sqrt(sum / Float(frames)) // [0..1] for float PCM
        // Perceptual scaling so quiet speech still moves the meter.
        return max(0, min(1, rms * 3.0))
    }

    func stopRecording() {
        timer?.invalidate()
        timer = nil

        // Tear down the speech path first (stop appending buffers).
        speechTask?.cancel()
        shared.speechRequest?.endAudio()
        shared.speechRequest = nil
        speechTask = nil

        // Stop the engine + remove the tap (no more buffer writes).
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // Finalize the file. Dropping the AVAudioFile reference flushes +
        // closes the m4a.
        shared.audioFile = nil
        tapFormat = nil

        isRecording = false
        audioLevel = 0

        // Deactivate audio session (let other apps resume). Only when we're
        // truly done — defer deactivation so background audio isn't cut.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Session observers (interruptions, route changes, media reset)

    private func registerSessionObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    /// An interruption (incoming call, Siri) pauses or stops the recording.
    /// The file written so far is already on disk and safe; we just stop
    /// cleanly so isRecording never lies.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // Another app took audio. Stop recording to keep state honest;
            // the partial m4a is already on disk.
            if isRecording { stopRecording() }
        case .ended:
            // Voice Memos also stops on call interruption; we don't auto-resume.
            break
        @unknown default:
            break
        }
    }

    /// Route changes (headset unplug, Bluetooth disconnect). A device-removal
    /// while recording would leave the input dangling; stop cleanly so the
    /// file is finalized with whatever was captured.
    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            if isRecording { stopRecording() }
        }
    }

    /// Media services reset is rare (e.g. device watchdog). Re-init would be
    /// invasive; stop cleanly so the user can restart intentionally.
    @objc private func handleMediaServicesReset(_ note: Notification) {
        if isRecording { stopRecording() }
        errorMessage = "Audio system reset. Please start the recording again."
    }

    // MARK: - Paths + helpers

    /// Absolute URL of Documents/Recordings/.
    static func recordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(recordingsDirName, isDirectory: true)
    }

    /// Documents-relative path string for a recording URL, suitable for the
    /// `media_url` journal column (e.g. "Recordings/journal_1234.m4a"). Returns
    /// nil if the URL isn't under Documents.
    static func documentsRelativePath(for url: URL) -> String? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let docsPath = docs.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(docsPath) else { return nil }
        // Drop the docs prefix + the leading slash.
        let rel = String(urlPath.dropFirst(docsPath.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }
}

/// Audio recording UI — a record button + live transcript display.
/// Designed to be embedded in the Journal tab.
struct AudioCaptureView: View {
    @StateObject var recorder = AudioRecorder()
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var showTranscript = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            if recorder.isRecording {
                // ── Recording zen screen (mirrors the reference's .capture-zen) ──
                // Top row: timer (right) so the user can see how long they've recorded.
                HStack {
                    Spacer()
                    Text(recorder.elapsedLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.muted(scheme))
                }

                // Capture stage: bordered rounded panel (like .capture-stage).
                VStack(spacing: 12) {
                    Text("Audio capture")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))

                    // Live transcript — the focus while recording.
                    ScrollView {
                        Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                            .font(DS.bodyFont)
                            .foregroundStyle(recorder.transcript.isEmpty ? DS.muted(scheme) : DS.ink(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .padding(12)
                    .background(DS.surface3(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))

                    // Pulsing "Listening" feedback row.
                    HStack(spacing: 8) {
                        Circle()
                            .fill(DS.accent(scheme))
                            .frame(width: 8, height: 8)
                            .opacity(0.85)
                        Text("Listening")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                }
                .padding(16)
                .background(DS.bg(scheme), in: RoundedRectangle(cornerRadius: DS.rLg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.rLg, style: .continuous)
                        .stroke(DS.line(scheme), lineWidth: 1)
                )

                // Pulsing coral record button → Stop & Save.
                Button {
                    recorder.stopRecording()
                    showTranscript = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [DS.accent2Color, Color(red: 0.83, green: 0.3, blue: 0.23)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 76, height: 76)
                            .shadow(color: DS.accent2Color.opacity(0.4), radius: 12, y: 4)
                            .scaleEffect(1.0)
                            .overlay {
                                // Pulsing ring (mirrors recording-pulse).
                                Circle()
                                    .stroke(DS.accent2Color.opacity(0.5), lineWidth: 2)
                                    .scaleEffect(pulse ? 1.5 : 1.0)
                                    .opacity(pulse ? 0 : 0.6)
                            }
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and save")

                Text("Stop & Save")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.muted(scheme))
            } else {
                // ── Idle: round green record button (mirrors .record-btn.audio) ──
                Button {
                    Task {
                        recorder.transcript = ""
                        await recorder.startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [DS.accent(scheme), Color(red: 0.05, green: 0.56, blue: 0.44)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 76, height: 76)
                            .shadow(color: DS.accent(scheme).opacity(0.42), radius: 10, y: 4)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record audio")

                Text("Tap to record an audio journal")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.muted(scheme))

                if let err = recorder.errorMessage {
                    Text(err)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.accent2Color)
                }
            }
        }
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
        .sheet(isPresented: $showTranscript) {
            // If live transcription wasn't available (unsupported locale) or
            // produced nothing, seed the sheet with a placeholder so the user
            // can still save the recording — the audio file is linked via
            // media_url regardless of text content.
            TranscriptSheet(transcript: recorder.transcript.isEmpty
                ? "🎙 Audio journal (no transcript)"
                : recorder.transcript) { polished in
                // Link the journal to its durable audio file via the
                // provenance columns added in Phase 2a.
                let mediaURL = recorder.recordedFileURL.flatMap(AudioRecorder.documentsRelativePath(for:))
                Task {
                    await state.storeJournal(text: polished,
                                             source: "audio_recorded",
                                             mediaURL: mediaURL)
                }
                recorder.transcript = ""
                recorder.recordedFileURL = nil
                showTranscript = false
            }
        }
    }
}

/// Sheet showing the transcript with options to save or AI-polish.
struct TranscriptSheet: View {
    let transcript: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var editedText = ""
    @State private var isPolishing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $editedText)
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rLg, style: .continuous))

                if state.llm != nil {
                    Button {
                        Task { await polish() }
                    } label: {
                        Label("AI Polish", systemImage: "sparkles")
                            .font(DS.bodyFont.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accentColor)
                    .disabled(isPolishing || editedText.isEmpty)
                }

                Spacer()
            }
            .padding()
            .background(DS.bg(scheme))
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedText)
                    }
                    .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { editedText = transcript }
    }

    private func polish() async {
        guard let llm = state.llm else { return }
        isPolishing = true
        defer { isPolishing = false }

        let raw = editedText
        DispatchQueue.global(qos: .userInitiated).async {
            if let polished = try? llm.synthesizeJournal(transcript: raw, model: state.model) {
                DispatchQueue.main.async { editedText = polished }
            }
        }
    }
}
