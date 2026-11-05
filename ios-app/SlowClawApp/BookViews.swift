import SwiftUI

struct BookView: View {
    @EnvironmentObject private var book: BookStore
    @EnvironmentObject private var store: Store
    @State private var openChapter: Int?
    @State private var openNode: String?   // kept for deep links to a passage
    @State private var reading = false
    @State private var confirmRebuild = false

    var body: some View {
        NavigationStack {
            List {
                let chapters = book.chapters
                if chapters.isEmpty {
                    ContentUnavailableView("Your book is empty",
                                           systemImage: "book",
                                           description: Text("As you journal, the passages worth keeping join a living book: grouped into chapters by theme, in the order you lived them."))
                } else {
                    Section("Contents") {
                        ForEach(chapters) { c in
                            Button {
                                openChapter = c.id
                                openNode = nil
                                reading = true
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(c.isLooseEnds ? "" : "\(c.id + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                                    Circle().fill(BookPalette.color(c.id)).frame(width: 8, height: 8)
                                    Text(c.title.isEmpty ? "Chapter \(c.id + 1)" : c.title).foregroundStyle(c.isLooseEnds ? .secondary : .primary)
                                    Spacer()
                                    Text("\(c.passageCount)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let p = book.progress {
                    Section {
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total))) {
                            Text("Polishing passages \(p.done) of \(p.total)").font(.footnote)
                        }
                    } footer: {
                        Text("Passages are shown in your own words right away and tidied up on this iPhone in the background.")
                    }
                }
            }
            .navigationTitle("Book")
            .task { await book.layout() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            openChapter = 0; openNode = nil; reading = true
                        } label: { Label("Read from the start", systemImage: "book.pages") }
                        .disabled(book.passages.isEmpty)
                        Button(role: .destructive) { confirmRebuild = true } label: {
                            Label("Rebuild from all journals", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(isPresented: $reading) {
                BookReaderView(startChapter: openChapter, startNode: openNode)
            }
            .confirmationDialog("Rebuild the book?", isPresented: $confirmRebuild, titleVisibility: .visible) {
                Button("Rebuild", role: .destructive) {
                    book.rebuild()
                    Processor.shared.kick()
                }
            } message: {
                Text("All passages are removed and your journals are read again from the oldest. Waiting passages are cleared.")
            }
        }
    }
}

enum BookPalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .red, .indigo, .brown, .mint]
    static func color(_ chapter: Int) -> Color { colors[abs(chapter) % colors.count] }
}

struct BookReaderView: View {
    @EnvironmentObject private var book: BookStore
    @EnvironmentObject private var store: Store
    let startChapter: Int?
    let startNode: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(book.chapters) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.isLooseEnds ? "Not yet part of a theme" : "Chapter \(c.id + 1)").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                            Text(c.title.isEmpty ? "Untitled" : c.title).font(.system(.title2, design: .serif).weight(.semibold))
                        }
                        .padding(.top, 24)
                        .id("chapter-\(c.id)")
                        ForEach(c.nodes) { n in
                            PassageView(node: n).id(n.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let startNode { proxy.scrollTo(startNode, anchor: .top) }
                else if let startChapter { proxy.scrollTo("chapter-\(startChapter)", anchor: .top) }
            }
        }
        .navigationTitle("Your book")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PassageView: View {
    @EnvironmentObject private var book: BookStore
    @EnvironmentObject private var store: Store
    let node: BookNode

    var body: some View {
        if node.kind != .passage {
            // Lines written on the phone to carry the reader along: visibly not the author's own words.
            Text(node.text)
                .font(.system(node.kind == .intro ? .callout : .footnote, design: .serif).italic())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
                .accessibilityLabel("Connecting line: \(node.text)")
        } else {
            passage
        }
    }

    private var passage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.text)
                .font(.system(.body, design: .serif))
                .lineSpacing(4)
                .textSelection(.enabled)
            if let jid = node.journalID, let j = store.journal(jid), !j.deleted {
                NavigationLink {
                    JournalDetailView(journalID: jid)
                } label: {
                    Text("From “\(j.displayTitle)”, \(j.createdAt.dayLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) { book.remove(node.id) } label: {
                Label("Remove from book", systemImage: "minus.circle")
            }
        }
    }
}
