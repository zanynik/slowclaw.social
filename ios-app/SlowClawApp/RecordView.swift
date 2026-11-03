import SwiftUI

/// Full-screen recorder. Starts recording as soon as it opens; Done saves and closes.
struct RecordView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var saving = false
    @State private var started = false
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Title (optional)", text: $title)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .padding(.horizontal)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(recorder.transcript.isEmpty ? placeholder : recorder.transcript)
                            .font(.body)
                            .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .id("bottom")
                    }
                    .onChange(of: recorder.transcript) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }

                if let error = recorder.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }

                WaveformView(samples: recorder.samples, color: recorder.isPaused ? .secondary : .red)
                    .frame(height: 64)
                    .padding(.horizontal)

                let _ = recorder.tick
                Text(recorder.elapsedLabel)
                    .font(.system(size: 40, weight: .light, design: .rounded).monospacedDigit())

                HStack(spacing: 48) {
                    Button {
                        Task {
                            if recorder.isPaused { await recorder.resumeRecording() } else { recorder.pauseRecording() }
                        }
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color(.secondarySystemBackground)))
                    }
                    .disabled(!recorder.isRecording || saving)
                    .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")

                    Button {
                        Task { await finish() }
                    } label: {
                        ZStack {
                            Circle().fill(Color.red).frame(width: 84, height: 84)
                            if saving || recorder.isFinalizing {
                                ProgressView().tint(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 28, height: 28)
                            }
                        }
                    }
                    .disabled(saving || !recorder.isRecording)
                    .accessibilityLabel("Stop and save")

                    Color.clear.frame(width: 60, height: 60)
                }
                .padding(.bottom, 24)
            }
            .padding(.top)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) {
                        // A stray tap must not throw away a real recording.
                        if recorder.elapsedSeconds >= 5 { confirmDiscard = true } else { Task { await discard() } }
                    }
                    .disabled(saving)
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard recording", role: .destructive) { Task { await discard() } }
                Button("Keep recording", role: .cancel) {}
            }
            .interactiveDismissDisabled()
            .task {
                guard !started else { return }
                started = true
                await recorder.startRecording()
            }
        }
    }

    private var placeholder: String {
        if recorder.isPaused { return "Paused." }
        if recorder.isRecording { return "Listening… start talking." }
        return "Starting…"
    }

    private func finish() async {
        saving = true
        await recorder.finishRecording()
        processor.saveRecording(title: title, transcript: recorder.transcript, audioURL: recorder.recordedFileURL)
        recorder.recordedFileURL = nil
        recorder.transcript = ""
        dismiss()
    }

    private func discard() async {
        saving = true
        if recorder.isRecording { await recorder.finishRecording() }
        if let url = recorder.recordedFileURL {
            try? FileManager.default.removeItem(at: url)
            TimedTranscriptStore.remove(for: url)
        }
        recorder.recordedFileURL = nil
        recorder.transcript = ""
        dismiss()
    }
}
