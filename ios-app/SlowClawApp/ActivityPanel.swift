import SwiftUI

/// A lightweight view of actual work, not a second scheduler. Speech keeps
/// its durable queue; optional AI yields between existing native requests.
struct ActivityBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var recorder: AudioRecorder
    @State private var showActivity = false

    private var hasActivity: Bool {
        recorder.isRecording || recorder.isTranscribing || recorder.isFinalizing
            || state.audioTranscriptionInFlight || !state.queuedAudio.isEmpty
            || state.isGeneratingPosts || state.isIndexingInterests
            || !state.pendingTitleKeys.isEmpty || state.optionalAIPaused
            || state.automaticTranscriptionPaused
    }

    private var summary: String {
        if recorder.isFinalizing { return "Finishing your transcript…" }
        if recorder.isRecording { return "Recording · tap to return" }
        if state.audioTranscriptionInFlight { return "Transcribing audio…" }
        if !state.queuedAudio.isEmpty { return "\(state.queuedAudio.count) audio waiting" }
        if state.isGeneratingPosts { return "Preparing drafts…" }
        if state.isIndexingInterests { return state.optionalAIPaused ? "Interest learning paused" : "Learning from journals…" }
        return "Activity · up to date"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let key = state.lastDeletedJournalKey {
                HStack {
                    Text("Moved to Recently Deleted")
                    Spacer()
                    Button("Undo") { state.restore(key: key) }
                    Button { state.lastDeletedJournalKey = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss undo")
                }
                .font(.caption).padding(.horizontal).padding(.vertical, 8)
            }
            if hasActivity {
            Button {
                if recorder.isRecording || recorder.isFinalizing { state.selectedTab = .journal }
                else { state.refreshAudioQueue(); showActivity = true }
            } label: {
                HStack {
                    Image(systemName: recorder.isRecording ? "waveform" : "list.bullet.circle")
                    Text(summary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up")
                }
                .font(.caption).padding(.horizontal).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            }
        }
        .background(.thinMaterial)
        .sheet(isPresented: $showActivity) {
            NavigationStack {
                List {
                    Section("Audio") {
                        if state.audioTranscriptionInFlight {
                            Label(state.audioTranscriptionProgress ?? "Transcribing…", systemImage: "waveform")
                        }
                        if state.queuedAudio.isEmpty && !state.audioTranscriptionInFlight {
                            Label("No recordings waiting", systemImage: "checkmark.circle")
                        }
                        ForEach(state.queuedAudio, id: \.key) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.journals.first(where: { $0.key == item.key }).map(journalTitleOf) ?? "Saved recording")
                                Text(state.transcriptionLabel(for: item.key)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Pause automatic transcription", isOn: $state.automaticTranscriptionPaused)
                        Button("Retry waiting recordings now") { Task { await state.retryQueuedAudio() } }
                            .disabled(state.queuedAudio.isEmpty || state.audioTranscriptionInFlight)
                    }
                    Section("Optional AI") {
                        Toggle("Pause AI work", isOn: $state.optionalAIPaused)
                        if state.isGeneratingPosts { Text(state.generateStatus ?? "Preparing drafts…") }
                        if state.isIndexingInterests { Text(state.interestIndexProgress ?? "Learning journal interests…") }
                        if !state.pendingTitleKeys.isEmpty { Text("\(state.pendingTitleKeys.count) journal titles waiting") }
                        Text("Pause takes effect after the current request. Recording and transcription take priority; optional AI waits when the phone is hot.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("You can keep using other tabs. Audio retries survive relaunch. While the app is closed, iOS decides when background transcription can run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Activity")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showActivity = false } } }
            }
        }
    }
}
