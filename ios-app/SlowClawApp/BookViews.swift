import SwiftUI

struct BookView: View {
    @EnvironmentObject private var book: BookStore
    @EnvironmentObject private var store: Store
    @State private var openChapter: Int?
    @State private var openNode: String?
    @State private var reading = false
    @State private var confirmRebuild = false

    var body: some View {
        NavigationStack {
            List {
                let chapters = book.chapters
                if chapters.isEmpty {
                    ContentUnavailableView("Your book is empty",
                                           systemImage: "book",
                                           description: Text("As you journal, the passages worth keeping join a living book in your own words. Each one has to connect to what is already there and add something new."))
                } else {
                    Section {
                        BookMapView(nodes: book.passages) { id in
                            openNode = id
                            openChapter = nil
                            reading = true
                        }
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                    } header: {
                        Text("Map")
                    } footer: {
                        Text("Each dot is a passage, placed by meaning. The line is the reading path. Tap a dot to read from there.")
                    }

                    Section("Contents") {
                        ForEach(chapters) { c in
                            Button {
                                openChapter = c.id
                                openNode = nil
                                reading = true
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(c.id + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                                    Circle().fill(BookPalette.color(c.id)).frame(width: 8, height: 8)
                                    Text(c.title.isEmpty ? "Chapter \(c.id + 1)" : c.title).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(c.passageCount)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        WaitingRoomView()
                    } label: {
                        LabeledContent("Waiting to fit", value: "\(book.waiting.count)")
                    }
                } footer: {
                    Text("Passages that don't connect to the book's themes yet wait here, and join once related passages arrive. Italic lines in the book are connecting lines written on this iPhone; everything else is in your own words.")
                }
            }
            .navigationTitle("Book")
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

/// The table of contents as a map: dots by meaning, the reading path as a line.
struct BookMapView: View {
    let nodes: [BookNode]
    var onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let points = nodes.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
            Canvas { ctx, _ in
                var line = Path()
                for (i, p) in points.enumerated() {
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                ctx.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                for (n, p) in zip(nodes, points) {
                    let r: CGFloat = 5
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(BookPalette.color(n.chapter)))
                }
                if let first = points.first {
                    ctx.draw(Text("start").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: first.x, y: first.y - 12))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let nearest = zip(nodes, points).min {
                    hypot($0.1.x - tap.location.x, $0.1.y - tap.location.y) < hypot($1.1.x - tap.location.x, $1.1.y - tap.location.y)
                }
                if let nearest, hypot(nearest.1.x - tap.location.x, nearest.1.y - tap.location.y) < 32 {
                    onSelect(nearest.0.id)
                }
            })
            .accessibilityElement()
            .accessibilityLabel("Map of \(nodes.count) passages")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
    }
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
                            Text("Chapter \(c.id + 1)").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
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

struct WaitingRoomView: View {
    @EnvironmentObject private var book: BookStore

    var body: some View {
        List {
            if book.waiting.isEmpty {
                Text("Nothing is waiting.").foregroundStyle(.secondary)
            }
            ForEach(book.waiting.sorted { $0.createdAt > $1.createdAt }) { c in
                VStack(alignment: .leading, spacing: 8) {
                    Text(c.text).font(.system(.callout, design: .serif))
                    Text(c.reason).font(.caption).foregroundStyle(.orange)
                    HStack {
                        Button("Add to book anyway") { book.addAnyway(c.id) }
                        Spacer()
                        Button("Dismiss", role: .destructive) { book.dismiss(c.id) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Waiting to fit")
    }
}
