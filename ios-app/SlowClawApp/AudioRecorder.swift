// AudioRecorder.swift — audio-first journal capture.
//
// Records a durable m4a to disk, then transcribes the whole file after stop.
// This matches the proven reference (web/src App.tsx + SpeechTranscriber.swift):
// record-then-transcribe, NOT live transcription. Live streaming SFSpeech past
// ~1 minute is unreliable on iOS < 26; segmenting the file post-stop is the
// robust path (see SpeechTranscriber.swift).
//
// Flow:
//   startRecording → engine tap writes PCM to AVAudioFile (m4a on disk)
//   stopRecording  → finalize file → SpeechTranscriber.transcribe(url)
//   TranscriptSheet shows the transcript + audio preview, user saves.
//
// Audio never leaves the device. On-device speech only.

import SwiftUI
import AVFoundation
import Speech

/// Audio recording view model. Records to a file, then transcribes after stop.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript = ""
    @Published var audioLevel: Float = 0
    @Published var errorMessage: String?
    @Published var elapsedSeconds: Int = 0

    /// The on-disk m4a URL of the most recent recording. The caller stores the
    /// journal with source="audio_recorded" and media_url = its Documents-
    /// relative path. Reset to nil after the journal is saved.
    @Published var recordedFileURL: URL?

    // Engine-owned state (single mic source for the file write).
    private let audioEngine = AVAudioEngine()
    private var timer: Timer?
    /// True iff the inputNode tap was installed. Tracked so stopRecording only
    /// removes it when present (removeTap on an un-tapped node errors).
    private var tapInstalled = false

    /// Mutable state shared between the main actor (start/stop) and the
    /// audio-thread tap closure (which writes buffers). These can't live on
    /// @MainActor-isolated self because the tap runs off the main actor.
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
            let format = inputNode.outputFormat(forBus: 0)

            // Open the file BEFORE installing the tap so the first buffer is
            // captured. AVAudioFile(forWriting:settings:) derives the channel
            // layout from AVNumberOfChannelsKey. Writing AAC into an .m4a keeps
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
            // on @MainActor-isolated self. The tap writes the buffer to the file.
            let pipe = shared
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                do {
                    try pipe.audioFile?.write(from: buffer)
                } catch {
                    // Swallow per-buffer write errors; a gap beats losing the
                    // whole journal.
                }
                // Level meter: compute RMS (pure) and throttle the main-actor
                // publish to ~10 Hz via the shared holder's timestamp.
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

            isRecording = true
            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.elapsedSeconds += 1
                }
            }
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            stopRecording()
        }
    }

    /// Stop the recording and transcribe the file on-device. Sets `transcript`
    /// and `recordedFileURL`; the caller presents the review sheet when
    /// `isTranscribing` returns to false.
    func stopRecording() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil

        // Stop the engine + remove the tap (no more buffer writes).
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Finalize the file. Dropping the AVAudioFile reference flushes +
        // closes the m4a.
        shared.audioFile = nil

        isRecording = false
        audioLevel = 0

        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )

        // Transcribe the file on-device, off the main actor. The UI shows a
        // "Transcribing…" state via isTranscribing.
        guard let url = recordedFileURL else { return }
        isTranscribing = true
        Task {
            let transcript = await Task.detached(priority: .userInitiated) {
                await SpeechTranscriber.transcribe(url: url)
            }.value
            self.transcript = transcript
            self.isTranscribing = false
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
        if type == .began, isRecording {
            // Another app took audio. Stop recording; the partial file is on disk.
            stopRecording()
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable, isRecording {
            stopRecording()
        }
    }

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
}

/// Nonisolated holder for the mutable audio-pipe state shared between the main
/// actor (start/stop) and the AVAudioEngine tap closure (audio thread). The
/// engine serializes tap callbacks, and start/stop run on main before/after
/// the tap's lifetime, so the two sides never mutate the same field concurrently.
final class AudioPipeState: @unchecked Sendable {
    var audioFile: AVAudioFile?
    /// Last level-publish timestamp (uptime nanoseconds); throttles meter
    /// updates from the audio-thread tap to ~10 Hz.
    var lastLevelTs: UInt64 = 0
}

// MARK: - Capture UI

/// Audio recording UI — record button, recording state, transcribing state.
/// Embedded in the Journal tab.
struct AudioCaptureView: View {
    @StateObject var recorder = AudioRecorder()
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var showTranscript = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            if recorder.isTranscribing {
                // ── Transcribing: the file is recorded, speech is running ──
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Transcribing…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if recorder.isRecording {
                // ── Recording zen screen ──
                HStack {
                    Spacer()
                    Text(recorder.elapsedLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.muted(scheme))
                }

                VStack(spacing: 12) {
                    Text("Audio capture")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))

                    // Level meter bar — the focus while recording (no live text).
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DS.accent2Color.opacity(0.85))
                            .frame(width: max(8, CGFloat(recorder.audioLevel) * 220), height: 8)
                            .animation(.easeOut(duration: 0.06), value: recorder.audioLevel)
                        Text("Recording…")
                            .font(DS.bodyFont)
                            .foregroundStyle(DS.ink(scheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(DS.accent2Color)
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

                // Pulsing coral stop button → Stop & Save.
                Button {
                    recorder.stopRecording()
                    // Present the sheet once transcription finishes. Use a
                    // small delay + observe isTranscribing via onChange.
                } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [DS.accent2Color, Color(red: 0.83, green: 0.3, blue: 0.23)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 76, height: 76)
                            .shadow(color: DS.accent2Color.opacity(0.4), radius: 12, y: 4)
                            .overlay {
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
                .accessibilityLabel("Stop and transcribe")

                Text("Stop & Transcribe")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.muted(scheme))
            } else {
                // ── Idle: round green record button ──
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
        // When transcription finishes, present the review sheet with the
        // transcript + audio preview.
        .onChange(of: recorder.isTranscribing) { _, nowTranscribing in
            if !nowTranscribing && recorder.recordedFileURL != nil {
                showTranscript = true
            }
        }
        // Also present immediately if there's a recorded file but transcription
        // never started (e.g. on-device speech unavailable edge case).
        .onChange(of: recorder.isRecording) { _, nowRecording in
            if !nowRecording && !recorder.isTranscribing && recorder.recordedFileURL != nil {
                showTranscript = true
            }
        }
        .sheet(isPresented: $showTranscript) {
            // Seed with the transcript, or a placeholder when speech produced
            // nothing (unsupported locale / silent recording). The audio file is
            // always linked via media_url regardless of text content.
            TranscriptSheet(
                transcript: recorder.transcript.isEmpty
                    ? "🎙 Audio journal (no transcript)"
                    : recorder.transcript,
                audioURL: recorder.recordedFileURL
            ) { polished in
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

// MARK: - Transcript sheet (with audio preview)

/// Sheet showing the transcript with an audio preview + AI-polish option.
struct TranscriptSheet: View {
    let transcript: String
    /// Optional audio file to preview before saving.
    var audioURL: URL?
    var onSave: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var editedText = ""
    @State private var isPolishing = false
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Audio preview (if a recording file is available).
                if let url = audioURL {
                    AudioPreviewBar(url: url, player: $audioPlayer)
                }

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
            .navigationTitle(audioURL != nil ? "Recording" : "Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        audioPlayer?.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        audioPlayer?.stop()
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

/// A compact play/pause + scrub bar for previewing a recording before saving.
struct AudioPreviewBar: View {
    let url: URL
    @Binding var player: AVAudioPlayer?
    @Environment(\.colorScheme) var scheme
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DS.accent2Color)
            }
            .buttonStyle(.plain)

            VStack(spacing: 4) {
                ProgressView(value: progress, total: 1.0)
                    .tint(DS.accent2Color)
                Text(url.lastPathComponent)
                    .font(DS.microFont)
                    .foregroundStyle(DS.muted(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
        .onAppear { preparePlayer() }
        .onDisappear {
            timer?.invalidate()
            player?.stop()
        }
    }

    private func preparePlayer() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
        } catch {
            // No preview available — the bar stays, but playback is a no-op.
        }
    }

    private func togglePlayback() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            p.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if p.duration > 0 {
                    progress = p.currentTime / p.duration
                }
                if !p.isPlaying {
                    isPlaying = false
                    progress = 0
                    timer?.invalidate()
                }
            }
        }
    }
}
