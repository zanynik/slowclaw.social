import Foundation

@main
enum JevPersonaTests {
    static func main() {
        precondition(JevPersona.topics.count == 224)
        precondition(Set(JevPersona.topics).count == 224)
        func scores(_ index: Int) -> [Double] {
            var result = Array(repeating: 0.0, count: 224)
            result[index] = 1
            return result
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let older = JevPersona.Record(fingerprint: "old", date: now.addingTimeInterval(-90 * 86400), scores: scores(0))
        let newer = JevPersona.Record(fingerprint: "new", date: now, scores: scores(1))
        let weights = JevPersona.vector([older, newer], now: now)
        precondition(abs(weights[0] - 0.5) < 0.00001 && weights[1] == 1)
        precondition(JevPersona.similarity(weights, scores(1)) > JevPersona.similarity(weights, scores(0)))
        precondition(JevPersona.similarity(weights, scores(2)) == 0)
        precondition(JevPersona.similarity(Array(repeating: 0, count: 224), scores(0)) == 0)
        precondition(JevPersona.similarity(weights, Array(repeating: 0.4, count: 224)) == 0)
        var records = ["journal": older]
        records["journal"] = newer
        precondition(JevPersona.vector(Array(records.values), now: now)[0] == 0)
        records.removeValue(forKey: "journal")
        precondition(JevPersona.vector(Array(records.values), now: now).allSatisfy { $0 == 0 })
        precondition(!JevPersona.valid([1]))
        precondition(!JevPersona.valid(Array(repeating: .nan, count: 224)))
        precondition(JevPersona.explanation(weights, scores(1)) == JevPersona.topics[1])
        print("Persona ranking, decay, replacement, removal and invalid-score checks passed.")
    }
}
