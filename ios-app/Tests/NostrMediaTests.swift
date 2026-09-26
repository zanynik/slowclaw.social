import XCTest
@testable import Runtime

final class NostrMediaTests: XCTestCase {
    func testUploadAuthorizationIsSignedAndScopedToReviewedExport() throws {
        let hash = String(repeating: "a", count: 64)
        let header = try NostrMedia.authorization(hash: hash, host: "cdn.example.com", secret: Array(repeating: 1, count: 32), now: 1_800_000_000)
        var base64 = String(header.dropFirst(6)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let event = try JSONDecoder().decode(PublishedEvent.self, from: XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertTrue(NostrEventVerifier.verify(event, now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(event.kind, 24242)
        XCTAssertTrue(event.tags.contains(["t", "upload"]))
        XCTAssertTrue(event.tags.contains(["x", hash]))
        XCTAssertTrue(event.tags.contains(["server", "cdn.example.com"]))
        XCTAssertTrue(event.tags.contains(["expiration", "1800000300"]))
    }
    func testMediaReceiptMustMatchExportAndUseHTTPS() throws {
        let hash = String(repeating: "a", count: 64)
        let good = NostrMedia.Descriptor(url: URL(string: "https://cdn.example.com/\(hash).png")!, sha256: hash, size: 200, type: "image/png")
        XCTAssertEqual(try good.validate(hash: hash, bytes: 200, mime: "image/png"), good.url)
        XCTAssertThrowsError(try good.validate(hash: "other", bytes: 200, mime: "image/png"))
        XCTAssertThrowsError(try good.validate(hash: hash, bytes: 201, mime: "image/png"))
        XCTAssertThrowsError(try good.validate(hash: hash, bytes: 200, mime: "video/mp4"))
        for server in ["http://example.com", "https://user@example.com", "https://example.com/upload", "https://example.com?key=example"] {
            XCTAssertThrowsError(try NostrMedia.endpoint(server))
        }
        XCTAssertEqual(try NostrMedia.endpoint("https://cdn.example.com").absoluteString, "https://cdn.example.com/upload")
    }
}
