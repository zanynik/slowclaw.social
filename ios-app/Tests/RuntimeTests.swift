import XCTest
@testable import Runtime

final class RuntimeTests: XCTestCase {
    func testBIP340VectorZero() throws {
        // Published BIP-340 test key, never used as an app identity.
        let key = Array(repeating: UInt8(0), count: 31) + [3]
        XCTAssertEqual(try NostrIdentity.publicKey(key),
            "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
        // sign() independently verifies every generated signature with libsecp256k1.
        XCTAssertEqual(try NostrIdentity.sign(hash: Array(repeating: 0, count: 32), secret: key).count, 128)
        XCTAssertThrowsError(try NostrIdentity.publicKey(Array(repeating: 0, count: 32)))
    }

    func testSecretRoundTripRejectsCorruption() {
        let key = Array(repeating: UInt8(7), count: 32)
        let encoded = Nip19.encodeKey(key, prefix: "nsec")
        XCTAssertEqual(Nip19.decodeSecret(encoded), key)
        XCTAssertEqual(Nip19.decodeSecret(encoded.uppercased()), key)
        XCTAssertNil(Nip19.decodeSecret(String(encoded.dropLast()) + (encoded.last == "q" ? "p" : "q")))
        XCTAssertNil(Nip19.decodeSecret("N" + encoded.dropFirst()))
    }

    func testExecutorDoesNotOverlapOrBlockMain() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var active = 0
            var maximum = 0
            func work() -> Bool {
                lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
                Thread.sleep(forTimeInterval: 0.03)
                let offMain = !Thread.isMainThread
                lock.lock(); active -= 1; lock.unlock()
                return offMain
            }
        }
        let counter = Counter()
        let executor = OnDeviceAIExecutor()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { try await executor.run { counter.work() } } }
            for try await offMain in group { XCTAssertTrue(offMain) }
        }
        XCTAssertEqual(counter.maximum, 1)
    }
}
