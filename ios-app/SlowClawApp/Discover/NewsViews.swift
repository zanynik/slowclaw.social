import SwiftUI
import SafariServices

struct NewsView: View {
    @EnvironmentObject private var news: NewsStore
    @EnvironmentObject private var store: Store
    @Binding var section: DiscoverSection
    @State private var showTopics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    topicStrip
                    if let error = news.error {
                        Text(error).font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if news.cards.isEmpty {
                        if news.loading {
                            ProgressView("Finding stories…").padding(.top, 60)
                        } else {
                            ContentUnavailableView("No stories yet",
                                                   systemImage: "newspaper",
                                                   description: Text(news.topics.isEmpty
                                                        ? "Write a few journal entries. SlowClaw works out what you care about on this iPhone and finds news on those topics."
                                                        : "Pull down to look for stories on your topics."))
                        }
                    }
                    ForEach(news.cards) { card in
                        NavigationLink(value: card.id) { NewsCardView(card: card) }
                            .buttonStyle(.plain)
                    }
                    if !news.cards.isEmpty {
                        Text("Only your topic searches were sent to Google News. Stories were ranked on this iPhone against what you wrote.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in NewsDetailView(cardID: id) }
            .refreshable { await news.refresh(journals: store.visibleJournals) }
            .toolbar {
                ToolbarItem(placement: .principal) { DiscoverPicker(section: $section) }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { ReadingHistoryView() } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Reading history")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTopics = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("News topics")
                }
            }
            .sheet(isPresented: $showTopics) { TopicsView() }
            .task {
                if news.isStale { await news.refresh(journals: store.visibleJournals) }
            }
        }
    }

    private var topicStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(news.themeSearches.map(\.theme) + news.topics.filter { $0.enabled && !$0.fromJournal }.map(\.name), id: \.self) { name in
                    Text(name).font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                Button { showTopics = true } label: {
                    Label("Topics", systemImage: "plus").font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct NewsCardView: View {
    @EnvironmentObject private var news: NewsStore
    let card: NewsCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NewsImage(card: card).frame(height: 170).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(card.topic.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(card.headline).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !card.summary.isEmpty {
                    Text(card.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "newspaper").font(.caption2)
                    Text(card.sourcesLabel)
                    if let newest = card.newest {
                        Text("·")
                        Text(newest, format: .relative(presentation: .named))
                    }
                    Spacer()
                    if news.isRead(card) { Label("Read", systemImage: "checkmark.circle").font(.caption2).labelStyle(.titleAndIcon) }
                    if card.summarized { Image(systemName: "sparkles").font(.caption2) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct NewsImage: View {
    let card: NewsCard

    var body: some View {
        if card.hasImage, let image = UIImage(contentsOfFile: NewsStore.imageURL(for: card.id).path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [gradientColor.opacity(0.85), gradientColor.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(card.topic.prefix(1).uppercased())
                    .font(.system(size: 64, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var gradientColor: Color {
        let hash = card.topic.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return BookPalette.color(hash)
    }
}

struct NewsDetailView: View {
    @EnvironmentObject private var news: NewsStore
    @EnvironmentObject private var store: Store
    let cardID: String
    @State private var reading: URL?
    @State private var opened: (article: NewsArticle, at: Date)?

    var body: some View {
        if let card = news.cards.first(where: { $0.id == cardID }) {
            List {
                Section {
                    NewsImage(card: card).frame(height: 200).clipped().listRowInsets(EdgeInsets())
                    VStack(alignment: .leading, spacing: 10) {
                        Text(card.headline).font(.title2.weight(.semibold))
                        if !card.summary.isEmpty { Text(card.summary) }
                        if card.summarized {
                            Label("Summarized on this iPhone from the headlines below.", systemImage: "sparkles")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                let related = NewsTopics.matches(topic: card.topic, in: store.visibleJournals)
                if !related.isEmpty {
                    Section {
                        ForEach(related.prefix(5), id: \.self) { id in
                            if let j = store.journal(id) {
                                NavigationLink {
                                    JournalDetailView(journalID: id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(j.displayTitle).lineLimit(1)
                                        Text(j.createdAt.dayLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Why you're seeing this")
                    } footer: {
                        Text("You wrote about \(card.topic) in \(related.count) \(related.count == 1 ? "entry" : "entries"). This link is made on your iPhone and is never sent anywhere.")
                    }
                }

                Section("Sources") {
                    ForEach(card.articles) { a in
                        Button {
                            reading = URL(string: a.url)
                            opened = (a, Date())
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(a.title).foregroundStyle(.primary)
                                    if news.history.contains(where: { $0.url == a.url }) {
                                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                            .accessibilityLabel("Read")
                                    }
                                }
                                HStack {
                                    Text(a.source)
                                    if let p = a.published { Text("·"); Text(p, format: .relative(presentation: .named)) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(card.topic)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $reading, onDismiss: {
                if let o = opened { news.recordRead(o.article, topic: card.topic, openedAt: o.at) }
                opened = nil
            }) { url in SafariView(url: url).ignoresSafeArea() }
        } else {
            ContentUnavailableView("Story no longer available", systemImage: "newspaper")
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct TopicsView: View {
    @EnvironmentObject private var news: NewsStore
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var newTopic = ""
    @State private var working = false
    @State private var editing: NewsTopic?
    @State private var editText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(news.topics.filter { !$0.fromJournal }) { t in
                        Toggle(isOn: Binding(get: { t.enabled }, set: { news.setEnabled(t, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name)
                                Button {
                                    editing = t; editText = t.query
                                } label: {
                                    Text("Searches: “\(t.query)”").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let list = news.topics.filter { !$0.fromJournal }
                        for i in offsets { news.remove(list[i]) }
                    }
                    HStack {
                        TextField("Add a topic or a specific search", text: $newTopic)
                            .onSubmit(add)
                        Button("Add", action: add).disabled(NewsTopics.sanitize(newTopic) == nil)
                    }
                } header: {
                    Text("Your topics")
                } footer: {
                    Text("Your own topics, searched as written. Only these searches and the ones below are sent to Google News. Your journal text never leaves the phone.")
                }

                Section {
                    if news.themeSearches.isEmpty {
                        Text("Searches appear once your book has chapters.").foregroundStyle(.secondary)
                    }
                    ForEach(news.themeSearches) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.theme)
                            Text(t.searches.map { "“\($0)”" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("From your book's chapters")
                } footer: {
                    Text("Made on this iPhone from the named things and phrases each chapter keeps returning to; never people or places. Stories are kept only if they are close to what you wrote.")
                }
            }
            .alert("Search for \(editing?.name ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Search", text: $editText)
                Button("Save") { if let t = editing { news.setQuery(t, editText) }; editing = nil }
                Button("Cancel", role: .cancel) { editing = nil }
            } message: {
                Text("Only this text is sent to Google News.")
            }
            .navigationTitle("News topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        Task { await news.refresh(journals: store.visibleJournals) }
                    }
                }
            }
        }
    }

    private func add() {
        news.add(newTopic)
        newTopic = ""
    }
}

/// Everything opened from News, newest first, with the time it stayed open.
struct ReadingHistoryView: View {
    @EnvironmentObject private var news: NewsStore
    @State private var reading: URL?

    var body: some View {
        List {
            if news.history.isEmpty {
                ContentUnavailableView("Nothing read yet", systemImage: "clock", description: Text("Articles you open from News are kept here, with how long you read them."))
            }
            ForEach(news.history) { r in
                Button { reading = URL(string: r.url) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.title).foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(r.source)
                            Text("·")
                            Text(r.openedAt, format: .relative(presentation: .named))
                            if r.seconds >= 5 { Text("·"); Text(Self.duration(r.seconds)) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Forget", role: .destructive) { news.forget(r) } }
            }
        }
        .navigationTitle("Reading history")
        .sheet(item: $reading) { url in SafariView(url: url).ignoresSafeArea() }
    }

    static func duration(_ s: Int) -> String {
        s < 60 ? "\(s)s read" : "\(s / 60) min read"
    }
}
