import Foundation

// Book v2 rules, free of storage and frameworks (tested in BookOrganizerTests; prototyped on
// real journals first). The book reads as a book because it is organised as a whole:
//
//   • Passages are the author's own words, lightly edited (see `voiceKept`).
//   • Repeats are dropped twice over: whole journals that repeat another (the same audio
//     imported twice), and passages that say the same as one already in the book.
//   • A passage joins when it relates to the book or to other waiting passages; one that
//     relates to nothing yet waits until enough related passages arrive to start a theme.
//   • Passages are grouped into themes (chapters, about √(n/2) of them), chapters follow each
//     other by closeness, and inside a chapter the order follows the thread while moving
//     forward in time, so a chapter reads as a thought developing.

struct OrgPassage {
    var vector: [Float]
    var day: Int          // yyyymmdd of the journal it came from
    var journal: String
    var seq: Int          // order within its journal
}

enum BookOrganizer {
    // MARK: - Repeats

    static func shingles(_ text: String, size: Int) -> Set<Int> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard words.count >= size else { return words.isEmpty ? [] : [words.joined(separator: " ").hashValue] }
        var out = Set<Int>()
        out.reserveCapacity(words.count)
        for i in 0...(words.count - size) { out.insert(words[i..<(i + size)].joined(separator: " ").hashValue) }
        return out
    }

    /// Share of the smaller text's word runs that also appear in the other one.
    static func containment(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        let small = min(a.count, b.count)
        guard small > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(small)
    }

    /// The same recording imported twice shares ~75% of its 3-word runs; different
    /// journals share under 10%.
    static func isRepeatJournal(_ body: String, of other: String) -> Bool {
        containment(shingles(body, size: 3), shingles(other, size: 3)) >= 0.5
    }

    static func isRepeatPassage(_ text: String, vector: [Float], of other: String, otherVector: [Float],
                                duplicateAt: Float = 0.92) -> Bool {
        BookEngine.similarity(vector, otherVector) >= duplicateAt
            || containment(shingles(text, size: 4), shingles(other, size: 4)) >= 0.35
    }

    // MARK: - Voice

    /// Share of the edited passage's content words that the author actually said. Edits that
    /// keep less than ~85% have started paraphrasing and are replaced by the original.
    static func voiceKept(edited: String, source: String) -> Double {
        let out = BookEngine.contentWords(edited)
        guard !out.isEmpty else { return 0 }
        return Double(out.intersection(BookEngine.contentWords(source)).count) / Double(out.count)
    }

    private static let filler = try! NSRegularExpression(
        pattern: #"\b(?:uh+|um+|hmm+|mm-?hmm|yeah|okay|you know|i mean|i guess|kind of|sort of|basically|actually)\b[,.]?\s*"#,
        options: [.caseInsensitive])

    /// Light cleanup that keeps the author's words: fillers, stutters and stray spaces only.
    static func lightClean(_ s: String) -> String {
        var t = filler.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        t = t.replacingOccurrences(of: #"\b(\w+)(\s+\1\b)+"#, with: "$1", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([,.!?])[,.]+"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,.").union(.whitespacesAndNewlines))
        guard let first = t.first else { return t }
        t = first.uppercased() + t.dropFirst()
        if let last = t.last, last.isLetter || last.isNumber { t += "." }
        return t
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) } }
        }
        return out
    }

    private static let dangling = try! NSRegularExpression(
        pattern: #"^(?:and|but|so|or|because|that|this|these|those|it|which|then|also|to|of|for|with|as|anyway)\b"#,
        options: [.caseInsensitive])
    private static let reflective = try! NSRegularExpression(
        pattern: #"\bI (?:think|feel|felt|believe|reali[sz]e|wonder|learn|understand|see|want|hope)|\bthe (?:point|idea)\b|\bimportant\b|\bmeaning\b"#,
        options: [.caseInsensitive])

    /// Without Apple Intelligence: windows of 3–5 cleaned sentences that start where a
    /// thought starts, scored by idea density; the best non-overlapping ones, up to one per
    /// ~1,800 characters of journal (max 8).
    static func extractPassages(_ body: String) -> [String] {
        let sents = sentences(body).map(lightClean).filter { BookEngine.wordCount($0) >= 4 }
        guard !sents.isEmpty else { return [] }
        let budget = max(1, min(8, body.count / 1800 + 1))
        var candidates: [(score: Double, start: Int, end: Int, text: String)] = []
        for i in sents.indices {
            let first = sents[i]
            if dangling.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil { continue }
            for n in 3...5 where i + n <= sents.count {
                let chunk = sents[i..<(i + n)].joined(separator: " ")
                let wc = BookEngine.wordCount(chunk)
                guard (35...130).contains(wc) else { continue }
                let cues = reflective.numberOfMatches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk))
                let score = Double(BookEngine.contentWords(chunk).count) / Double(wc) + 0.08 * Double(cues)
                candidates.append((score, i, i + n, chunk))
            }
        }
        candidates.sort { $0.score > $1.score }
        var taken: [(Int, Int)] = []
        var chosen: [(Int, String)] = []
        for c in candidates where chosen.count < budget {
            if taken.contains(where: { !(c.end <= $0.0 || c.start >= $0.1) }) { continue }
            taken.append((c.start, c.end))
            chosen.append((c.start, c.text))
        }
        return chosen.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Joining

    enum Admission: Equatable { case join, wait(String), drop(String) }

    /// `book` holds the vectors of passages already in the book (any order).
    static func admit(vector: [Float], text: String, bookVectors: [[Float]], bookTexts: [String],
                      waitingVectors: [[Float]], seedCount: Int = 8) -> Admission {
        guard BookEngine.wordCount(text) >= 12 else { return .drop("Too short to stand on its own.") }
        var sims: [(Float, Int)] = []
        for (i, v) in bookVectors.enumerated() { sims.append((BookEngine.similarity(vector, v), i)) }
        sims.sort { $0.0 > $1.0 }
        if let best = sims.first, isRepeatPassage(text, vector: vector, of: bookTexts[best.1], otherVector: bookVectors[best.1]) {
            return .drop("Says nearly the same as a passage already in the book.")
        }
        for (_, i) in sims.prefix(5) where containment(shingles(text, size: 4), shingles(bookTexts[i], size: 4)) >= 0.35 {
            return .drop("Says nearly the same as a passage already in the book.")
        }
        let near = sims.prefix(3).map { bookTexts[$0.1] }
        if !near.isEmpty, BookEngine.newInformation(text, comparedTo: near) < 0.30 {
            return .drop("Adds too little that the book does not already say.")
        }
        guard bookVectors.count >= seedCount, let best = sims.first?.0 else { return .join }
        // Relates to the book as closely as its passages usually relate to each other?
        let usual = nearestNeighbourPercentile(bookVectors, percentile: 0.10)
        if best >= usual { return .join }
        // Otherwise it can still start a new theme with two waiting passages it relates to.
        let friends = waitingVectors.filter { BookEngine.similarity(vector, $0) >= usual }.count
        return friends >= 2 ? .join : .wait("Not connected to the book's themes yet. It joins when related passages arrive.")
    }

    /// The given percentile of each passage's similarity to its nearest neighbour.
    static func nearestNeighbourPercentile(_ vectors: [[Float]], percentile: Double) -> Float {
        guard vectors.count >= 2 else { return -1 }
        var best: [Float] = []
        for (i, a) in vectors.enumerated() {
            var m: Float = -1
            for (j, b) in vectors.enumerated() where i != j { m = max(m, BookEngine.similarity(a, b)) }
            best.append(m)
        }
        best.sort()
        return best[min(best.count - 1, Int(Double(best.count) * percentile))]
    }

    // MARK: - Organising

    /// Chapters as lists of passage indices, in reading order.
    static func organize(_ passages: [OrgPassage]) -> [[Int]] {
        let n = passages.count
        guard n > 0 else { return [] }
        if n < 4 { return [Array(0..<n).sorted { before(passages[$0], passages[$1]) }] }

        var sim = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in i..<n { let s = BookEngine.similarity(passages[i].vector, passages[j].vector); sim[i][j] = s; sim[j][i] = s } }

        // Average-linkage clustering with Lance–Williams updates, down to about √(n/2) themes:
        // about 9 chapters of ~17 passages for a book of 150.
        let target = max(2, min(14, Int((Double(n) / 2).squareRoot().rounded())))
        var members: [[Int]] = (0..<n).map { [$0] }
        var link = sim
        var alive = Set(0..<n)
        while alive.count > target {
            var best: Float = -.infinity, pair = (0, 0)
            let ids = alive.sorted()
            for (k, a) in ids.enumerated() { for b in ids[(k + 1)...] where link[a][b] > best { best = link[a][b]; pair = (a, b) } }
            let (a, b) = pair
            let na = Float(members[a].count), nb = Float(members[b].count)
            for c in alive where c != a && c != b {
                let v = (na * link[a][c] + nb * link[b][c]) / (na + nb)
                link[a][c] = v; link[c][a] = v
            }
            members[a] += members[b]
            members[b] = []
            alive.remove(b)
        }
        // Fold themes of one or two passages into their closest theme.
        var themes = alive.map { members[$0] }.filter { !$0.isEmpty }
        let small = themes.filter { $0.count < 3 }
        themes = themes.filter { $0.count >= 3 }
        if themes.isEmpty { themes = [Array(0..<n)] } else {
            for group in small { for i in group {
                let k = themes.indices.max { avg(i, themes[$0], sim) < avg(i, themes[$1], sim) }!
                themes[k].append(i)
            } }
        }

        // Chapter order: the theme that began earliest first, then the closest remaining theme.
        func centroidSim(_ x: [Int], _ y: [Int]) -> Float {
            var t: Float = 0
            for i in x { for j in y { t += sim[i][j] } }
            return t / Float(x.count * y.count)
        }
        var order = [themes.indices.min { earliest(themes[$0], passages) < earliest(themes[$1], passages) }!]
        var left = Set(themes.indices).subtracting(order)
        while !left.isEmpty {
            let next = left.max { centroidSim(themes[order.last!], themes[$0]) < centroidSim(themes[order.last!], themes[$1]) }!
            order.append(next)
            left.remove(next)
        }
        return order.map { thread(themes[$0], passages, sim) }
    }

    private static func avg(_ i: Int, _ group: [Int], _ sim: [[Float]]) -> Float {
        group.reduce(0) { $0 + sim[i][$1] } / Float(max(1, group.count))
    }

    private static func before(_ a: OrgPassage, _ b: OrgPassage) -> Bool {
        a.day == b.day ? (a.journal == b.journal ? a.seq < b.seq : a.journal < b.journal) : a.day < b.day
    }

    private static func earliest(_ group: [Int], _ p: [OrgPassage]) -> Int { group.map { p[$0].day }.min() ?? 0 }

    /// Follows the thread from the earliest passage: next is the most similar remaining one,
    /// with a penalty for going back in time and for reading a journal backwards.
    static func thread(_ group: [Int], _ p: [OrgPassage], _ sim: [[Float]], timeWeight: Float = 0.15) -> [Int] {
        let sorted = group.sorted { before(p[$0], p[$1]) }
        guard var current = sorted.first else { return [] }
        let days = sorted.map { dayNumber(p[$0].day) }
        let span = Float(max(1, (days.max() ?? 0) - (days.min() ?? 0)))
        let score: (Int, Int) -> Float = { from, to in
            var s = sim[from][to]
            let back = dayNumber(p[from].day) - dayNumber(p[to].day)
            if back > 0 { s -= timeWeight * Float(back) / span }
            if p[from].journal == p[to].journal && p[to].seq < p[from].seq { s -= 0.5 }
            return s
        }
        var out = [current]
        var left = Set(sorted.dropFirst())
        while !left.isEmpty {
            let from = current
            let next = left.max { score(from, $0) < score(from, $1) }!
            out.append(next)
            left.remove(next)
            current = next
        }
        return out
    }

    /// yyyymmdd → days since 2000, so gaps across month ends count correctly.
    static func dayNumber(_ yyyymmdd: Int) -> Int {
        var c = DateComponents()
        c.year = yyyymmdd / 10000; c.month = (yyyymmdd / 100) % 100; c.day = yyyymmdd % 100
        guard let d = Calendar(identifier: .gregorian).date(from: c) else { return 0 }
        return Int(d.timeIntervalSince1970 / 86_400)
    }

    /// Where the reader would feel a jump: neighbours in a chapter less similar than the
    /// chapter usually is. At most a third of the gaps get a connecting line.
    static func bridgeGaps(_ chapter: [Int], vectors: [[Float]]) -> [Int] {
        guard chapter.count >= 3 else { return [] }
        let gaps = (1..<chapter.count).map { ($0, BookEngine.similarity(vectors[chapter[$0 - 1]], vectors[chapter[$0]])) }
        let sorted = gaps.map(\.1).sorted()
        let median = sorted[sorted.count / 2]
        return gaps.filter { $0.1 < median }.sorted { $0.1 < $1.1 }
            .prefix(max(1, gaps.count / 3)).map(\.0).sorted()
    }

    /// Reuses a cached chapter title when the chapter still has most of the same passages.
    static func reuseTitle(for ids: Set<String>, cache: [(ids: Set<String>, title: String)]) -> String? {
        cache.first { old in
            let union = old.ids.union(ids).count
            return union > 0 && Double(old.ids.intersection(ids).count) / Double(union) >= 0.6
        }?.title
    }
}
