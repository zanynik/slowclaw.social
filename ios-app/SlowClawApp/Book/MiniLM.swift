import Foundation
import Accelerate

/// all-MiniLM-L6-v2 sentence embeddings, on the phone (Apache-2.0 weights bundled in Model/).
///
/// The same model, step for step, as the Python prototype the book and Discover were tuned
/// with (`minilm.py`), so what was measured there is what the phone computes. A unit test
/// checks the vectors against golden values exported from that prototype.
final class MiniLM: @unchecked Sendable {
    static let dimension = 384
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: MiniLM?

    /// Loaded once, on first use (~90 MB of floats). Safe to call from any thread.
    static var shared: MiniLM? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let w = Bundle.main.url(forResource: "minilm", withExtension: "weights"),
              let v = Bundle.main.url(forResource: "minilm", withExtension: "vocab"),
              let m = try? MiniLM(weights: w, vocab: v) else { return nil }
        loaded = m
        return m
    }

    private let vocab: [String: Int]
    private let w: [String: [Float]]
    private let layers = 6, heads = 12, hidden = 384, intermediate = 1536
    private let eps: Float = 1e-12
    private let cls: Int, sep: Int, unk: Int

    init(weights: URL, vocab vocabURL: URL) throws {
        let text = try String(contentsOf: vocabURL, encoding: .utf8)
        var v: [String: Int] = [:]
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            v[String(line)] = i
        }
        vocab = v
        guard let c = v["[CLS]"], let s = v["[SEP]"], let u = v["[UNK]"] else { throw CocoaError(.fileReadCorruptFile) }
        cls = c; sep = s; unk = u
        w = try Self.loadWeights(weights)
    }

    /// minilm.weights: "MLM1", UInt32 header length, JSON {name: {offset, shape}}, fp16 data.
    private static func loadWeights(_ url: URL) throws -> [String: [Float]] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8, data.prefix(4) == Data("MLM1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let headerLength = data.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let headerData = data.subdata(in: 8..<(8 + headerLength))
        guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: [String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let base = 8 + headerLength
        var out: [String: [Float]] = [:]
        for (name, meta) in header {
            guard let offset = meta["offset"] as? Int, let shape = meta["shape"] as? [Int] else { continue }
            let count = shape.reduce(1, *)
            let start = base + offset
            var halves = [UInt16](repeating: 0, count: count)
            _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0, from: start..<(start + count * 2)) }
            var floats = [Float](repeating: 0, count: count)
            halves.withUnsafeBufferPointer { src in
                floats.withUnsafeMutableBufferPointer { dst in
                    var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                }
            }
            out[name] = floats
        }
        return out
    }

    // MARK: - Tokenizer (BERT uncased WordPiece)

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    func basicTokens(_ text: String) -> [String] {
        // Clean: drop control characters, turn whitespace into spaces.
        var cleaned = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD { continue }
            if s == "\t" || s == "\n" || s == "\r" || s.properties.generalCategory == .spaceSeparator { cleaned.append(" "); continue }
            switch s.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned: continue
            default: cleaned.append(s)
            }
        }
        var out: [String] = []
        for word in String(cleaned).lowercased().split(whereSeparator: { $0.isWhitespace }) {
            // Strip accents: decompose and drop non-spacing marks.
            let stripped = String(String.UnicodeScalarView(String(word).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }))
            var current = String.UnicodeScalarView()
            for s in stripped.unicodeScalars {
                if Self.isPunctuation(s) || (0x4E00...0x9FFF).contains(s.value) {
                    if !current.isEmpty { out.append(String(current)); current = String.UnicodeScalarView() }
                    out.append(String(s))
                } else {
                    current.append(s)
                }
            }
            if !current.isEmpty { out.append(String(current)) }
        }
        return out
    }

    private func wordpiece(_ word: String) -> [Int] {
        let chars = Array(word.unicodeScalars)
        if chars.count > 100 { return [unk] }
        var ids: [Int] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int?
            while start < end {
                var piece = String(String.UnicodeScalarView(chars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            ids.append(id)
            start = end
        }
        return ids
    }

    func encode(_ text: String, maxLength: Int = 256) -> [Int] {
        var ids = [cls]
        for t in basicTokens(text) { ids += wordpiece(t) }
        return Array(ids.prefix(maxLength - 1)) + [sep]
    }

    // MARK: - Model

    private func layerNorm(_ x: inout [Float], rows: Int, _ name: String) {
        let g = w[name + ".weight"]!, b = w[name + ".bias"]!
        let n = hidden
        x.withUnsafeMutableBufferPointer { p in
            for r in 0..<rows {
                let row = p.baseAddress! + r * n
                var mean: Float = 0, sq: Float = 0
                vDSP_meanv(row, 1, &mean, vDSP_Length(n))
                var neg = -mean
                vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(n))
                vDSP_measqv(row, 1, &sq, vDSP_Length(n))
                var inv = 1 / (sq + eps).squareRoot()
                vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(n))
                vDSP_vmul(row, 1, g, 1, row, 1, vDSP_Length(n))
                vDSP_vadd(row, 1, b, 1, row, 1, vDSP_Length(n))
            }
        }
    }

    /// y[rows × out] = x[rows × inDim] · Wᵀ + b, with W stored [out × inDim].
    private func dense(_ x: [Float], rows: Int, inDim: Int, outDim: Int, _ name: String) -> [Float] {
        let W = w[name + ".weight"]!, b = w[name + ".bias"]!
        var y = [Float](repeating: 0, count: rows * outDim)
        for r in 0..<rows { for c in 0..<outDim { y[r * outDim + c] = b[c] } }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outDim), Int32(inDim),
                    1, x, Int32(inDim), W, Int32(inDim), 1, &y, Int32(outDim))
        return y
    }

    /// Unit-length 384-dimensional vector for `text`.
    func embed(_ text: String) -> [Float] {
        let ids = encode(text)
        let n = ids.count, h = hidden, d = hidden / heads
        let wordE = w["embeddings.word_embeddings.weight"]!, posE = w["embeddings.position_embeddings.weight"]!
        let typeE = w["embeddings.token_type_embeddings.weight"]!
        var x = [Float](repeating: 0, count: n * h)
        for (i, id) in ids.enumerated() {
            for j in 0..<h { x[i * h + j] = wordE[id * h + j] + posE[i * h + j] + typeE[j] }
        }
        layerNorm(&x, rows: n, "embeddings.LayerNorm")

        for l in 0..<layers {
            let p = "encoder.layer.\(l)."
            let q = dense(x, rows: n, inDim: h, outDim: h, p + "attention.self.query")
            let k = dense(x, rows: n, inDim: h, outDim: h, p + "attention.self.key")
            let v = dense(x, rows: n, inDim: h, outDim: h, p + "attention.self.value")
            var ctx = [Float](repeating: 0, count: n * h)
            var scores = [Float](repeating: 0, count: n * n)
            let scale = 1 / Float(d).squareRoot()
            q.withUnsafeBufferPointer { qp in k.withUnsafeBufferPointer { kp in v.withUnsafeBufferPointer { vp in
                ctx.withUnsafeMutableBufferPointer { cp in
                    for head in 0..<heads {
                        let off = head * d
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(d), scale,
                                    qp.baseAddress! + off, Int32(h), kp.baseAddress! + off, Int32(h), 0, &scores, Int32(n))
                        // Row softmax.
                        for r in 0..<n {
                            scores.withUnsafeMutableBufferPointer { sp in
                                let row = sp.baseAddress! + r * n
                                var m: Float = 0
                                vDSP_maxv(row, 1, &m, vDSP_Length(n))
                                var neg = -m
                                vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(n))
                                var count = Int32(n)
                                vvexpf(row, row, &count)
                                var sum: Float = 0
                                vDSP_sve(row, 1, &sum, vDSP_Length(n))
                                var inv = 1 / sum
                                vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(n))
                            }
                        }
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(d), Int32(n), 1,
                                    scores, Int32(n), vp.baseAddress! + off, Int32(h), 0, cp.baseAddress! + off, Int32(h))
                    }
                }
            } } }
            var attn = dense(ctx, rows: n, inDim: h, outDim: h, p + "attention.output.dense")
            vDSP_vadd(attn, 1, x, 1, &attn, 1, vDSP_Length(n * h))
            layerNorm(&attn, rows: n, p + "attention.output.LayerNorm")
            x = attn

            var inter = dense(x, rows: n, inDim: h, outDim: intermediate, p + "intermediate.dense")
            for i in 0..<inter.count { let t = inter[i]; inter[i] = 0.5 * t * (1 + erf(t / 2.0.squareRoot().f)) }
            var out = dense(inter, rows: n, inDim: intermediate, outDim: h, p + "output.dense")
            vDSP_vadd(out, 1, x, 1, &out, 1, vDSP_Length(n * h))
            layerNorm(&out, rows: n, p + "output.LayerNorm")
            x = out
        }

        // Mean over tokens, then unit length.
        var pooled = [Float](repeating: 0, count: h)
        for i in 0..<n { for j in 0..<h { pooled[j] += x[i * h + j] } }
        var norm: Float = 0
        vDSP_svesq(pooled, 1, &norm, vDSP_Length(h))
        let inv = 1 / max(norm.squareRoot(), 1e-12)
        return pooled.map { $0 * inv }
    }
}

private extension Double {
    var f: Float { Float(self) }
}
