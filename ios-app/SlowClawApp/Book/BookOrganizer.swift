import Foundation

// The book's rules, ported from the Python prototypes that were tuned on real journals with the
// same MiniLM vectors (see docs/book.md). No language model is needed to build the book:
//
//   journal → sentences → topic segments (where meaning turns) → the most central 3–5
//   sentences of each substantial segment → drop repeats → one reading path through every
//   passage (neighbours alike, spoken continuations together) → cut into about √(n/2) chapters.

struct OrgPassage {
    var vector: [Float]
    var day: Int          // yyyymmdd of the journal it came from
    var journal: String
    var seq: Int          // order within its journal
}

enum BookOrganizer {
    // MARK: - Text

    static func shingles(_ text: String, size: Int) -> Set<Int> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard words.count >= size else { return words.isEmpty ? [] : [words.joined(separator: " ").hashValue] }
        var out = Set<Int>()
        for i in 0...(words.count - size) { out.insert(words[i..<(i + size)].joined(separator: " ").hashValue) }
        return out
    }

    static func containment(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        let small = min(a.count, b.count)
        guard small > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(small)
    }

    /// The same recording imported twice shares ~75% of its 3-word runs; different journals under 10%.
    static func isRepeatJournal(_ body: String, of other: String) -> Bool {
        containment(shingles(body, size: 3), shingles(other, size: 3)) >= 0.5
    }

    static func isRepeatPassage(_ text: String, vector: [Float], of other: String, otherVector: [Float]) -> Bool {
        BookEngine.similarity(vector, otherVector) >= 0.85
            || containment(shingles(text, size: 4), shingles(other, size: 4)) >= 0.35
    }

    /// Share of the edited passage's content words that the author actually said.
    static func voiceKept(edited: String, source: String) -> Double {
        let out = BookEngine.contentWords(edited)
        guard !out.isEmpty else { return 0 }
        return Double(out.intersection(BookEngine.contentWords(source)).count) / Double(out.count)
    }

    private static let filler = try! NSRegularExpression(
        pattern: #"\b(?:uh+|um+|hmm+|mm+-?hmm+|mhm|yeah|okay|ok|you know|i mean|i guess|kind of|sort of|basically|actually|like,)\b[,.]?\s*"#,
        options: [.caseInsensitive])

    /// Light cleanup that keeps the author's words: fillers, stutters and stray punctuation only.
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

    /// Cleaned sentences of a journal, ready to embed (very short ones dropped).
    static func bookSentences(_ body: String) -> [String] {
        sentences(body).map(lightClean).filter { BookEngine.wordCount($0) >= 4 }
    }

    /// Share of content words: low for small talk and logistics.
    static func substance(_ text: String) -> Double {
        let all = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).count
        guard all > 0 else { return 0 }
        let content = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .filter { $0.count > 2 && !BookEngine.isStopword(String($0)) }.count
        return Double(content) / Double(all)
    }

    private static let dangling = try! NSRegularExpression(
        pattern: #"^(?:and|but|so|or|because|that|this|these|those|it|which|then|also|to|of|for|with|as|anyway|he|she|they)\b"#,
        options: [.caseInsensitive])

    private static func startsMidThought(_ s: String) -> Bool {
        dangling.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: - Segments and passages

    private static func mean(_ vs: ArraySlice<[Float]>) -> [Float] {
        guard let first = vs.first else { return [] }
        var m = [Float](repeating: 0, count: first.count)
        for v in vs { for i in m.indices { m[i] += v[i] } }
        return BookEngine.normalized(m)
    }

    /// TextTiling with sentence vectors: cut where the next sentences turn away from the last ones.
    static func segments(_ vectors: [[Float]], window: Int = 3, minLength: Int = 4, maxLength: Int = 14) -> [Range<Int>] {
        let n = vectors.count
        guard n > minLength else { return [0..<n] }
        var gaps: [Float] = []
        for i in 1..<n {
            gaps.append(BookEngine.similarity(mean(vectors[max(0, i - window)..<i]), mean(vectors[i..<min(n, i + window)])))
        }
        var depth = [Float](repeating: 0, count: gaps.count)
        for i in gaps.indices {
            let l = gaps[max(0, i - 3)...i].max()!, r = gaps[i..<min(gaps.count, i + 4)].max()!
            depth[i] = (l - gaps[i]) + (r - gaps[i])
        }
        let avg = depth.reduce(0, +) / Float(depth.count)
        let sd = (depth.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Float(depth.count)).squareRoot()
        let cutAt = avg + 0.5 * sd
        var bounds: [Range<Int>] = []
        var start = 0
        // Cut only at the deepest point of each dip (local maxima of depth).
        for i in gaps.indices where depth[i] >= cutAt
            && (i == 0 || depth[i] >= depth[i - 1]) && (i == gaps.count - 1 || depth[i] >= depth[i + 1]) {
            let c = i + 1
            if c - start >= minLength && n - c >= 2 { bounds.append(start..<c); start = c }
        }
        bounds.append(start..<n)
        var out: [Range<Int>] = []
        for b in bounds {
            var a = b.lowerBound
            while b.upperBound - a > maxLength { out.append(a..<(a + maxLength / 2 + 3)); a += maxLength / 2 + 3 }
            out.append(a..<b.upperBound)
        }
        return out
    }

    /// The 3–5 sentence window closest to its segment's meaning, starting where a thought starts.
    static func centralPassage(_ sentences: [String], _ vectors: [[Float]], in range: Range<Int>) -> (text: String, start: Int)? {
        let centroid = mean(vectors[range])
        var best: (score: Double, text: String, start: Int)?
        for i in range where !startsMidThought(sentences[i]) {
            for n in 3...5 where i + n <= range.upperBound {
                let text = sentences[i..<(i + n)].joined(separator: " ")
                guard (30...120).contains(BookEngine.wordCount(text)) else { continue }
                let score = Double(BookEngine.similarity(mean(vectors[i..<(i + n)]), centroid)) + 0.6 * substance(text)
                if best == nil || score > best!.score { best = (score, text, i) }
            }
        }
        return best.map { ($0.text, $0.start) }
    }

    /// A journal's passages: the most substantial segments, about one per 1,500 characters (max 10).
    static func passages(sentences: [String], vectors: [[Float]], journalLength: Int) -> [(text: String, start: Int, range: Range<Int>)] {
        guard sentences.count >= 3 else { return [] }
        let budget = max(1, min(10, journalLength / 1500 + 1))
        var found: [(sub: Double, text: String, start: Int, range: Range<Int>)] = []
        for r in segments(vectors) {
            guard let p = centralPassage(sentences, vectors, in: r) else { continue }
            let s = substance(p.text)
            if s >= 0.33 { found.append((s, p.text, p.start, r)) }
        }
        return found.sorted { $0.sub > $1.sub }.prefix(budget).sorted { $0.start < $1.start }.map { ($0.text, $0.start, $0.range) }
    }

    // MARK: - Arrangement (v4): one reading path, then the best cuts
    //
    // Mirrors tools/prototype/arrange.py line by line (see docs/book.md for what was measured).
    // The book is one path through every passage that keeps neighbours as alike as possible and
    // keeps a thought next to the one spoken right after it; chapters are the best places to cut
    // that path. The path is found by local search and can be checked against a lower bound; the
    // cuts are exactly optimal for the path.

    /// What "this was said right after that" is worth, in similarity units.
    static let spokenBonus: Float = 0.15
    static let minChapter = 4

    /// A square matrix stored row by row.
    struct Matrix {
        let n: Int
        var values: [Float]
        init(n: Int) { self.n = n; values = [Float](repeating: 0, count: n * n) }
        subscript(a: Int, b: Int) -> Float {
            get { values[a * n + b] }
            set { values[a * n + b] = newValue }
        }
    }

    static func similarityMatrix(_ vectors: [[Float]]) -> Matrix {
        var m = Matrix(n: vectors.count)
        for a in vectors.indices {
            m[a, a] = 1
            for b in vectors.indices where b > a {
                let s = BookEngine.similarity(vectors[a], vectors[b])
                m[a, b] = s; m[b, a] = s
            }
        }
        return m
    }

    static func pathCost(_ order: [Int], _ cost: Matrix) -> Float {
        var total: Float = 0
        for (a, b) in zip(order, order.dropFirst()) { total += cost[a, b] }
        return total
    }

    /// Weight of the minimum spanning tree: no path through all points can be shorter.
    static func lowerBound(_ cost: Matrix) -> Float {
        let n = cost.n
        guard n >= 2 else { return 0 }
        var done = [Bool](repeating: false, count: n)
        var dist = (0..<n).map { cost[0, $0] }
        done[0] = true
        var total: Float = 0
        for _ in 1..<n {
            var j = -1
            for x in 0..<n where !done[x] && (j < 0 || dist[x] < dist[j]) { j = x }
            total += dist[j]; done[j] = true
            for x in 0..<n where !done[x] && cost[j, x] < dist[x] { dist[x] = cost[j, x] }
        }
        return total
    }

    /// Local search on a tour whose first stop is a dummy at distance 0 from everything (so the
    /// tour is really an open path). Reverses stretches (symmetric costs only) and relocates runs
    /// of one to three stops, until no move shortens it.
    private static func improve(_ start: [Int], _ x: Matrix, symmetric: Bool) -> [Int] {
        var o = start
        let count = o.count
        var improved = true
        while improved {
            improved = false
            if symmetric {
                for i in 0..<(count - 1) {
                    var j = i + 2
                    while j < count {
                        let a = o[i], b = o[i + 1], c = o[j], d = o[(j + 1) % count]
                        if x[a, c] + x[b, d] - x[a, b] - x[c, d] < -1e-5 {
                            o[(i + 1)...j].reverse()
                            improved = true
                        }
                        j += 1
                    }
                }
            }
            for length in 1...3 {
                var i = 1
                while i + length <= count {
                    let p = o[i - 1], s0 = o[i], s1 = o[i + length - 1], q = o[(i + length) % count]
                    let gain = x[p, s0] + x[s1, q] - x[p, q]
                    var best = gain - 1e-5
                    var at = -1
                    var flip = false
                    for k in 0..<count where k < i - 1 || k > i + length - 1 {
                        let a = o[k], b = o[(k + 1) % count]
                        let forward = x[a, s0] + x[s1, b] - x[a, b]
                        if forward < best { best = forward; at = k; flip = false }
                        if symmetric {
                            let backward = x[a, s1] + x[s0, b] - x[a, b]
                            if backward < best { best = backward; at = k; flip = true }
                        }
                    }
                    if at >= 0 {
                        var segment = Array(o[i..<(i + length)])
                        if flip { segment.reverse() }
                        let anchor = o[at]
                        o.removeSubrange(i..<(i + length))
                        let k = o.firstIndex(of: anchor) ?? 0
                        o.insert(contentsOf: segment, at: k + 1)
                        improved = true
                    } else {
                        i += 1
                    }
                }
            }
        }
        return o
    }

    /// `cost` with one more row and column of zeros: the dummy stop that opens the tour into a path.
    private static func withDummy(_ cost: Matrix) -> Matrix {
        let n = cost.n
        var x = Matrix(n: n + 1)
        for a in 0..<n { for b in 0..<n { x[a, b] = cost[a, b] } }
        return x
    }

    /// Order of all rows of the symmetric `cost` that makes neighbours as close as possible.
    static func shortestPath(_ cost: Matrix, starts: Int = 4) -> [Int] {
        let n = cost.n
        guard n > 2 else { return Array(0..<n) }
        let x = withDummy(cost)
        var best: [Int] = []
        var bestCost = Float.infinity
        let tries = min(starts, n)
        for t in 0..<tries {
            let s = t * (n - 1) / max(1, tries - 1)
            var o = [n, s]
            var left = Array(0..<n)
            left.remove(at: s)
            while !left.isEmpty {
                let last = o[o.count - 1]
                var pick = 0
                for k in left.indices where x[last, left[k]] < x[last, left[pick]] { pick = k }
                o.append(left.remove(at: pick))
            }
            o = improve(o, x, symmetric: true)
            let path = Array(o.dropFirst())
            let c = pathCost(path, cost)
            if c < bestCost - 1e-5 { best = path; bestCost = c }
        }
        return best
    }

    /// The same search for costs that depend on direction: runs are relocated, never reversed.
    static func directedRefine(_ order: [Int], _ cost: Matrix) -> [Int] {
        let n = cost.n
        guard n > 2, order.count == n else { return order }
        return Array(improve([n] + order, withDummy(cost), symmetric: false).dropFirst())
    }

    /// Exact best split of `order` into at most `k` chapters of `lo...hi` passages, cutting only
    /// before the positions in `allowed`. Maximises, summed over chapters, the pairwise similarity
    /// inside a chapter divided by its size (dynamic programming over prefix sums).
    static func cutChapters(_ order: [Int], _ sim: Matrix, k: Int, allowed: Set<Int>, lo: Int, hi: Int) -> [[Int]] {
        let m = order.count
        guard m > 0 else { return [] }
        let w = m + 1
        var p = [Double](repeating: 0, count: w * w)
        for a in 0..<m {
            var row = 0.0
            for b in 0..<m {
                row += Double(sim[order[a], order[b]])
                p[(a + 1) * w + b + 1] = p[a * w + b + 1] + row
            }
        }
        func score(_ a: Int, _ b: Int) -> Double {
            (p[b * w + b] - p[a * w + b] - p[b * w + a] + p[a * w + a]) / Double(b - a)
        }
        let points = [0] + (1..<m).filter { allowed.contains($0) } + [m]
        let none = -Double.infinity
        var best = [[Double]](repeating: [Double](repeating: none, count: points.count), count: k + 1)
        var arg = [[Int]](repeating: [Int](repeating: 0, count: points.count), count: k + 1)
        best[0][0] = 0
        if k >= 1 {
            for q in 1...k {
                for bi in 1..<points.count {
                    for ai in 0..<bi {
                        let size = points[bi] - points[ai]
                        guard size >= lo, size <= hi, best[q - 1][ai] > none else { continue }
                        let v = best[q - 1][ai] + score(points[ai], points[bi])
                        if v > best[q][bi] { best[q][bi] = v; arg[q][bi] = ai }
                    }
                }
            }
        }
        var q = k
        while q > 0 && best[q][points.count - 1] == none { q -= 1 }
        guard q > 0 else { return [order] }
        var out: [[Int]] = []
        var bi = points.count - 1
        while q > 0 {
            let ai = arg[q][bi]
            out.append(Array(order[points[ai]..<points[bi]]))
            bi = ai
            q -= 1
        }
        return out.reversed()
    }

    /// Pairs "a then b" (as `a * count + b`) where passage b was said right after passage a.
    static func spokenNext(_ passages: [OrgPassage]) -> Set<Int> {
        let n = passages.count
        var bySitting: [String: [Int]] = [:]
        for (i, p) in passages.enumerated() { bySitting[p.journal, default: []].append(i) }
        var pairs = Set<Int>()
        for ids in bySitting.values {
            let sorted = ids.sorted { passages[$0].seq == passages[$1].seq ? $0 < $1 : passages[$0].seq < passages[$1].seq }
            for (a, b) in zip(sorted, sorted.dropFirst()) { pairs.insert(a * n + b) }
        }
        return pairs
    }

    /// Chapters as lists of passage indices, in reading order.
    static func organize(_ passages: [OrgPassage]) -> [[Int]] {
        let n = passages.count
        guard n > 0 else { return [] }
        guard n >= 6 else {
            // Too few to arrange: one chapter, as it was lived.
            return [passages.indices.sorted { a, b in
                let pa = passages[a], pb = passages[b]
                return pa.day == pb.day ? (pa.journal == pb.journal ? pa.seq < pb.seq : pa.journal < pb.journal) : pa.day < pb.day
            }]
        }
        let sim = similarityMatrix(passages.map(\.vector))
        let next = spokenNext(passages)
        var symmetric = Matrix(n: n), directed = Matrix(n: n)
        for a in 0..<n {
            for b in 0..<n where a != b {
                let forward = next.contains(a * n + b)
                symmetric[a, b] = 1 - sim[a, b] + (forward || next.contains(b * n + a) ? 0 : spokenBonus)
                directed[a, b] = 1 - sim[a, b] - (forward ? spokenBonus : 0)
            }
        }
        let path = shortestPath(symmetric)
        let forward = directedRefine(path, directed), backward = directedRefine(path.reversed(), directed)
        let order = pathCost(backward, directed) < pathCost(forward, directed) - 1e-5 ? backward : forward
        // A chapter never breaks between a thought and the one spoken right after it.
        let allowed = Set((1..<n).filter { !next.contains(order[$0 - 1] * n + order[$0]) })
        let k = max(1, min(14, Int((Double(n) / 2).squareRoot().rounded())))
        let hi = max(3 * minChapter, Int((2 * Double(n) / Double(k)).rounded(.up)))
        return cutChapters(order, sim, k: k, allowed: allowed, lo: minChapter, hi: hi)
    }

    /// Joins where the book jumps: far below the book's usual closeness, and not a spoken
    /// continuation. Each is a pair of neighbouring passage indices.
    static func gaps(_ chapters: [[Int]], _ passages: [OrgPassage]) -> [(before: Int, after: Int)] {
        let n = passages.count
        let next = spokenNext(passages)
        var joins: [(before: Int, after: Int, sim: Float)] = []
        for chapter in chapters {
            for (a, b) in zip(chapter, chapter.dropFirst()) {
                joins.append((a, b, BookEngine.similarity(passages[a].vector, passages[b].vector)))
            }
        }
        guard joins.count >= 8 else { return [] }
        let mean = joins.reduce(Float(0)) { $0 + $1.sim } / Float(joins.count)
        let variance = joins.reduce(Float(0)) { $0 + ($1.sim - mean) * ($1.sim - mean) } / Float(joins.count)
        let bar = min(0.25, mean - 1.5 * variance.squareRoot())
        return joins.filter { $0.sim < bar && !next.contains($0.before * n + $0.after) }.map { (before: $0.before, after: $0.after) }
    }

    /// Loners: passages whose nearest neighbour is further than almost every other passage's.
    /// They wait until related passages arrive.
    static func loners(_ vectors: [[Float]]) -> Set<Int> {
        guard vectors.count >= 12 else { return [] }
        var nearest: [Float] = []
        for (i, a) in vectors.enumerated() {
            var m: Float = -1
            for (j, b) in vectors.enumerated() where i != j { m = max(m, BookEngine.similarity(a, b)) }
            nearest.append(m)
        }
        let cut = nearest.sorted()[vectors.count / 20]   // the loneliest 5%
        return Set(nearest.indices.filter { nearest[$0] < cut - 1e-4 })
    }

    // MARK: - Keyphrases (chapter labels without AI, and search terms for Discover)

    static func phrases(_ text: String) -> [String] {
        let w = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map(String.init).filter { $0.count > 2 && !BookEngine.isStopword($0) }
        return w + zip(w, w.dropFirst()).filter { $0 != $1 }.map { $0 + " " + $1 }
    }

    /// Distinctive phrases of each group of texts against all groups (class-based TF-IDF).
    static func keyphrases(groups: [[String]], perGroup k: Int = 4, minCount: Int = 2) -> [[String]] {
        let docs = groups.flatMap { $0 }
        var df: [String: Int] = [:]
        for d in docs { for p in Set(phrases(d)) { df[p, default: 0] += 1 } }
        let n = Double(max(1, docs.count))
        return groups.map { texts in
            var tf: [String: Int] = [:]
            for t in texts { for p in phrases(t) { tf[p, default: 0] += 1 } }
            let scored = tf.compactMap { p, c -> (String, Double)? in
                guard c >= minCount, let d = df[p], Double(d) <= n * 0.3 else { return nil }
                return (p, Double(c) * log(n / Double(d)) * (p.contains(" ") ? 1.6 : 1))
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            var out: [String] = []
            for (p, _) in scored where !out.contains(where: { $0.contains(p) || p.contains($0) }) {
                out.append(p)
                if out.count == k { break }
            }
            return out
        }
    }
}
