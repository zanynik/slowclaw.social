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
    'private func rebuildInterestLens('
]]
(target / 'Sources/Runtime/ReadingRegression.swift').write_text('''import Foundation
@MainActor final class ReadingRegression {
    var readsItems: [RankedFeedItem] = []
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
