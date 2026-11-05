import SwiftUI

enum DiscoverSection: String, CaseIterable, Identifiable {
    case news = "News", videos = "Videos"
    var id: String { rawValue }
}

/// News and Videos share a tab; the switcher sits in the navigation bar.
struct DiscoverView: View {
    @AppStorage("slowclaw.discover.section") private var section: DiscoverSection = .news

    var body: some View {
        switch section {
        case .news: NewsView(section: $section)
        case .videos: VideosView(section: $section)
        }
    }
}

struct DiscoverPicker: View {
    @Binding var section: DiscoverSection
    var body: some View {
        Picker("Discover", selection: $section) {
            ForEach(DiscoverSection.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }
}

struct VideosView: View {
    @EnvironmentObject private var videos: VideoStore
    @EnvironmentObject private var store: Store
    @Environment(\.openURL) private var openURL
    @Binding var section: DiscoverSection
    @State private var showGoals = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let error = videos.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if videos.goals.isEmpty {
                        if videos.loading { ProgressView("Reading your journal…").frame(maxWidth: .infinity).padding(.top, 60) }
                        else {
                            ContentUnavailableView("No suggestions yet", systemImage: "play.rectangle",
                                                   description: Text("SlowClaw reads your recent entries on this iPhone and suggests videos for what you want to understand better. Pull down to start."))
                        }
                    }
                    ForEach(videos.goals.filter(\.enabled)) { goal in
                        goalSection(goal)
                    }
                    if !videos.goals.isEmpty {
                        Text("Only the searches shown were sent to YouTube. The reasons were worked out on this iPhone and stay here.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { DiscoverPicker(section: $section) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showGoals = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Learning goals")
                }
            }
            .refreshable { await videos.refresh(journals: store.visibleJournals) }
            .sheet(isPresented: $showGoals) { LearningGoalsView() }
            .task { if videos.isStale { await videos.refresh(journals: store.visibleJournals) } }
        }
    }

    @ViewBuilder private func goalSection(_ goal: LearningGoal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: goal.kind == "gap" ? "questionmark.circle" : "sparkle.magnifyingglass")
                Text(goal.label).font(.headline)
            }
            Text(goal.why).font(.subheadline).foregroundStyle(.secondary)
            let items = videos.videos.filter { $0.goal == goal.label }
            if items.isEmpty || videos.unreadable.contains(goal.label) {
                if let url = YouTubeResults.searchURL(goal.query) {
                    Button { openURL(url) } label: { Label("Search “\(goal.query)” on YouTube", systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
            }
            ForEach(items) { v in
                Button {
                    videos.markWatched(v)
                    openURL(v.url)
                } label: { VideoCard(video: v, watched: videos.watched.contains(v.id)) }
                .buttonStyle(.plain)
            }
        }
    }
}

struct VideoCard: View {
    let video: VideoItem
    let watched: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: video.thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if !video.duration.isEmpty {
                    Text(video.duration).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(4)
                }
            }
            .opacity(watched ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(3).foregroundStyle(.primary)
                Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if !video.published.isEmpty { Text(video.published) }
                    if watched { Label("Watched", systemImage: "checkmark.circle").labelStyle(.titleAndIcon) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LearningGoalsView: View {
    @EnvironmentObject private var videos: VideoStore
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var newQuery = ""
    @State private var working = false
    @State private var editing: LearningGoal?
    @State private var editText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(videos.goals) { g in
                        Toggle(isOn: Binding(get: { g.enabled }, set: { videos.setEnabled(g, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.label)
                                Button { editing = g; editText = g.query } label: {
                                    Text("Searches: “\(g.query)”").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let list = videos.goals
                        for i in offsets { videos.remove(list[i]) }
                    }
                    HStack {
                        TextField("Something you want to understand", text: $newQuery).onSubmit(add)
                        Button("Add", action: add).disabled(NewsTopics.sanitizeQuery(newQuery) == nil)
                    }
                } header: {
                    Text("Learning goals")
                } footer: {
                    Text("Found on this iPhone in your recent entries. Only the search under each goal is sent to YouTube; your journal and the reasons stay on the phone. Tap a search to change it.")
                }
                Section {
                    Button {
                        Task { working = true; await videos.refreshGoals(from: store.visibleJournals); working = false }
                    } label: {
                        HStack { Text("Suggest goals from my journal"); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Learning goals")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Search for \(editing?.label ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Search", text: $editText)
                Button("Save") { if let g = editing { videos.setQuery(g, editText) }; editing = nil }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: { Text("Only this text is sent to YouTube.") }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); Task { await videos.refresh(journals: store.visibleJournals) } }
                }
            }
        }
    }

    private func add() {
        videos.add(newQuery)
        newQuery = ""
    }
}
