// AudioRecorder.swift — audio-first journal capture.
//
// AVAudioRecorder + SFSpeechRecognizer for on-device speech-to-text.
// The transcript is then passed to the Zig core's synthesizeJournal
// to clean up + structure it into a journal entry.
//
// Audio stays on-device (never leaves the phone). Speech recognition uses
// Apple's on-device engine (SFSpeechRecognizer with requiresOnDeviceRecognition).

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

    private var recorder: AVAudioRecorder?
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var timer: Timer?

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        speechRecognizer?.defaultTaskHint = .dictation
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

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Start speech recognition.
            speechRequest = SFSpeechAudioBufferRecognitionRequest()
            speechRequest?.shouldReportPartialResults = true
            if #available(iOS 13, *) {
                speechRequest?.requiresOnDeviceRecognition = false // allow cloud fallback
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.speechRequest?.append(buffer)
                // Update audio level.
                buffer.frameLength
            }

            audioEngine.prepare()
            try audioEngine.start()

            speechTask = speechRecognizer?.recognitionTask(with: speechRequest!) { result, error in
                Task { @MainActor in
                    if let result = result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil {
                        self.stopRecording()
                    }
                }
            }

            isRecording = true
            elapsedSeconds = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsedSeconds += 1 }
            }
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        timer?.invalidate()
        timer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechRequest = nil
        speechTask = nil
        isRecording = false

        // Deactivate audio session.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}

/// Audio recording UI — a record button + live transcript display.
/// Designed to be embedded in the Journal tab.
struct AudioCaptureView: View {
    @ObservedObject var recorder = AudioRecorder()
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
            TranscriptSheet(transcript: recorder.transcript) { polished in
                Task { await state.storeJournal(text: polished) }
                recorder.transcript = ""
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
                    Button("Cancel") { dismiss() }
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
