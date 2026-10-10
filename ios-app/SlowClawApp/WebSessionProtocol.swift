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
        var origin: String = WebSessionProtocol.origin
        var signaling: String? = nil
    }
    static func pairing(_ value: String) throws -> Pairing {
        guard value.utf8.count < 2000, let url = URLComponents(string: value), url.scheme == "https",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil,
              let fragment = url.fragment,
              let fields = URLComponents(string: "https://example.com/?" + fragment)?.queryItems,
              Set(fields.map(\.name)).count == fields.count,
              let id = fields.first(where: { $0.name == "id" })?.value,
              let pair = fields.first(where: { $0.name == "pair" })?.value,
              let rawKey = fields.first(where: { $0.name == "key" })?.value,
              validID(id), validID(pair), validID(rawKey), let bytes = NostrEventVerifier.bytes(rawKey, count: 32) else {
            throw PublishingError.message("Scan a fresh QR code from SlowClaw Web.")
        }
        if fields.count == 3, url.host == "slowclaw-web.zanynik.chatgpt.site", url.path == "/pair" {
            return Pairing(id: id, pair: pair, key: Data(bytes))
        }
        guard fields.count == 5, Set(fields.map(\.name)) == Set(["v", "id", "pair", "key", "signal"]),
              fields.first(where: { $0.name == "v" })?.value == "2", url.host == "slowclaw.social", url.path == "/",
              let signal = fields.first(where: { $0.name == "signal" })?.value,
              let endpoint = URLComponents(string: signal), endpoint.scheme == "https",
              endpoint.host?.hasSuffix(".workers.dev") == true, endpoint.host != "workers.dev",
              endpoint.user == nil, endpoint.password == nil, endpoint.port == nil,
              (endpoint.path == "" || endpoint.path == "/"), endpoint.query == nil, endpoint.fragment == nil else {
            throw PublishingError.message("Use a pairing code from slowclaw.social with a Cloudflare signaling Worker.")
        }
        return Pairing(id: id, pair: pair, key: Data(bytes), origin: "https://slowclaw.social", signaling: "https://" + endpoint.host!)
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
