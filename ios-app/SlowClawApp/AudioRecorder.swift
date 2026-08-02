// AudioRecorder.swift — audio-first journal capture.
//
// A trustworthy recorder modeled on Apple's Voice Memos: audio is written to
// a durable m4a file incrementally (so it survives crashes, interruptions,
// and screen lock), AND live-transcribed on-device via SFSpeechRecognizer so
// the user sees the text appear as they speak.
//
// Design notes (see the "bring Voice-Memos-level trust" plan):
//   - AVAudioRecorder writes AAC/m4a to Documents/Recordings/<key>.m4a,
//     flushing to disk as it goes. This is what survives a phone call or a
//     crash — the file is on disk the whole time, not held in memory.
//   - AVAudioEngine taps the mic in parallel and feeds PCM buffers to
//     SFSpeechAudioBufferRecognitionRequest for the live transcript. Both
//     run under one .playAndRecord session.
//   - Interruption (call/Siri), route change (AirPods unplug), and
//     mediaServicesReset are observed so the recording either resumes or
//     stops cleanly instead of silently dying with isRecording stuck true.
//   - Speech recognition is forced on-device (requiresOnDeviceRecognition =
//     true); audio never leaves the phone. Matches the hardened importer.
//
// The recorder field is no longer dead code.

import SwiftUI
import AVFoundation
import Speech

/// Audio recording + live transcription view model.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var elapsedSeconds: Int = 0

    /// The on-disk m4a URL of the most recent recording, or nil if no file
    /// was produced (e.g. stopped before any audio captured, or an error).
    /// The caller stores the journal with source="audio_recorded" and
    /// media_url set to this path's Documents-relative form.
    @Published var recordedFileURL: URL?

    private var recorder: AVAudioRecorder?
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var timer: Timer?
    /// True iff the inputNode tap was installed in startRecording. Tracked so
    /// stopRecording only removes it when present (removeTap on an un-tapped
    /// node is a runtime error). The tap is conditional on on-device speech
    /// being available for the locale.
    private var tapInstalled = false

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

            // ── Durable file write (the trust foundation) ───────────────────
            // AVAudioRecorder flushes to disk incrementally, so the file is
            // recoverable even if the app crashes mid-recording.
            let key = "journal_\(Int(Date().timeIntervalSince1970))"
            let destDir = Self.recordingsDirectory()
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destURL = destDir.appendingPathComponent("\(key).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let rec = try AVAudioRecorder(url: destURL, settings: settings)
            rec.isMeteringEnabled = true   // drives the level meter
            guard rec.record() else {
                errorMessage = "Could not start the audio recorder."
                return
            }
            recorder = rec
            recordedFileURL = destURL

            // ── Live transcript (on-device) ────────────────────────────────
            // Only start the engine/speech path when on-device recognition is
            // available for this locale; otherwise we still record the file
            // (trust > live UX) and the user transcribes later if desired.
            let onDeviceAvailable = SFSpeechRecognizer.supportsOnDeviceRecognition(for: Locale.current)
            if onDeviceAvailable {
                speechRequest = SFSpeechAudioBufferRecognitionRequest()
                speechRequest?.shouldReportPartialResults = true
                speechRequest?.requiresOnDeviceRecognition = true

                let inputNode = audioEngine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                    self?.speechRequest?.append(buffer)
                }
                tapInstalled = true

                audioEngine.prepare()
                try audioEngine.start()

                speechTask = speechRecognizer?.recognitionTask(with: speechRequest!) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result = result {
                            self.transcript = result.bestTranscription.formattedString
                        }
                        if error != nil {
                            // Speech task failed (e.g. recognizer busy, ~1/min
                            // limit). DON'T stop the durable recording — the
                            // file keeps writing; only the live text stops.
                            self.speechTask?.cancel()
                            self.speechTask = nil
                        }
                    }
                }
            }

            isRecording = true
            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsedSeconds += 1
                    // Poll the recorder's meter for the level UI.
                    self.recorder?.updateMeters()
                    // averagePower is in dBFS [-160..0]; normalize to [0..1].
                    let db = self.recorder?.averagePower(forChannel: 0) ?? -160
                    let norm = max(0, min(1, (db + 60) / 60))
                    self.audioLevel = norm
                }
            }
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            // Clean up any half-started state so isRecording stays honest.
            stopRecording()
        }
    }

    func stopRecording() {
        timer?.invalidate()
        timer = nil

        // Tear down the speech path.
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechRequest = nil
        speechTask = nil

        // Finalize the file. stop() flushes and closes the m4a.
        recorder?.stop()
        recorder = nil

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
                       name: AVAudioSession.mediaServicesResetNotification, object: nil)
    }

    /// An interruption (incoming call, Siri) pauses or stops the recording.
    /// The file written so far is already on disk and safe; we just stop
    /// cleanly on began/resumed so isRecording never lies.
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
            // We stopped on .began, so there's nothing to resume. (Resuming
            // an AVAudioRecorder mid-file requires prepareToRecord + record
            // again and would append; we intentionally keep it simple —
            // Voice Memos also stops on call interruption.)
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

    // MARK: - Paths

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
