import SwiftUI

struct ReadsView: View {
    @EnvironmentObject private var reads: ReadsStore
    @Binding var section: DiscoverSection
    @State private var showWriters = false

    private var themes: [String] {
        var seen: [String] = []
        for a in reads.articles where !seen.contains(a.theme) { seen.append(a.theme) }
        return seen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let error = reads.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if reads.articles.isEmpty {
                        if reads.loading {
                            ProgressView("Finding essays for your themes…").frame(maxWidth: .infinity).padding(.top, 60)
                        } else if reads.error == nil {
                            ContentUnavailableView("No essays yet", systemImage: "text.book.closed",
                                                   description: Text("Long reads from independent writers, matched on this iPhone to the chapters of your book. Pull down to look."))
                        }
                    }
                    ForEach(themes, id: \.self) { theme in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(theme).font(.headline)
                            ForEach(reads.articles.filter { $0.theme == theme }) { a in
                                NavigationLink(value: a.id) {
                                    ReadCard(article: a, opened: reads.opened.contains(a.id))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !reads.articles.isEmpty {
                        Text("Essays published on Nostr by writers you choose, matched on this iPhone to the chapters of your book. Nothing about you was sent: the relays only see the list of writers.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in ArticleReaderView(articleID: id) }
            .toolbar {
                ToolbarItem(placement: .principal) { DiscoverPicker(section: $section) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showWriters = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Writers")
                }
            }
            .refreshable { await reads.refresh() }
            .sheet(isPresented: $showWriters) { WritersView() }
            .task { if reads.isStale { await reads.refresh() } }
        }
    }
}

struct ReadCard: View {
    let article: ReadArticle
    let opened: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(opened ? .secondary : .primary)
                .multilineTextAlignment(.leading)
            if !article.summary.isEmpty {
                Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 6) {
                Text(article.author)
                Text("·")
                Text("\(article.minutes) min read")
                Text("·")
                Text(article.published, format: .relative(presentation: .named))
                if opened { Label("Read", systemImage: "checkmark.circle").labelStyle(.titleAndIcon) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
    }
}

/// A quiet reader for one essay, set like the book.
struct ArticleReaderView: View {
    @EnvironmentObject private var reads: ReadsStore
    @Environment(\.openURL) private var openURL
    let articleID: String
    @State private var blocks: [ArticleMarkdown.Block] = []

    var body: some View {
        if let article = reads.articles.first(where: { $0.id == articleID }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(article.theme).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).textCase(.uppercase)
                        Text(article.title).font(.system(.title, design: .serif).weight(.semibold))
                        Text("\(article.author) · \(article.published.formatted(date: .abbreviated, time: .omitted)) · \(article.minutes) min read")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)

                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        Label("Published on Nostr by \(article.author). The signature was checked on this iPhone.",
                              systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let link = article.link {
                            Button { openURL(link) } label: { Label("Open the original in a browser", systemImage: "safari") }
                                .font(.footnote)
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let link = article.link {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: link, subject: Text(article.title)) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                    }
                }
            }
            .task(id: articleID) {
                blocks = ArticleMarkdown.blocks(article.content)
                reads.markOpened(article)
            }
        } else {
            ContentUnavailableView("Essay no longer available", systemImage: "text.book.closed")
        }
    }

    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }

    @ViewBuilder
    private func blockView(_ block: ArticleMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ArticleMarkdown.inline(text))
                .font(.system(headingStyle(level), design: .serif).weight(.semibold))
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(ArticleMarkdown.inline(text))
                .font(.system(.body, design: .serif))
                .lineSpacing(5)
                .textSelection(.enabled)
        case .quote(let text):
            Text(ArticleMarkdown.inline(text))
                .font(.system(.body, design: .serif).italic())
                .lineSpacing(5)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3) }
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(.secondary)
                Text(ArticleMarkdown.inline(text)).font(.system(.body, design: .serif)).lineSpacing(4)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number + ".").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                Text(ArticleMarkdown.inline(text)).font(.system(.body, design: .serif)).lineSpacing(4)
            }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.footnote.monospaced()).textSelection(.enabled)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        case .rule:
            Divider().padding(.vertical, 6)
        }
    }
}

struct WritersView: View {
    @EnvironmentObject private var reads: ReadsStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var adding = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(reads.authors) { a in
                        Toggle(a.name, isOn: Binding(get: { a.enabled }, set: { reads.setEnabled(a, $0) }))
                    }
                    .onDelete { offsets in
                        let list = reads.authors
                        for i in offsets { reads.remove(list[i]) }
                    }
                } header: {
                    Text("Writers")
                } footer: {
                    Text("Their recent essays are matched to your book's chapters on this iPhone. Only clearly related ones are shown. This list is the only thing sent to the Nostr relays.")
                }
                Section {
                    TextField("npub1…", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                    Button {
                        Task {
                            adding = true
                            switch await reads.addAuthor(key) {
                            case .added(let name): message = "\(name) added."; key = ""
                            case .duplicate: message = "That writer is already in your list."
                            case .invalid: message = "Paste a writer's public key. It starts with npub1."
                            }
                            adding = false
                        }
                    } label: {
                        HStack { Text("Add writer"); if adding { Spacer(); ProgressView() } }
                    }
                    .disabled(adding || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Add a writer")
                } footer: {
                    Text("Anyone who publishes long posts on Nostr has a public key. You will find it on their profile.")
                }
            }
            .navigationTitle("Writers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); Task { await reads.refresh() } }
                }
            }
        }
    }
}
