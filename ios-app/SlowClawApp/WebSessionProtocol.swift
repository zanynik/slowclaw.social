import Foundation
import CryptoKit

/// This protocol only authorizes the companion's HTTP requests. It never grants
/// remote signing or publishing rights and never exports the Nostr secret.
enum WebSessionProtocol {
    static let origin = "https://slowclaw-web.zanynik.chatgpt.site"
    struct Pairing: Equatable {
        let id: String
        let pair: String
        let key: Data
    }
    static func pairing(_ value: String) throws -> Pairing {
        guard value.utf8.count < 1500, let url = URLComponents(string: value),
              url.scheme == "https", url.host == "slowclaw-web.zanynik.chatgpt.site",
              url.port == nil, url.user == nil, url.password == nil, url.path == "/pair", url.query == nil,
              let fragment = url.fragment,
              let fields = URLComponents(string: "https://example.com/?" + fragment)?.queryItems,
              fields.count == 3, Set(fields.map(\.name)) == Set(["id", "pair", "key"]),
              let id = fields.first(where: { $0.name == "id" })?.value,
              let pair = fields.first(where: { $0.name == "pair" })?.value,
              let rawKey = fields.first(where: { $0.name == "key" })?.value,
              validID(id), validID(pair), validID(rawKey),
              let bytes = NostrEventVerifier.bytes(rawKey, count: 32) else {
            throw PublishingError.message("Scan a fresh QR code from SlowClaw Web.")
        }
        return Pairing(id: id, pair: pair, key: Data(bytes))
    }
    static func validID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func seal(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw PublishingError.message("Invalid session key.") }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw PublishingError.message("Could not encrypt this session.") }
        return combined
    }
    static func open(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32, data.count >= 28 else { throw PublishingError.message("Invalid encrypted data.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data(context.utf8))
    }
    static func authorization(url: URL, method: String, body: Data, secret: [UInt8], now: Date = Date()) throws -> String {
        let pubkey = try NostrIdentity.publicKey(secret), created = Int(now.timeIntervalSince1970)
        // A nonce makes two otherwise identical polls in one second distinct.
        let tags = [["u", url.absoluteString], ["method", method], ["payload", digest(body)], ["nonce", UUID().uuidString]]
        let canonical = try JSONSerialization.data(withJSONObject: [0, pubkey, created, 27235, tags, ""], options: [.withoutEscapingSlashes])
        let hash = Array(SHA256.hash(data: canonical))
        let event: [String: Any] = ["id": digest(canonical), "pubkey": pubkey, "created_at": created, "kind": 27235,
                                    "tags": tags, "content": "", "sig": try NostrIdentity.sign(hash: hash, secret: secret)]
        return "Nostr " + (try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes])).base64EncodedString()
    }
}
