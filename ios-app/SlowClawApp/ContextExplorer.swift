import SwiftUI

/// One quiet drill-down from a memory: original sources, relevant reading,
/// then an optional reflection. Tool execution is bounded by the app.
struct ContextExplorer: View {
    @EnvironmentObject var state: AppState
    let journalKey: String
    @State private var related: [ContextDocument] = []
    @State private var evidence: [EvidenceArticle] = []
    @State private var selectedEvidence: String?
    @State private var query = ""
    @State private var reflection: GroundedReflection?
    @State private var reflectionDocuments: [ContextDocument] = []
    @State private var reflectionEvidence: EvidenceArticle?
    @State private var status: String?
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var source: SlowClawMemoryEntry?
    @State private var web: WebLink?

    private var current: ContextDocument? { state.contextDocument(journalKey) }

    var body: some View {
        List {
            if let current {
                Section("Your words") {
                    Text(current.title).font(.headline)
                    Text(current.text).textSelection(.enabled)
                    Button("Open journal") { source = state.memorySource(journalKey) }
                }
                Section("Connected experiences") {
                    if related.isEmpty { Text("No close matches found in your indexed journals.").foregroundStyle(.secondary) }
                    ForEach(related) { document in
                        Button { source = state.memorySource(document.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).foregroundStyle(.primary)
                                Text(document.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                Text(document.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Reading to explore") {
                    Text("Related by meaning or words, not evidence of agreement. These are excerpts; open the source before drawing conclusions.")
                        .font(.caption).foregroundStyle(.secondary)
                    if evidence.isEmpty { Text("No relevant cached reading yet. You can search a public topic below.").foregroundStyle(.secondary) }
                    ForEach(evidence) { article in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                state.beginEvidenceReading(article)
                                web = WebLink(url: article.url)
                            } label: { Text(article.title).multilineTextAlignment(.leading) }
                            Text(article.source).font(.caption).foregroundStyle(.secondary)
                            Text(article.excerpt).lineLimit(4).font(.callout).foregroundStyle(.secondary)
                            Button(selectedEvidence == article.id ? "Included in reflection ✓" : "Include in reflection") {
                                selectedEvidence = selectedEvidence == article.id ? nil : article.id
                                reflection = nil
                            }.font(.caption).disabled(busy)
                        }.padding(.vertical, 4)
                    }
                    DisclosureGroup("Search beyond Reads") {
                        TextField("Public topic, e.g. community gardens", text: $query)
                            .textInputAutocapitalization(.never)
                        Text("Only the query you enter is sent to English Wikipedia. Keep names and private details out. Results are background reading, not a fact-check.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Search Wikipedia") { search() }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    }
                }
                Section("A question to sit with") {
                    if let reflection {
                        Text(reflection.observation)
                        Text(reflection.question).font(.headline)
                        FollowQuestionButton(sourceKey: journalKey, suggestion: reflection.question)
                        Text("A tentative AI reflection. Exact quotes are checked; its interpretation can still be wrong.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(reflection.citations, id: \.id) { citation in
                            DisclosureGroup("Source \(citation.id)") {
                                Text(citation.quote).font(.callout)
                                if citation.id.hasPrefix("J"), let i = Int(citation.id.dropFirst()), reflectionDocuments.indices.contains(i - 1) {
                                    Button("Open journal") { source = state.memorySource(reflectionDocuments[i - 1].id) }
                                } else if citation.id == "E1", let article = reflectionEvidence {
                                    Button("Open reading") { state.beginEvidenceReading(article); web = WebLink(url: article.url) }
                                }
                            }
                        }
                    }
                    Button(busy ? "Working…" : "Reflect with sources") { reflect(current) }
                        .disabled(busy || state.isGeneratingPosts || state.contextWorkPaused)
                    if busy { Button("Stop") { work?.cancel() } }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("This memory was changed or excluded. Return to your journals to explore its current source.")
            }
        }
        .navigationTitle("Explore")
        .task(id: state.contextRevision) {
            work?.cancel(); reflection = nil; related = []; evidence = []; selectedEvidence = nil
            guard let current else { return }
            related = await state.searchPersonalContext(current.title, excluding: journalKey)
            guard !Task.isCancelled else { return }
            evidence = await state.findLocalEvidence(current.title)
        }
        .onDisappear { work?.cancel() }
        .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
        .sheet(item: $web, onDismiss: { state.finishReading() }) { link in
            InAppBrowserView(url: link.url) { web = nil }
        }
    }

    private func search() {
        work?.cancel(); busy = true; status = "Searching public background reading…"
        let topic = query
        work = Task {
            defer { busy = false }
            do {
                let found = try await EvidenceSearch.search(query: topic)
                    .filter { ReadsContentFilter.isAllowed($0.title, $0.excerpt) }
                try Task.checkCancellation()
                let existing = Set(evidence.map(\.id))
                evidence = Array((evidence + found.filter { !existing.contains($0.id) }).suffix(10))
                status = found.isEmpty ? "No results. Try a broader public topic." : "Wikipedia introductions added below your local suggestions."
            } catch is CancellationError { status = "Stopped." }
            catch { status = error.localizedDescription }
        }
    }

    private func reflect(_ current: ContextDocument) {
        work?.cancel(); busy = true; reflection = nil; status = "Reading the selected passages on this device…"
        let documents = [current] + Array(related.prefix(1))
        let article = evidence.first { $0.id == selectedEvidence }
        work = Task {
            defer { busy = false }
            do {
                let result = try await state.reflectOnContext(documents: documents, evidence: article)
                try Task.checkCancellation()
                reflectionDocuments = documents; reflectionEvidence = article
                reflection = result; status = nil
            } catch is CancellationError { status = "Stopped." }
            catch { status = error.localizedDescription }
        }
    }
}
