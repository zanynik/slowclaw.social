import Foundation

// Book v3 rules, ported from the Python prototype that was tuned on real journals with the
// same MiniLM vectors (see docs/book.md). No language model is needed to build the book:
//
//   journal → sentences → topic segments (where meaning turns) → the most central 3–5
//   sentences of each substantial segment → drop repeats → themes (spherical k-means,
//   about √(n/2)) → chapters in order of closeness, passages in date order.

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

    // MARK: - Themes

    /// Spherical k-means with k-means++ starts (fixed seeds, so the same book gives the same chapters).
    static func themes(_ vectors: [[Float]], k: Int, restarts: Int = 8, iterations: Int = 40) -> [[Int]] {
        let n = vectors.count
        guard n > 0 else { return [] }
        let k = max(1, min(k, n))
        var best: (score: Float, labels: [Int])?
        for r in 0..<restarts {
            var rng = SeededRandom(seed: UInt64(r + 1))
            var centers = [vectors[Int(rng.next() % UInt64(n))]]
            while centers.count < k {
                let d = vectors.map { v in max(0, 1 - centers.map { BookEngine.similarity(v, $0) }.max()!) }
                let weights = d.map { $0 * $0 }
                let total = weights.reduce(0, +)
                if total <= 0 { centers.append(vectors[Int(rng.next() % UInt64(n))]); continue }
                var pick = Float(Double(rng.next() % 1_000_000) / 1_000_000) * total
                var chosen = n - 1
                for (i, wgt) in weights.enumerated() { pick -= wgt; if pick <= 0 { chosen = i; break } }
                centers.append(vectors[chosen])
            }
            var labels = [Int](repeating: 0, count: n)
            for _ in 0..<iterations {
                let newLabels = vectors.map { v in centers.indices.max { BookEngine.similarity(v, centers[$0]) < BookEngine.similarity(v, centers[$1]) }! }
                if newLabels == labels && centers.count == k { labels = newLabels; break }
                labels = newLabels
                for c in centers.indices {
                    let members = vectors.indices.filter { labels[$0] == c }
                    if !members.isEmpty { centers[c] = mean(ArraySlice(members.map { vectors[$0] })) }
                }
            }
            let score = vectors.indices.reduce(Float(0)) { $0 + BookEngine.similarity(vectors[$1], centers[labels[$1]]) }
            if best == nil || score > best!.score { best = (score, labels) }
        }
        var groups = (0..<k).map { c in best!.labels.indices.filter { best!.labels[$0] == c } }.filter { !$0.isEmpty }
        // Fold themes of one or two passages into their closest theme.
        let small = groups.filter { $0.count < 3 }
        groups = groups.filter { $0.count >= 3 }
        if groups.isEmpty { return [Array(0..<n)] }
        for g in small { for i in g {
            let target = groups.indices.max { avgSim(i, groups[$0], vectors) < avgSim(i, groups[$1], vectors) }!
            groups[target].append(i)
        } }
        return groups
    }

    private static func avgSim(_ i: Int, _ group: [Int], _ vs: [[Float]]) -> Float {
        group.reduce(0) { $0 + BookEngine.similarity(vs[i], vs[$1]) } / Float(max(1, group.count))
    }

    /// Chapters as lists of passage indices, in reading order: the theme that began earliest
    /// first, then the closest remaining theme; inside a chapter, by date.
    static func organize(_ passages: [OrgPassage]) -> [[Int]] {
        let n = passages.count
        guard n > 0 else { return [] }
        let vectors = passages.map(\.vector)
        let k = max(1, min(14, Int((Double(n) / 2).squareRoot().rounded())))
        let groups = n < 6 ? [Array(0..<n)] : themes(vectors, k: k)
        let centroids = groups.map { mean(ArraySlice($0.map { vectors[$0] })) }
        func earliest(_ g: [Int]) -> Int { g.map { passages[$0].day }.min() ?? 0 }
        var order = [groups.indices.min { earliest(groups[$0]) < earliest(groups[$1]) }!]
        var left = Set(groups.indices).subtracting(order)
        while !left.isEmpty {
            let last = centroids[order.last!]
            let next = left.max { BookEngine.similarity(last, centroids[$0]) < BookEngine.similarity(last, centroids[$1]) }!
            order.append(next); left.remove(next)
        }
        return order.map { groups[$0].sorted { a, b in
            let pa = passages[a], pb = passages[b]
            return pa.day == pb.day ? (pa.journal == pb.journal ? pa.seq < pb.seq : pa.journal < pb.journal) : pa.day < pb.day
        } }
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

/// Small deterministic generator (SplitMix64) so chapters do not change between launches.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
