import Foundation

/// Runs the capture pipeline: transcribe → clean up → organize into a space.
/// Everything happens on the phone; journals are saved first so nothing is lost.
@MainActor
final class Processor: ObservableObject {
    static let shared = Processor()

    @Published private(set) var activity: String?
    @Published private(set) var bulkProgress: (done: Int, total: Int)?
    @Published private(set) var summarizing: Set<String> = []

    private let store = Store.shared
    private var running = false
    private var bulkTask: Task<Void, Never>?

    /// Journals created after this date are organized automatically.
    /// Older (imported) journals are organized from the Spaces tab on request.
    private var autoOrganizeSince: Date {
        let key = "slowclaw.auto-organize-since"
        if let v = UserDefaults.standard.object(forKey: key) as? Double { return Date(timeIntervalSince1970: v) }
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
        return now
    }

    var autoOrganize: Bool {
        get { UserDefaults.standard.object(forKey: "slowclaw.auto-organize") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "slowclaw.auto-organize"); objectWillChange.send() }
    }

    func start() {
        _ = autoOrganizeSince
        kick()
    }

    // MARK: - Capture entry points

    /// Called when a recording stops. Saves immediately, then processes.
    func saveRecording(title: String, transcript: String, audioURL: URL?) {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = audioURL.flatMap { AudioRecorder.documentsRelativePath(for: $0) }
        guard !raw.isEmpty || path != nil else { return }
        store.addJournal(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                         body: raw, transcript: raw.isEmpty ? nil : raw, audioPath: path,
                         status: raw.isEmpty ? .transcribing : .cleaning)
        store.saveNow()
        kick()
    }

    /// Adds a new recording to an existing entry, so one topic stays in one place.
    /// The audio is kept with the entry; the words are transcribed, cleaned and appended.
    func appendRecording(to id: String, transcript: String, audioURL: URL?) {
        let path = audioURL.flatMap { AudioRecorder.documentsRelativePath(for: $0) }
        if let path { store.updateJournal(id) { $0.moreAudio = ($0.moreAudio ?? []) + [path] } }
        let live = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveNow()
        Task {
            var raw = live
            if raw.isEmpty, let audioURL {
                activity = "Transcribing…"
                raw = await Task.detached(priority: .userInitiated) { await Transcriber.transcribe(url: audioURL) }.value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !raw.isEmpty else { activity = nil; return }
            activity = "Cleaning up transcript…"
            let cleaned = await OnDeviceAI.cleanTranscript(raw)
            let stamp = Date().formatted(date: .abbreviated, time: .shortened)
            store.updateJournal(id) {
                $0.body += "\n\n— Continued \(stamp) —\n\n" + cleaned
                $0.transcript = ($0.transcript ?? "") + "\n\n" + raw
            }
            // New words may hold new to-dos and new passages for the book.
            BookStore.shared.reread(id)
            await organize(id)
            activity = nil
            kick()
        }
    }

    func saveText(title: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !title.isEmpty else { return }
        store.addJournal(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: text)
        kick()
    }

    // MARK: - Pipeline

    func kick() {
        guard !running else { return }
        running = true
        Task {
            await drain()
            running = false
        }
    }

    private func drain() async {
        while true {
            if let j = store.visibleJournals.last(where: { $0.status == .transcribing }) {
                await transcribe(j)
            } else if let j = store.visibleJournals.last(where: { $0.status == .cleaning }) {
                await clean(j)
            } else if autoOrganize,
                      let j = store.visibleJournals.last(where: { $0.status == .ready && !$0.organized && $0.createdAt >= autoOrganizeSince && $0.spaceID == nil }) {
                await organize(j.id)
            } else if let j = store.visibleJournals.last(where: { BookStore.shared.needsReading($0) }) {
                // Oldest first, so the book grows in the order life happened.
                activity = "Reading into your book…"
                await BookStore.shared.read(j)
            } else if BookStore.shared.needsPolish {
                activity = "Writing chapter titles…"
                let store = self.store
                await BookStore.shared.polish {
                    // Hand back as soon as a recording needs work.
                    store.visibleJournals.contains { $0.status != .ready }
                }
                if BookStore.shared.needsPolish { continue }
            } else {
                break
            }
        }
        activity = nil
    }

    private func transcribe(_ j: Journal) async {
        activity = "Transcribing…"
        guard let path = j.audioPath, let url = AudioRecorder.absoluteURL(forMediaRelativePath: path),
              FileManager.default.fileExists(atPath: url.path) else {
            store.updateJournal(j.id) { $0.status = .ready; if $0.body.isEmpty { $0.body = "(Audio could not be found.)" } }
            return
        }
        let text = await Task.detached(priority: .userInitiated) {
            await Transcriber.transcribe(url: url)
        }.value
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            store.updateJournal(j.id) {
                $0.status = .ready
                $0.body = "(No speech was recognized. The audio is still saved on this phone.)"
                $0.organized = true
            }
        } else {
            store.updateJournal(j.id) { $0.transcript = raw; $0.body = raw; $0.status = .cleaning }
        }
    }

    private func clean(_ j: Journal) async {
        activity = "Cleaning up transcript…"
        let source = j.transcript ?? j.body
        let cleaned = await OnDeviceAI.cleanTranscript(source)
        store.updateJournal(j.id) {
            // Respect edits the user made while cleanup was running.
            if $0.body == source || $0.body.isEmpty { $0.body = cleaned }
            $0.status = .ready
        }
    }

    /// Assigns the journal to a space and extracts items. Safe to call repeatedly.
    func organize(_ id: String) async {
        guard let j = store.journal(id), j.status == .ready, !j.deleted else { return }
        activity = "Organizing…"
        let names = store.visibleSpaces.map(\.name)
        let recent = Date().timeIntervalSince(j.createdAt) < 14 * 86_400
        let result = await OnDeviceAI.organize(title: j.title, body: j.body, spaceNames: names, includeTodos: recent)

        var spaceID = j.spaceID
        if spaceID == nil, let name = result.space?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            // Keep the list of spaces small: only allow new ones while there are few.
            if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) || names.count < 12 {
                spaceID = store.spaceNamed(name).id
            }
        }
        store.updateJournal(id) {
            $0.organized = true
            if $0.spaceID == nil { $0.spaceID = spaceID }
            if $0.title.trimmingCharacters(in: .whitespaces).isEmpty, !result.title.isEmpty {
                $0.title = String(result.title.prefix(80))
            }
        }
        if let target = store.journal(id)?.spaceID {
            for (kind, text) in result.items {
                store.addItem(spaceID: target, kind: kind, text: text, journalID: id)
            }
        }
    }

    /// Organizes every unsorted journal, newest first. Cancellable.
    func organizeAllUnsorted() {
        guard bulkTask == nil else { return }
        let ids = store.unsortedJournals.map(\.id)
        guard !ids.isEmpty else { return }
        bulkProgress = (0, ids.count)
        bulkTask = Task {
            for (index, id) in ids.enumerated() {
                if Task.isCancelled { break }
                await organize(id)
                bulkProgress = (index + 1, ids.count)
            }
            bulkProgress = nil
            activity = nil
            bulkTask = nil
        }
    }

    func cancelBulk() {
        bulkTask?.cancel()
    }

    func reclean(_ id: String) async {
        guard let j = store.journal(id) else { return }
        let source = j.transcript ?? j.body
        activity = "Cleaning up transcript…"
        let cleaned = await OnDeviceAI.cleanTranscript(source)
        store.updateJournal(id) { $0.body = cleaned }
        activity = nil
    }

    func refreshSummary(spaceID: String) async {
        guard let space = store.space(spaceID), !summarizing.contains(spaceID) else { return }
        summarizing.insert(spaceID)
        defer { summarizing.remove(spaceID) }
        let journals = store.journals(in: spaceID)
        let todos = store.items(in: spaceID).filter { $0.kind == .todo && !$0.done }.map(\.text)
        if let text = await OnDeviceAI.summarize(spaceName: space.name, journals: journals, openTodos: todos) {
            store.updateSpace(spaceID) { $0.summary = text }
        }
    }
}
