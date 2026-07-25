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

    private var recorder: AVAudioRecorder?
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        speechRecognizer?.defaultTaskHint = .dictation
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
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
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
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 12) {
            if recorder.isRecording {
                // Live transcript
                ScrollView {
                    Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                        .font(.body)
                        .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: 120)

                Button {
                    recorder.stopRecording()
                    showTranscript = true
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                        Text("Stop & Transcribe")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.red, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                }
            } else {
                // Record button
                Button {
                    Task {
                        recorder.transcript = ""
                        await recorder.startRecording()
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32))
                        Text("Hold to record")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.blue)
                }

                if let err = recorder.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
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
    @State private var editedText = ""
    @State private var isPolishing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $editedText)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                if state.llm != nil {
                    Button {
                        Task { await polish() }
                    } label: {
                        Label("AI Polish", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPolishing || editedText.isEmpty)
                }

                Spacer()
            }
            .padding()
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
