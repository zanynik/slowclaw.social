import SwiftUI

enum DiscoverSection: String, CaseIterable, Identifiable {
    case news = "News", videos = "Videos", reads = "Reads"
    var id: String { rawValue }
}

/// News, Videos and Reads share a tab; the switcher sits in the navigation bar.
struct DiscoverView: View {
    @AppStorage("slowclaw.discover.section") private var section: DiscoverSection = .news

    var body: some View {
        switch section {
        case .news: NewsView(section: $section)
        case .videos: VideosView(section: $section)
        case .reads: ReadsView(section: $section)
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
        .frame(width: 250)
    }
}

struct VideosView: View {
    @EnvironmentObject private var videos: VideoStore
    @Environment(\.openURL) private var openURL
    @Binding var section: DiscoverSection
    @State private var showChannels = false

    private var themes: [String] {
        var seen: [String] = []
        for v in videos.videos where !seen.contains(v.theme) { seen.append(v.theme) }
        return seen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let error = videos.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if videos.videos.isEmpty {
                        if videos.loading { ProgressView("Finding videos for your themes…").frame(maxWidth: .infinity).padding(.top, 60) }
                        else if videos.error == nil {
                            ContentUnavailableView("No videos yet", systemImage: "play.rectangle",
                                                   description: Text("Recent videos from educational channels, matched on this iPhone to the chapters of your book. Pull down to look."))
                        }
                    }
                    ForEach(themes, id: \.self) { theme in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(theme).font(.headline)
                            ForEach(videos.videos.filter { $0.theme == theme }) { v in
                                Button {
                                    videos.markWatched(v)
                                    openURL(v.url)
                                } label: { VideoCard(video: v, watched: videos.watched.contains(v.id)) }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !videos.videos.isEmpty {
                        Text("Matched on this iPhone to the chapters of your book. Nothing about you was sent: channel feeds are the same for everyone.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { DiscoverPicker(section: $section) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showChannels = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Channels")
                }
            }
            .refreshable { await videos.refresh() }
            .sheet(isPresented: $showChannels) { ChannelsView() }
            .task { if videos.isStale { await videos.refresh() } }
        }
    }
}

struct VideoCard: View {
    let video: VideoItem
    let watched: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: video.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color(.tertiarySystemFill))
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(watched ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(3).foregroundStyle(.primary)
                Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let p = video.published { Text(p, format: .relative(presentation: .named)) }
                    if watched { Label("Watched", systemImage: "checkmark.circle").labelStyle(.titleAndIcon) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ChannelsView: View {
    @EnvironmentObject private var videos: VideoStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var adding = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(videos.channels) { c in
                        Toggle(c.name, isOn: Binding(get: { c.enabled }, set: { videos.setEnabled(c, $0) }))
                    }
                    .onDelete { offsets in
                        let list = videos.channels
                        for i in offsets { videos.remove(list[i]) }
                    }
                } header: {
                    Text("Channels")
                } footer: {
                    Text("Their latest videos are matched to your book's chapters on this iPhone. Only clearly related ones are shown.")
                }
                Section {
                    TextField("youtube.com/channel/UC…", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task {
                            adding = true
                            let ok = await videos.addChannel(link)
                            message = ok ? "Channel added." : "Paste a link that contains the channel id (it starts with UC)."
                            if ok { link = "" }
                            adding = false
                        }
                    } label: {
                        HStack { Text("Add channel"); if adding { Spacer(); ProgressView() } }
                    }
                    .disabled(adding || link.isEmpty)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Add a channel")
                }
            }
            .navigationTitle("Video channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); Task { await videos.refresh() } }
                }
            }
        }
    }
}
