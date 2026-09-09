import SwiftUI

struct QuestionThreadsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List {
            Section {
                Text("Follow a question from any memory or reflection. Keep what changes your thinking alongside its original journal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(QuestionThread.Status.allCases, id: \.self) { status in
                let threads = state.visibleQuestionThreads.filter { $0.status == status }
                if !threads.isEmpty {
                    Section(status.rawValue.capitalized) {
                        ForEach(threads) { thread in
                            NavigationLink { QuestionThreadView(threadID: thread.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(thread.question)
                                    Text(thread.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if state.visibleQuestionThreads.isEmpty {
                Text("Nothing followed yet. Open a memory and choose Follow this question.")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("Questions")
    }
}

struct QuestionThreadView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let threadID: String
    @State private var question = ""
    @State private var note = ""
    @State private var status: QuestionThread.Status = .active
    @State private var related: [ContextDocument] = []
    @State private var evidence: [EvidenceArticle] = []
    @State private var error: String?
    @State private var source: SlowClawMemoryEntry?
    @State private var web: WebLink?
    private var thread: QuestionThread? { state.visibleQuestionThreads.first { $0.id == threadID } }
    var body: some View {
        List {
            if let thread {
                Section("Question") {
                    TextField("What are you exploring?", text: $question, axis: .vertical)
                    Picker("Status", selection: $status) {
                        ForEach(QuestionThread.Status.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("What has changed? Add your own observation…", text: $note, axis: .vertical)
                    Button("Save changes") {
                        do { try state.updateQuestion(thread.id, question: question, note: note, status: status); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 || question.count > 240 || note.count > 2000)
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    Text("Paused and resolved questions stay here, but leave your daily selection.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Kept experiences") {
                    ForEach(thread.sourceKeys.compactMap { state.contextDocument($0) }) { doc in
                        NavigationLink { ContextExplorer(journalKey: doc.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(doc.text).lineLimit(4)
                                Text(doc.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Possible connections") {
                    Text("Matches suggest a connection; they do not establish an answer.").font(.caption).foregroundStyle(.secondary)
                    ForEach(related.filter { !thread.sourceKeys.contains($0.id) }) { doc in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { source = state.memorySource(doc.id) } label: { Text(doc.text).lineLimit(4) }
                            Button("Keep with this question") {
                                do { try state.linkQuestion(thread.id, sourceKey: doc.id) }
                                catch { self.error = error.localizedDescription }
                            }.font(.caption)
                        }
                    }
                    if related.isEmpty { Text("No close matches in indexed journals yet.").foregroundStyle(.secondary) }
                }
                Section("Reading to explore") {
                    ForEach(evidence) { article in
                        Button {
                            state.beginEvidenceReading(article)
                            web = WebLink(url: article.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(article.title)
                                Text(article.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if evidence.isEmpty { Text("No matching cached reading yet.").foregroundStyle(.secondary) }
                }
                Section {
                    Button("Remove question", role: .destructive) {
                        do { try state.removeQuestion(thread.id); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } else { Text("This question's sources are unavailable or excluded.") }
        }
        .navigationTitle("Following a question")
        .onAppear { if let thread { question = thread.question; note = thread.note; status = thread.status } }
        .task(id: (thread?.question ?? "") + state.contextRevision + String(state.readsItems.count)) {
            related = []; evidence = []
            guard let thread else { return }
            let matches = await state.searchPersonalContext(thread.question)
            guard !Task.isCancelled else { return }
            related = matches
            let articles = await state.findLocalEvidence(thread.question)
            guard !Task.isCancelled else { return }
            evidence = articles
        }
        .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
        .sheet(item: $web, onDismiss: { state.finishReading() }) { link in
            InAppBrowserView(url: link.url) { web = nil }
        }
    }
}

struct FollowQuestionButton: View {
    let sourceKey: String
    let suggestion: String
    @State private var showing = false
    var body: some View {
        Button("Follow this question") { showing = true }
            .sheet(isPresented: $showing) { FollowQuestionSheet(sourceKey: sourceKey, suggestion: suggestion) }
    }
}

private struct FollowQuestionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let sourceKey: String
    let suggestion: String
    @State private var question = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Something to explore over time") {
                    TextField("Your question", text: $question, axis: .vertical)
                    Text("Edit this in your own words. The original journal stays linked.").font(.caption).foregroundStyle(.secondary)
                    Button("Follow question") {
                        do { try state.followQuestion(question, sourceKey: sourceKey); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!(5...240).contains(question.trimmingCharacters(in: .whitespacesAndNewlines).count))
                }
                let active = state.visibleQuestionThreads.filter { $0.status == .active }
                if !active.isEmpty {
                    Section("Or keep with an existing question") {
                        ForEach(active) { thread in
                            Button(thread.question) {
                                do { try state.linkQuestion(thread.id, sourceKey: sourceKey); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Follow a question")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { question = suggestion }
        }
    }
}

struct DailySelectionCard: View {
    @EnvironmentObject var state: AppState
    @State private var showingQuestions = false
    var body: some View {
        if let selection = state.dailySelection, !selection.dismissed {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("A little for today").font(.headline)
                    Spacer()
                    Button { state.dismissDailySelection() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss today's selection")
                }
                if let thread = state.visibleQuestionThreads.first(where: { $0.id == selection.questionID && $0.status == .active }) {
                    Button { showingQuestions = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A question you're following").font(.caption).foregroundStyle(.secondary)
                            Text(thread.question).multilineTextAlignment(.leading)
                        }
                    }
                }
                let items = selection.readIDs.compactMap { id in
                    state.readsItems.first { $0.id == id && state.readingSignals[id]?.preference != -1 }
                }
                ForEach(items) { item in
                    FeedCard(item: item, interests: state.interests)
                }
                if items.isEmpty { Text("Nothing new to add today. Your reading is below.").font(.caption).foregroundStyle(.secondary) }
                Text("A few unread choices from your journal-ranked Reads, with different sources. Explore more below when you want.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .sheet(isPresented: $showingQuestions) {
                NavigationStack {
                    if let id = selection.questionID { QuestionThreadView(threadID: id) }
                }
            }
        }
    }
}
