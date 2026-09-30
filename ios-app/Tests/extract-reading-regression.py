"""Exercise the actual AppState reading methods without booting the Zig app."""
from pathlib import Path
import sys
app, target = map(Path, sys.argv[1:])
source = (app / 'SlowClawApp/SlowClawApp.swift').read_text()
def member(signature):
    start = source.index('    ' + signature)
    return source[start:source.index('\n    }', start) + 6]
methods = [member(x) for x in [
    'var relevantReads:', 'private var relevantFeedItems:',
    'private static func readsDecisionText(', 'func rememberArticle(',
    'func clearReadingHistory(', 'private func recordReadingProgress(',
    'private func rebuildInterestLens(', 'private func mergeReads(',
    'private func restoreCachedReadsDecisions(', 'func loadReads('
]]
(target / 'Sources/Runtime/ReadingRegression.swift').write_text('''import Foundation
@MainActor final class ReadingRegression {
    var readsItems: [RankedFeedItem] = []
    var readsRefreshTask: Task<Void, Never>?
    static let readsCacheMaxAge: TimeInterval = 1800
    var personaWeights = [Double](repeating: 0, count: JevPersona.topics.count)
    var batchRelevanceCache = JevBatch.Cache()
    var jevReadSources: [String: String] = [:]
    var fetchCount = 0
    var fetchCompleted = false
    func fetchReads(force: Bool) async {
        fetchCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        fetchCompleted = !Task.isCancelled
    }
    func refreshReadsDecisions() async {}
    func startJevFeedSelection() {}
    func merge(_ incoming: [RankedFeedItem]) { mergeReads(incoming) }
    func cacheApproval(_ item: RankedFeedItem) {
        personaWeights[0] = 1
        let profile = JevBatch.profileID(JevBatch.profile(personaWeights))
        batchRelevanceCache = .init(profile: profile)
        batchRelevanceCache.entries[JevBatch.digest(Self.readsDecisionText(item))] = .init(score: 0.95, date: Date())
    }
    var readingSignals: [String: ReadingSignal] = [:]
    var readingVisits: [String: ReadingVisit] = [:]
    var readsDecisions: [String: ReadsRelevance.Decision] = [:]
    var memoryRevision = 1
    var jevEnabled = true, readsModelEnabled = false, kevStrongMatchesOnly = false
    var kevReadDetails: [String: Int] = [:], kevJournalSelections: [String: Int] = [:], semanticMatches: [String: Int] = [:]
    var interests: [String] = [], interestWeights: [String: Double] = [:]
    var readsRefreshedAt: Date?, readingStarted: Date?, readingHistoryError: String?
    var readingCandidate: RankedFeedItem?
    var readingSeconds: TimeInterval = 0, readingRecordedSeconds: TimeInterval = 0
    func approve(_ items: [RankedFeedItem]) {
        readsItems = items
        for item in items { readsDecisions[item.id] = .init(text: Self.readsDecisionText(item), score: 0.95, revision: memoryRevision) }
    }
    func record(_ item: RankedFeedItem, seconds: TimeInterval) {
        readingCandidate = item; readingSeconds = seconds; readingRecordedSeconds = 0
        recordReadingProgress()
    }
''' + '\n'.join(methods) + '\n}\nextension String { func strippingHTML() -> String { self } }\n')

(target / 'Sources/Runtime/CreateRefreshRegression.swift').write_text("""import Foundation
@MainActor final class CreateRefreshRegression {
    var createTask: Task<Void, Never>?
    var createBusy = false
    var scanCount = 0
    var scanCompleted = false
    func findCreateIdeas() async {
        scanCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        scanCompleted = !Task.isCancelled
    }
    func resumeJevWork() async {}
""" + member('func refreshCreateIdeas(') + '\n}\n')
