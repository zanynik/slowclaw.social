import Foundation

// Shared text and vector helpers for the living book: similarity, content words, novelty,
// fallback titles and the 2D map projection. The book's rules live in BookOrganizer.

enum BookEngine {
    // MARK: - Vectors

    static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let n = sum.squareRoot()
        guard n > 0, n.isFinite else { return v }
        return v.map { $0 / n }
    }

    /// Cosine similarity of two unit vectors (0 when they are not comparable).
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    // MARK: - Words

    private static let stopwords: Set<String> = [
        "about", "after", "again", "also", "because", "been", "before", "being", "could", "does",
        "doing", "down", "each", "even", "every", "from", "have", "having", "here", "into", "just",
        "know", "like", "more", "most", "much", "only", "other", "over", "really", "should", "some",
        "still", "such", "than", "that", "their", "them", "then", "there", "these", "they", "thing",
        "things", "think", "this", "those", "through", "today", "very", "want", "was", "were",
        "what", "when", "where", "which", "while", "will", "with", "would", "your", "yours", "myself",
        "feel", "felt", "maybe", "going", "make", "made", "time", "kind", "sort", "lot", "something",
    ]

    /// The prototype's stopword list (common words and spoken fillers), for substance and keyphrases.
    private static let extendedStopwords: Set<String> = Set("""
    a about above after again against all also am an and any are as at be because been before being below between both but by \
    can could did do does doing down during each even every few for from further had has have having he her here hers him his how i if in \
    into is it its itself just let me more most my myself no nor not now of off on once only or other our ours out over own really same \
    she should so some something such than that the their them then there these they thing things think this those through to too under \
    until up very was we were what when where which while who why will with would you your yeah okay know mean guess maybe want going get \
    got go lot kind sort actually basically right well like said say says one much many way stuff need see feel people time \
    today anything everything someone everybody somebody whatever still already always never i'm it's that's don't i've i'll you're \
    can't didn't doesn't isn't there's what's let's gonna wanna
    """.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

    static func isStopword(_ w: String) -> Bool {
        let lower = w.lowercased()
        return stopwords.contains(lower) || extendedStopwords.contains(lower)
    }

    static func contentWords(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.count >= 4, !stopwords.contains(w) { out.insert(stem(w)) }
        }
        return out
    }

    /// Crude plural/tense folding so "runs", "running" and "run" count as one idea.
    private static func stem(_ w: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Share of `text`'s content words that do not appear in `known`.
    static func newInformation(_ text: String, comparedTo known: [String]) -> Double {
        let mine = contentWords(text)
        guard !mine.isEmpty else { return 0 }
        var seen = Set<String>()
        for k in known { seen.formUnion(contentWords(k)) }
        return Double(mine.subtracting(seen).count) / Double(mine.count)
    }

    /// Fallback chapter title: the two words its passages share most.
    static func keywordTitle(_ texts: [String]) -> String {
        var counts: [String: Int] = [:]
        for t in texts {
            var seen = Set<String>()
            for raw in t.lowercased().split(whereSeparator: { !$0.isLetter }) {
                let w = String(raw)
                if w.count >= 4, !stopwords.contains(w), seen.insert(w).inserted { counts[w, default: 0] += 1 }
            }
        }
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(2).map { $0.key.prefix(1).uppercased() + $0.key.dropFirst() }
        return top.isEmpty ? "Untitled" : top.joined(separator: " & ")
    }

    // MARK: - Map

    /// Projects vectors to 2D with PCA (power iteration). Coordinates land in 0.05…0.95.
    /// `previousAxes` keeps the map from flipping as the book grows.
    static func project(_ vectors: [[Float]], previousAxes: [[Float]]? = nil) -> (points: [(Double, Double)], axes: [[Float]]) {
        let n = vectors.count
        guard n > 0, let d = vectors.first?.count, d > 0, vectors.allSatisfy({ $0.count == d }) else {
            return (vectors.map { _ in (0.5, 0.5) }, [])
        }
        if n == 1 { return ([(0.5, 0.5)], previousAxes ?? []) }

        var mean = [Float](repeating: 0, count: d)
        for v in vectors { for i in 0..<d { mean[i] += v[i] } }
        for i in 0..<d { mean[i] /= Float(n) }
        let centered = vectors.map { v in (0..<d).map { v[$0] - mean[$0] } }

        func multiply(_ v: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: d)
            for x in centered {
                var dot: Float = 0
                for i in 0..<d { dot += x[i] * v[i] }
                for i in 0..<d { out[i] += dot * x[i] }
            }
            return out
        }

        var axes: [[Float]] = []
        for k in 0..<2 {
            // Deterministic start so the same book always gives the same map.
            var v = (0..<d).map { Float(sin(Double($0 * (k + 3) + 1))) }
            for _ in 0..<60 {
                v = multiply(v)
                for a in axes {
                    let dot = similarity(v, a)
                    for i in 0..<d { v[i] -= dot * a[i] }
                }
                v = normalized(v)
            }
            if let prev = previousAxes, prev.count > k, prev[k].count == d, similarity(v, prev[k]) < 0 {
                v = v.map { -$0 }
            }
            axes.append(v)
        }

        let raw = centered.map { (Double(similarity($0, axes[0])), Double(similarity($0, axes[1]))) }
        func scale(_ values: [Double]) -> [Double] {
            guard let lo = values.min(), let hi = values.max(), hi - lo > 1e-9 else { return values.map { _ in 0.5 } }
            return values.map { 0.05 + 0.9 * ($0 - lo) / (hi - lo) }
        }
        let xs = scale(raw.map(\.0)), ys = scale(raw.map(\.1))
        return (Array(zip(xs, ys)), axes)
    }
}
