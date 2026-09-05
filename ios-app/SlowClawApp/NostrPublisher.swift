import Foundation
import Combine
import CryptoKit
import Security
import libsecp256k1

enum PublishingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// NIP-01 / NIP-23 signing. Keys never enter defaults, logs, or relay frames.
enum NostrIdentity {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.slowclaw.nostr",
        kSecAttrAccount as String: "publishing-key"
    ]

    static func secret() throws -> [UInt8] {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw PublishingError.message("Set up your Nostr identity to publish.")
        }
        return Array(data)
    }

    static func install(_ bytes: [UInt8]) throws {
        _ = try publicKey(bytes)
        var item = query
        item[kSecValueData as String] = Data(bytes)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        // Never silently replace an existing identity.
        guard status == errSecSuccess else {
            throw PublishingError.message(status == errSecDuplicateItem
                ? "An identity already exists on this device. Back it up before changing accounts."
                : "Could not securely save the identity.")
        }
    }

    static func create() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PublishingError.message("Secure random generation failed.")
        }
        try install(bytes)
    }

    static func publicKey(_ secret: [UInt8]) throws -> String {
        guard secret.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            throw PublishingError.message("Invalid Nostr key.")
        }
        defer { secp256k1_context_destroy(ctx) }
        var pair = secp256k1_keypair()
        guard secp256k1_keypair_create(ctx, &pair, secret) == 1 else {
            throw PublishingError.message("Invalid Nostr secret key.")
        }
        var publicKey = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(ctx, &publicKey, nil, &pair) == 1 else {
            throw PublishingError.message("Could not derive the public key.")
        }
        var output = [UInt8](repeating: 0, count: 32)
        guard secp256k1_xonly_pubkey_serialize(ctx, &output, &publicKey) == 1 else {
            throw PublishingError.message("Could not encode the public key.")
        }
        return hex(output)
    }

    static func sign(hash: [UInt8], secret: [UInt8]) throws -> String {
        guard hash.count == 32, secret.count == 32,
              let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            throw PublishingError.message("Invalid signing input.")
        }
        defer { secp256k1_context_destroy(ctx) }
        var pair = secp256k1_keypair()
        var random = [UInt8](repeating: 0, count: 32)
        var signature = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &random) == errSecSuccess,
              secp256k1_context_randomize(ctx, random) == 1,
              secp256k1_keypair_create(ctx, &pair, secret) == 1,
              secp256k1_schnorrsig_sign32(ctx, &signature, hash, &pair, random) == 1 else {
            throw PublishingError.message("Could not sign this draft.")
        }
        var publicKey = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(ctx, &publicKey, nil, &pair) == 1,
              secp256k1_schnorrsig_verify(ctx, signature, hash, 32, &publicKey) == 1 else {
            throw PublishingError.message("Signature verification failed.")
        }
        return hex(signature)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

struct PublishedEvent: Codable {
    let id: String
    let pubkey: String
    let created_at: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String
}

@MainActor
final class NostrPublisher: ObservableObject {
    static let shared = NostrPublisher()
    @Published var busy = false
    @Published var status: String?
    // User-editable relays preserve portability. No dependency on an account server.
    static var relayText: String {
        get { UserDefaults.standard.string(forKey: "slowclaw.nostr.relays") ?? "wss://relay.damus.io\nwss://nos.lol" }
        set { UserDefaults.standard.set(newValue, forKey: "slowclaw.nostr.relays") }
    }

    func publish(draftKey: String, content: String, title: String, article: Bool) async throws -> String {
        guard !busy else { throw PublishingError.message("A publication is already in progress.") }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 60_000 else {
            throw PublishingError.message("The draft is empty or too large.")
        }
        let relays = Array(Set(Self.relayText.split(whereSeparator: { $0.isWhitespace }).map(String.init))).sorted()
        guard !relays.isEmpty, relays.count <= 5, relays.allSatisfy({
            guard let url = URL(string: $0) else { return false }
            return url.scheme == "wss" && url.host != nil && url.user == nil && url.password == nil
        }) else { throw PublishingError.message("Enter one to five wss:// relay addresses.") }
        busy = true
        status = "Signing your reviewed draft…"
        defer { busy = false }
        let secret = try NostrIdentity.secret()
        let pubkey = try NostrIdentity.publicKey(secret)
        let cacheKey = "slowclaw.nostr.event." + draftKey
        let kind = article ? 30023 : 1
        let event: PublishedEvent
        if let cached = UserDefaults.standard.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode(PublishedEvent.self, from: cached),
           saved.content == text, saved.pubkey == pubkey, saved.kind == kind,
           (!article || saved.tags.contains(["title", title])) {
            event = saved // Retry the same event ID after a timeout or relaunch.
        } else {
            let created = Int(Date().timeIntervalSince1970)
            let tags = article ? [["d", draftKey], ["title", title], ["published_at", String(created)]] : []
            let canonical = try JSONSerialization.data(withJSONObject: [0, pubkey, created, kind, tags, text], options: [.withoutEscapingSlashes])
            let hash = Array(SHA256.hash(data: canonical))
            event = PublishedEvent(id: NostrIdentity.hex(hash), pubkey: pubkey,
                created_at: created, kind: kind, tags: tags, content: text,
                sig: try NostrIdentity.sign(hash: hash, secret: secret))
            UserDefaults.standard.set(try JSONEncoder().encode(event), forKey: cacheKey)
        }
        let encoded = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let frame = try JSONSerialization.data(withJSONObject: ["EVENT", object], options: [.withoutEscapingSlashes])
        guard let wire = String(data: frame, encoding: .utf8) else { throw PublishingError.message("Could not encode event.") }
        status = "Waiting for relay acknowledgement…"
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for relay in relays {
                group.addTask { await Self.send(wire, id: event.id, relay: relay) }
            }
            var count = 0
            for await ok in group { if ok { count += 1 } }
            return count
        }
        guard accepted > 0 else {
            status = "No relay confirmed publication. Your draft and signed event are saved; retry safely."
            throw PublishingError.message(status!)
        }
        status = "Published · accepted by \(accepted) relay\(accepted == 1 ? "" : "s")"
        UserDefaults.standard.set(event.id, forKey: "slowclaw.nostr.receipt." + draftKey)
        return event.id
    }

    nonisolated private static func send(_ wire: String, id: String, relay: String) async -> Bool {
        guard let url = URL(string: relay) else { return false }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 128_000
        socket.resume()
        // Closing the socket interrupts a stalled receive; task-group cancellation alone doesn't.
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
        do {
            try await socket.send(.string(wire))
            for _ in 0..<20 {
                let received = try await socket.receive()
                let data: Data
                switch received {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: return false
                }
                guard let frame = try JSONSerialization.jsonObject(with: data) as? [Any], frame.count >= 3,
                      frame[0] as? String == "OK", frame[1] as? String == id else { continue }
                return frame[2] as? Bool == true
            }
        } catch { return false }
        return false
    }
}
