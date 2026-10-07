import Foundation
import CryptoKit

/// Exact excerpts with normalized EmbeddingGemma 2 vectors. No generated prose.
enum JournalUnits {
    static let model = "embeddinggemma-2-text-vision-440m@e301f74d5551b0c2641bd5cb4652a76239d5c5f8:256"
    struct Unit: Codable, Identifiable, Sendable {
        let id: String
        let sourceKey: String
        let text: String
        let vector: [Double]
    }
    struct Record: Codable {
        let revision: String
        let model: String
        let units: [Unit]
    }
    struct Submission: Decodable {
        let kind: String
        let key: String
        let base: String
        let model: String
        let units: [Candidate]
        struct Candidate: Decodable { let text: String; let vector: [Double] }
        func record(source: String) throws -> Record {
            guard kind == "units", model == JournalUnits.model, WebSessionProtocol.validID(base),
                  !key.isEmpty, key.utf8.count <= 240, units.count <= 512 else {
                throw PublishingError.message("Invalid organized thoughts.")
            }
            var seen = Set<String>()
            let values = try units.map { item -> Unit in
                let norm = item.vector.reduce(0) { $0 + $1 * $1 }
                guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      item.text.utf8.count <= 6000, source.contains(item.text), seen.insert(item.text).inserted,
                      item.vector.count == 256, item.vector.allSatisfy({ $0.isFinite && abs($0) <= 1.0001 }),
                      norm.isFinite, abs(norm - 1) < 0.01 else {
                    throw PublishingError.message("Organized thoughts do not match this journal.")
                }
                let id = WebSessionProtocol.digest(Data((key + "\n" + item.text).utf8))
                return Unit(id: id, sourceKey: key, text: item.text, vector: item.vector)
            }
            return Record(revision: base, model: model, units: values)
        }
    }
    struct Cache: Codable {
        var records: [String: Record] = [:]
        var dismissed: Set<String> = []
        static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("journal-units.json")
        }
        static func load() -> Cache { (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Cache() }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }
    struct Group: Identifiable, Sendable {
        let id: String
        var units: [Unit]
        var title: String { String(units[0].text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90)) }
    }
    /// Compare to the group's first excerpt to avoid chains of weak similarities.
    static func groups(_ units: [Unit]) -> [Group] {
        var result: [Group] = []
        for unit in units.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { return [] }
            var best: Int?, score = 0.94
            for i in result.indices {
                let vector = result[i].units[0].vector
                guard vector.count == unit.vector.count else { continue }
                let similarity = zip(vector, unit.vector).reduce(0) { $0 + $1.0 * $1.1 }
                if similarity >= score { score = similarity; best = i }
            }
            if let best { result[best].units.append(unit) }
            else { result.append(Group(id: unit.id, units: [unit])) }
        }
        return result.sorted { $0.units.count == $1.units.count ? $0.id < $1.id : $0.units.count > $1.units.count }
    }
}
