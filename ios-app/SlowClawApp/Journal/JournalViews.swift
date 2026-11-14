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
    @State private var pendingDelete: Journal?

    /// Matches titles, text and space names ("health" finds everything filed under Health).
    private var filtered: [Journal] {
        let all = store.visibleJournals
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        let spaces = Set(store.visibleSpaces.filter { $0.name.localizedCaseInsensitiveContains(q) }.map(\.id))
        return all.filter { j in
            j.title.localizedCaseInsensitiveContains(q) || j.body.localizedCaseInsensitiveContains(q)
                || (j.spaceID.map { spaces.contains($0) } ?? false)
        }
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
                } else if grouped.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(grouped) { group in
                    Section(group.id) {
                        ForEach(group.journals) { j in
                            NavigationLink(value: j.id) { JournalRow(journal: j) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    // Not a destructive role: the row must stay until the delete is confirmed.
                                    Button("Delete", systemImage: "trash") { pendingDelete = j }.tint(.red)
                                }
                                .contextMenu { rowMenu(j) }
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
            .sensoryFeedback(.impact, trigger: showRecorder) { _, opening in opening }
            .confirmationDialog("Delete this entry?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { j in
                Button("Delete entry", role: .destructive) { store.deleteJournal(j.id) }
                Button("Keep", role: .cancel) {}
            } message: { j in
                Text(j.audioPath == nil ? "“\(j.displayTitle)” will be removed from this iPhone and from sync."
                                        : "“\(j.displayTitle)” and its recording will be removed from this iPhone and from sync.")
            }
        }
    }

    /// Long-press a row: file it, share it or delete it without opening it.
    @ViewBuilder
    private func rowMenu(_ j: Journal) -> some View {
        if j.status == .ready {
            Menu {
                ForEach(store.visibleSpaces) { s in
                    Button { store.moveJournal(j.id, toSpace: s.id) } label: {
                        Label(s.name, systemImage: j.spaceID == s.id ? "checkmark" : s.icon)
                    }
                }
            } label: { Label("Move to space", systemImage: "square.grid.2x2") }
            ShareLink(item: [j.displayTitle, j.body].filter { !$0.isEmpty }.joined(separator: "\n\n")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button(role: .destructive) { pendingDelete = j } label: { Label("Delete", systemImage: "trash") }
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
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What's on your mind?").foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            }
            .padding()
            .interactiveDismissDisabled(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @State private var confirmDelete = false
    @FocusState private var typing: Bool
    @StateObject private var player = AudioPlayer()

    private var journal: Journal? { store.journal(journalID) }

    var body: some View {
        Group {
            if let j = journal, !j.deleted {
                Form {
                    Section {
                        TextField("Title", text: $title, axis: .vertical)
                            .font(.title3.weight(.semibold))
                            .focused($typing)
                        if j.status == .ready {
                            TextEditor(text: $bodyText)
                                .frame(minHeight: 240)
                                .focused($typing)
                        } else {
                            Label(j.status == .transcribing ? "Transcribing…" : "Cleaning up…", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        let words = BookEngine.wordCount(bodyText)
                        Text(j.createdAt.formatted(date: .complete, time: .shortened)
                             + (words > 0 ? " · \(words) \(words == 1 ? "word" : "words")" : ""))
                    }

                    Section {
                        Picker(selection: Binding(
                            get: { j.spaceID ?? "" },
                            set: { newValue in store.moveJournal(journalID, toSpace: newValue.isEmpty ? nil : newValue) })) {
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
                                confirmDelete = true
                            } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            if working { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                        }
                        .accessibilityLabel("More")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { typing = false }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete entry", role: .destructive) { store.deleteJournal(journalID); dismiss() }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text(j.audioPath == nil ? "It will be removed from this iPhone and from sync."
                                            : "The entry and its recording will be removed from this iPhone and from sync.")
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
