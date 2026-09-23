import Foundation

/// Owns a bounded in-memory embedding cache; all native calls use the existing
/// serial executor, never the main actor. Snapshot persistence is separate.
actor PulseRanking {
    static let shared = PulseRanking()
    enum Failure: LocalizedError {
        case invalid, inference
        var errorDescription: String? {
            "Couldn’t refresh local Pulse ranking. Your previous posts are still available."
        }
    }
    private var vectors: [String: [Float]] = [:]
    private var order: [String] = []

    private static func packed(_ strings: [String]) throws -> Data {
        var result = Data()
        for string in strings {
            let bytes = Data(string.utf8)
            guard bytes.count <= Int(UInt32.max) else { throw Failure.invalid }
            var length = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }

    func embedding(_ text: String) async throws -> [Float] {
        let key = JevBatch.digest(text)
        if let vector = vectors[key] { return vector }
        guard !text.isEmpty, text.utf8.count <= 1200, !text.contains("\0") else { throw Failure.invalid }
        let vector: [Float] = try await OnDeviceAIExecutor.shared.run {
            let data = Data(text.utf8)
            var result = [Float](repeating: 0, count: 3072)
            let rc = data.withUnsafeBytes { raw in
                result.withUnsafeMutableBufferPointer { buffer in
                    slowclaw_feed_needle_embed(raw.bindMemory(to: UInt8.self).baseAddress, data.count, buffer.baseAddress, buffer.count)
                }
            }
            guard rc == 0, result.allSatisfy(\.isFinite) else { throw Failure.inference }
            return result
        }
        vectors[key] = vector; order.append(key)
        while order.count > 240 { vectors.removeValue(forKey: order.removeFirst()) }
        return vector
    }

    func rank(texts: [String], interests: [JevBatch.Interest], topicVectors: [[Float]], postVectors: [[Float]]) async throws -> [Double] {
        guard !texts.isEmpty, texts.count <= 40, texts.count == postVectors.count,
              interests.count == topicVectors.count, !interests.isEmpty,
              (topicVectors + postVectors).allSatisfy({ $0.count == 3072 }) else { throw Failure.invalid }
        var centroid = [Double](repeating: 0, count: 3072)
        for (interest, vector) in zip(interests, topicVectors) {
            for i in centroid.indices { centroid[i] += Double(vector[i]) * interest.weight }
        }
        let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw Failure.invalid }
        let cosines = postVectors.map { v in zip(v, centroid).reduce(0.0) { $0 + Double($1.0) * $1.1 } / norm }
        let query = try Self.packed(interests.map(\.topic)), documents = try Self.packed(texts)
        let weights = interests.map(\.weight)
        return try await OnDeviceAIExecutor.shared.run {
            var scores = [Double](repeating: 0, count: texts.count)
            let rc = query.withUnsafeBytes { q in documents.withUnsafeBytes { d in
                weights.withUnsafeBufferPointer { w in cosines.withUnsafeBufferPointer { c in
                    scores.withUnsafeMutableBufferPointer { out in
                        slowclaw_feed_pulse_rank(q.bindMemory(to: UInt8.self).baseAddress, query.count,
                            w.baseAddress, w.count, d.bindMemory(to: UInt8.self).baseAddress, documents.count,
                            c.baseAddress, out.baseAddress, out.count)
                    }
                } }
            } }
            guard rc == 0, scores.allSatisfy(\.isFinite) else { throw Failure.invalid }
            return scores
        }
    }
}
