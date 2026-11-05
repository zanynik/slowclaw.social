import SwiftUI
import AVFoundation

struct JournalListView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    @EnvironmentObject private var cloud: CloudSync
    @Binding var showRecorder: Bool
    @State private var search = ""
    @State private var showWriter = false
    @State private var showSettings = false

    private var filtered: [Journal] {
        let all = store.visibleJournals
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
    }

    private struct DayGroup: Identifiable {
        let id: String
        let journals: [Journal]
    }

    private var grouped: [DayGroup] {
        var order: [String] = []
        var map: [String: [Journal]] = [:]
        for j in filtered {
            let key = j.createdAt.dayLabel
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(j)
        }
        return order.map { DayGroup(id: $0, journals: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let activity = processor.activity {
                    Label(activity, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.visibleJournals.isEmpty {
                    ContentUnavailableView("Start journaling",
                                           systemImage: "mic",
                                           description: Text("Tap the red button and just talk. SlowClaw transcribes, tidies up and files it for you."))
                }
                ForEach(grouped) { group in
                    let journals = group.journals
                    Section(group.id) {
                        ForEach(journals) { j in
                            NavigationLink(value: j.id) { JournalRow(journal: j) }
                        }
                        .onDelete { offsets in
                            for i in offsets { store.deleteJournal(journals[i].id) }
                        }
                    }
                }
                Color.clear.frame(height: 90).listRowBackground(Color.clear)
            }
            .searchable(text: $search, prompt: "Search journals")
            .navigationTitle("Journal")
            .navigationDestination(for: String.self) { id in JournalDetailView(journalID: id) }
            .refreshable { await cloud.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWriter = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Write")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .overlay(alignment: .bottom) {
                Button { showRecorder = true } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.red).shadow(radius: 6, y: 3))
                }
                .accessibilityLabel("Record a journal")
                .padding(.bottom, 12)
            }
            .sheet(isPresented: $showWriter) { WriteView() }
        }
    }
}

struct JournalRow: View {
    @EnvironmentObject private var store: Store
    let journal: Journal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(journal.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                if journal.status != .ready {
                    ProgressView().controlSize(.small)
                } else if journal.audioPath != nil {
                    Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !journal.body.isEmpty {
                Text(journal.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(journal.createdAt.timeLabel)
                if let space = store.space(journal.spaceID) {
                    Label(space.name, systemImage: space.icon)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct WriteView: View {
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title (optional)", text: $title).font(.title3.weight(.semibold))
                TextEditor(text: $text).focused($focused)
            }
            .padding()
            .navigationTitle("New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { processor.saveText(title: title, body: text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

struct JournalDetailView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    @Environment(\.dismiss) private var dismiss
    let journalID: String
    @State private var title = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var showOriginal = false
    @State private var working = false
    @State private var continuing = false
    @StateObject private var player = AudioPlayer()

    private var journal: Journal? { store.journal(journalID) }

    var body: some View {
        Group {
            if let j = journal, !j.deleted {
                Form {
                    Section {
                        TextField("Title", text: $title, axis: .vertical)
                            .font(.title3.weight(.semibold))
                        if j.status == .ready {
                            TextEditor(text: $bodyText)
                                .frame(minHeight: 240)
                        } else {
                            Label(j.status == .transcribing ? "Transcribing…" : "Cleaning up…", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(j.createdAt.formatted(date: .complete, time: .shortened))
                    }

                    Section {
                        Picker(selection: Binding(
                            get: { j.spaceID ?? "" },
                            set: { newValue in moveToSpace(newValue.isEmpty ? nil : newValue) })) {
                            Text("Unsorted").tag("")
                            ForEach(store.visibleSpaces) { s in
                                Label(s.name, systemImage: s.icon).tag(s.id)
                            }
                        } label: {
                            Label("Space", systemImage: "square.grid.2x2")
                        }
                    }

                    let fromThis = store.items(fromJournal: j.id)
                    if !fromThis.isEmpty {
                        Section("From this entry") {
                            ForEach(fromThis) { item in ItemRow(item: item) }
                        }
                    }

                    let parts = ([j.audioPath].compactMap { $0 } + (j.moreAudio ?? []))
                        .compactMap { AudioRecorder.absoluteURL(forMediaRelativePath: $0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !parts.isEmpty {
                        Section(parts.count == 1 ? "Recording" : "Recordings") {
                            ForEach(Array(parts.enumerated()), id: \.offset) { index, url in
                                Button {
                                    player.toggle(url)
                                } label: {
                                    let playingThis = player.playing && player.current == url
                                    Label(playingThis ? "Pause" : (parts.count == 1 ? "Play recording" : "Play part \(index + 1)"),
                                          systemImage: playingThis ? "pause.circle" : "play.circle")
                                }
                            }
                            Text("Audio stays on this iPhone and is not synced.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let original = j.transcript, original != j.body {
                        Section {
                            DisclosureGroup("Original transcript", isExpanded: $showOriginal) {
                                Text(original).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if j.status == .ready {
                                Button {
                                    save(); continuing = true
                                } label: { Label("Continue recording", systemImage: "mic.badge.plus") }
                            }
                            Button {
                                Task { working = true; save(); await processor.organize(journalID); working = false }
                            } label: { Label("Organize again", systemImage: "sparkles") }
                            if j.transcript != nil {
                                Button {
                                    Task { working = true; await processor.reclean(journalID); bodyText = store.journal(journalID)?.body ?? bodyText; working = false }
                                } label: { Label("Clean up transcript again", systemImage: "wand.and.stars") }
                            }
                            ShareLink(item: shareText(j)) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) {
                                store.deleteJournal(journalID); dismiss()
                            } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            if working { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
                .onAppear {
                    guard !loaded else { return }
                    title = j.title
                    bodyText = j.body
                    loaded = true
                }
                .onChange(of: j.body) { oldValue, newValue in
                    // Pick up cleanup or sync results unless the user has edited the text.
                    if bodyText == oldValue || bodyText.isEmpty { bodyText = newValue }
                }
                .onChange(of: j.title) { oldValue, newValue in
                    if title == oldValue || title.isEmpty { title = newValue }
                }
                .onDisappear { save(); player.stop() }
            } else {
                ContentUnavailableView("Entry deleted", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $continuing) { RecordView(continuing: journalID) }
    }

    private func save() {
        guard loaded, let j = journal, j.status == .ready else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != j.title || bodyText != j.body {
            store.updateJournal(journalID) { $0.title = t; $0.body = bodyText }
        }
    }

    private func moveToSpace(_ id: String?) {
        store.updateJournal(journalID) { $0.spaceID = id; $0.organized = true }
        // Items extracted from this entry follow it.
        if let id {
            for item in store.items(fromJournal: journalID) { store.updateItem(item.id) { $0.spaceID = id } }
        }
    }

    private func shareText(_ j: Journal) -> String {
        [j.displayTitle, j.body].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Minimal player for a saved recording.
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var current: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing && player?.url == url { player?.pause(); playing = false; return }
        if playing { player?.stop(); playing = false }
        do {
            if player?.url != url {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
            }
            player?.play()
            playing = true
            current = url
        } catch {
            playing = false
        }
    }

    func stop() {
        player?.stop()
        playing = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false }
    }
}
