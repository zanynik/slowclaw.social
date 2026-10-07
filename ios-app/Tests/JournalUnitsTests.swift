import XCTest
@testable import Runtime

final class JournalUnitsTests: XCTestCase {
    func testSubmissionRequiresCurrentModelAndExactSource() throws {
        let vector = [1.0] + Array(repeating: 0.0, count: 255)
        func decode(_ text: String, model: String = JournalUnits.model) throws -> JournalUnits.Submission {
            let value: [String: Any] = ["kind": "units", "key": "journal_test", "base": String(repeating: "a", count: 64),
                "model": model, "units": [["text": text, "vector": vector]]]
            return try JSONDecoder().decode(JournalUnits.Submission.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let source = "A quiet walk helps me reflect."
        let record = try decode(source).record(source: source)
        XCTAssertEqual(record.units.first?.text, source)
        XCTAssertThrowsError(try decode("Invented words").record(source: source))
        XCTAssertThrowsError(try decode(source, model: "different-model").record(source: source))
    }
    func testGroupsRequireStrongDirectSimilarity() {
        let a = [1.0] + Array(repeating: 0.0, count: 255)
        let b = [0.0, 1.0] + Array(repeating: 0.0, count: 254)
        let units = [JournalUnits.Unit(id: "a", sourceKey: "one", text: "Walk outside", vector: a),
                     JournalUnits.Unit(id: "b", sourceKey: "two", text: "Walking helps", vector: a),
                     JournalUnits.Unit(id: "c", sourceKey: "two", text: "Review project", vector: b)]
        let groups = JournalUnits.groups(units)
        XCTAssertEqual(groups.map(\.units.count), [2, 1])
        XCTAssertEqual(JournalUnits.groups(Array(units.reversed())).map(\.id), groups.map(\.id))
    }
}
