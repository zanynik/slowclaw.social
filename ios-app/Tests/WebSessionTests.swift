import XCTest
import CryptoKit
@testable import Runtime
final class WebSessionTests: XCTestCase {
    func testPairingRejectsDifferentOriginAndDuplicateFields() throws {
        let value = WebSessionProtocol.origin + "/pair#id=" + String(repeating: "1", count: 64) + "&pair=" + String(repeating: "2", count: 64) + "&key=" + String(repeating: "3", count: 64)
        XCTAssertEqual(try WebSessionProtocol.pairing(value).key.count, 32)
        XCTAssertThrowsError(try WebSessionProtocol.pairing(value.replacingOccurrences(of: "slowclaw-web.zanynik.chatgpt.site", with: "example.com")))
        XCTAssertThrowsError(try WebSessionProtocol.pairing(value + "&id=" + String(repeating: "1", count: 64)))
        XCTAssertThrowsError(try WebSessionProtocol.pairing(value.replacingOccurrences(of: "https://", with: "http://")))
        XCTAssertThrowsError(try WebSessionProtocol.pairing(value.replacingOccurrences(of: "/pair#", with: "/pair?untrusted=1#")))
    }
    func testCiphertextIsBoundToSessionAndTransfer() throws {
        let key = Data(repeating: 7, count: 32), body = Data("SlowClawAgent garden journal".utf8)
        let sealed = try WebSessionProtocol.seal(body, key: key, context: "session/file")
        XCTAssertEqual(try WebSessionProtocol.open(sealed, key: key, context: "session/file"), body)
        XCTAssertThrowsError(try WebSessionProtocol.open(sealed, key: key, context: "other/file"))
        var tampered = sealed; tampered[tampered.count-1] ^= 1
        XCTAssertThrowsError(try WebSessionProtocol.open(tampered, key: key, context: "session/file"))
    }
    func testNIP98SignsExactURLMethodAndBodyWithoutSecret() throws {
        let secret = Array(repeating: UInt8(0), count: 31) + [UInt8(1)]
        let url = URL(string: WebSessionProtocol.origin + "/api/session/example/snapshot")!
        let body = Data("{}".utf8)
        let auth = try WebSessionProtocol.authorization(url: url, method: "PUT", body: body, secret: secret)
        let data = try XCTUnwrap(Data(base64Encoded: String(auth.dropFirst(6))))
        let event = try JSONDecoder().decode(PublishedEvent.self, from: data)
        XCTAssertEqual(event.kind, 27235)
        XCTAssertTrue(event.tags.contains(["u", url.absoluteString]))
        XCTAssertTrue(event.tags.contains(["method", "PUT"]))
        XCTAssertTrue(event.tags.contains(["payload", WebSessionProtocol.digest(body)]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(NostrIdentity.hex(secret)))
        XCTAssertNotEqual(auth, try WebSessionProtocol.authorization(url: url, method: "PUT", body: body, secret: secret))
    }
    func testBrowserCryptoFixture() throws {
        // WebCrypto AES-GCM vector: key bytes 7, nonce bytes 1, bound context.
        let combined = try XCTUnwrap(Data(base64Encoded: "AQEBAQEBAQEBAQEBJY3mwNPTjXmQs7lPBBcXUNqfcZo4/VRmKl8iDgkPHAUXEWEoclfph7+/C/c="))
        XCTAssertEqual(String(decoding: try WebSessionProtocol.open(combined, key: Data(repeating: 7, count: 32), context: "session/file"), as: UTF8.self), "SlowClawAgent garden journal")
    }
    func testJournalWriteRequiresMatchingRevisionAndRetriesAreIdempotent() throws {
        let operation = WebJournalEdit(kind: "write", key: "journal_web_" + String(repeating: "a", count: 64), base: "b".repeat64, title: "Journal", text: "Browser text")
        try operation.validate()
        XCTAssertEqual(operation.decision(current: "Old text", revision: "b".repeat64, available: true), "saved")
        XCTAssertEqual(operation.decision(current: "Phone edit", revision: "c".repeat64, available: true), "conflict")
        XCTAssertEqual(operation.decision(current: operation.content, revision: "c".repeat64, available: true), "saved")
        XCTAssertEqual(operation.decision(current: nil, revision: nil, available: false), "rejected")
    }
    func testNewJournalCannotResurrectMissingOrExcludedExistingEntry() throws {
        let key = "journal_web_" + String(repeating: "a", count: 64)
        let create = WebJournalEdit(kind: "write", key: key, base: nil, title: "Journal", text: "Text")
        XCTAssertEqual(create.decision(current: nil, revision: nil, available: false), "saved")
        XCTAssertEqual(create.decision(current: create.content, revision: nil, available: false), "rejected")
        let old = WebJournalEdit(kind: "write", key: "journal_123", base: nil, title: "Journal", text: "Text")
        XCTAssertEqual(old.decision(current: nil, revision: nil, available: false), "rejected")
    }
    func testTranscriptReadsAndTextValidation() throws {
        let read = WebJournalEdit(kind: "read", key: "journal_123", base: nil, title: nil, text: nil)
        try read.validate()
        XCTAssertEqual(read.decision(current: "Transcript", revision: nil, available: true), "loaded")
        XCTAssertEqual(read.decision(current: "Transcript", revision: nil, available: false), "rejected")
        XCTAssertThrowsError(try WebJournalEdit(kind: "write", key: "journal_123", base: nil, title: "Invalid\ntitle", text: "Text").validate())
        XCTAssertThrowsError(try WebJournalEdit(kind: "write", key: "journal_123", base: nil, title: "Journal", text: String(repeating: "a", count: 1_000_001)).validate())
    }
}

private extension String { var repeat64: String { String(repeating: self, count: 64) } }
