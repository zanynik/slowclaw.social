import XCTest
@testable import Runtime

final class PulseSnapshotTests: XCTestCase {
    func testSnapshotRejectsCorruptVersionAndOversizedData() throws {
        XCTAssertTrue(PulseSnapshot.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(PulseSnapshot.decode(Data(repeating: 32, count: 4_000_001)).isEmpty)
        let future = try JSONEncoder().encode(PulseSnapshot.Saved(version: 2, items: []))
        XCTAssertTrue(PulseSnapshot.decode(future).isEmpty)
    }
    func testSnapshotRestoresExactRankedOrderAndRejectsDuplicates() throws {
        let json = """
        {"version":1,"items":[
        {"id":"nostr:b","title":"B","link":"nostr:b","description":"Second event, ranked first","sourceLabel":"Nostr posts","score":0.9,"readMinutes":1,"sourcePlatform":"nostr"},
        {"id":"nostr:a","title":"A","link":"nostr:a","description":"First event, ranked second","sourceLabel":"Nostr posts","score":0.8,"readMinutes":1,"sourcePlatform":"nostr"}
        ]}
        """
        let items = PulseSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["nostr:b", "nostr:a"])
        let duplicate = try JSONEncoder().encode(PulseSnapshot.Saved(version: 1, items: items + items))
        XCTAssertTrue(PulseSnapshot.decode(duplicate).isEmpty)
    }
}
