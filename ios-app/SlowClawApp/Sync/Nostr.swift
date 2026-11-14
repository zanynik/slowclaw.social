import Foundation
import CryptoKit
import Security
import libsecp256k1

/// The phone's Nostr identity. The secret key is generated on this iPhone and kept in
/// the Keychain, synced through iCloud Keychain (end-to-end encrypted) so a new iPhone
/// keeps the same identity. It never goes to the cloud, the website or the logs.
enum NostrIdentity {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Item written by builds up to 0.2 (this device only). Read once and copied forward.
    private static let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.slowclaw.nostr",
        kSecAttrAccount as String: "publishing-key",
    ]
    private static let currentQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.slowclaw.nostr",
        kSecAttrAccount as String: "identity",
        kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPublicKey: String?

    // MARK: - Key storage

    /// Loads the key, migrating the legacy item or creating a new key the first time.
    static func secret() throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        if let bytes = read(currentQuery) { return bytes }
        if let old = read(legacyQuery) {
            try store(old)
            return old
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        // Retry until the bytes form a valid secp256k1 secret (practically always first try).
        for _ in 0..<8 {
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw Failure(message: "Secure random generation failed.")
            }
            if (try? publicKey(for: bytes)) != nil {
                try store(bytes)
                return bytes
            }
        }
        throw Failure(message: "Could not create a Nostr key.")
    }

    /// Replaces the identity with a key restored from a backup (nsec or hex).
    static func restore(_ input: String) throws {
        guard let bytes = Bech32.decodeSecret(input) else {
            throw Failure(message: "That is not a valid nsec backup key.")
        }
        _ = try publicKey(for: bytes)
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(currentQuery as CFDictionary)
        try store(bytes)
        cachedPublicKey = nil
    }

    private static func read(_ query: [String: Any]) -> [UInt8]? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return Array(data)
    }

    private static func store(_ bytes: [UInt8]) throws {
        var item = currentQuery
        item[kSecValueData as String] = Data(bytes)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Failure(message: "Could not save the Nostr key securely (\(status)).")
        }
    }

    // MARK: - Public identity

    static func publicKeyHex() throws -> String {
        if let cached = cachedPublicKey { return cached }
        let pk = try publicKey(for: secret())
        cachedPublicKey = pk
        return pk
    }

    static var npub: String? {
        guard let hex = try? publicKeyHex(), let bytes = Hex.bytes(hex) else { return nil }
        return Bech32.encode(bytes, prefix: "npub")
    }

    static func nsec() throws -> String {
        Bech32.encode(try secret(), prefix: "nsec")
    }

    // MARK: - secp256k1 (BIP-340 Schnorr)

    static func publicKey(for secret: [UInt8]) throws -> String {
        guard secret.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            throw Failure(message: "Invalid Nostr key.")
        }
        defer { secp256k1_context_destroy(ctx) }
        var pair = secp256k1_keypair()
        var xonly = secp256k1_xonly_pubkey()
        var out = [UInt8](repeating: 0, count: 32)
        guard secp256k1_keypair_create(ctx, &pair, secret) == 1,
              secp256k1_keypair_xonly_pub(ctx, &xonly, nil, &pair) == 1,
              secp256k1_xonly_pubkey_serialize(ctx, &out, &xonly) == 1 else {
            throw Failure(message: "Invalid Nostr key.")
        }
        return Hex.string(out)
    }

    static func sign(hash: [UInt8], secret: [UInt8]) throws -> String {
        guard hash.count == 32, secret.count == 32,
              let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            throw Failure(message: "Invalid signing input.")
        }
        defer { secp256k1_context_destroy(ctx) }
        var pair = secp256k1_keypair()
        var aux = [UInt8](repeating: 0, count: 32)
        var seed = [UInt8](repeating: 0, count: 32)
        var sig = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &aux) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, 32, &seed) == errSecSuccess,
              secp256k1_context_randomize(ctx, seed) == 1,
              secp256k1_keypair_create(ctx, &pair, secret) == 1,
              secp256k1_schnorrsig_sign32(ctx, &sig, hash, &pair, aux) == 1 else {
            throw Failure(message: "Could not sign.")
        }
        var xonly = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(ctx, &xonly, nil, &pair) == 1,
              secp256k1_schnorrsig_verify(ctx, sig, hash, 32, &xonly) == 1 else {
            throw Failure(message: "Signature check failed.")
        }
        return Hex.string(sig)
    }

    static func verify(signature: String, hash: [UInt8], publicKey: String) -> Bool {
        guard let sig = Hex.bytes(signature), sig.count == 64, hash.count == 32,
              let pk = Hex.bytes(publicKey), pk.count == 32,
              let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else { return false }
        defer { secp256k1_context_destroy(ctx) }
        var xonly = secp256k1_xonly_pubkey()
        guard secp256k1_xonly_pubkey_parse(ctx, &xonly, pk) == 1 else { return false }
        return secp256k1_schnorrsig_verify(ctx, sig, hash, 32, &xonly) == 1
    }

    // MARK: - Events (NIP-01) and HTTP auth (NIP-98)

    /// NIP-01 canonical serialization: [0, pubkey, created_at, kind, tags, content].
    static func serialize(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> Data {
        let array: [Any] = [0, pubkey, createdAt, kind, tags, content]
        return (try? JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes])) ?? Data()
    }

    static func eventID(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> [UInt8] {
        Array(SHA256.hash(data: serialize(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)))
    }

    static func signedEvent(kind: Int, tags: [[String]], content: String, createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> [String: Any] {
        let secret = try secret()
        let pubkey = try publicKey(for: secret)
        let id = eventID(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return ["id": Hex.string(id), "pubkey": pubkey, "created_at": createdAt, "kind": kind,
                "tags": tags, "content": content, "sig": try sign(hash: id, secret: secret)]
    }

    /// `Authorization` header value proving this phone sent exactly `body` to `url`.
    static func httpAuthorization(url: String, method: String = "POST", body: Data) throws -> String {
        let payload = Hex.string(Array(SHA256.hash(data: body)))
        let event = try signedEvent(kind: 27235, tags: [["u", url], ["method", method], ["payload", payload]], content: "")
        let json = try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes])
        return "Nostr " + json.base64EncodedString()
    }
}

enum Hex {
    static func string(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func string(_ data: Data) -> String { string(Array(data)) }

    static func bytes(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return string(bytes)
    }
}

/// NIP-19 bech32 (constant 1, not bech32m) for npub / nsec.
enum Bech32 {
    private static let charset: [Character] = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func encode(_ bytes: [UInt8], prefix: String) -> String {
        let data = convertBits(bytes, from: 8, to: 5, pad: true)
        let checksum = createChecksum(hrp: prefix, data: data)
        return prefix + "1" + String((data + checksum).map { charset[Int($0)] })
    }

    /// Accepts an nsec1… string or 64 hex characters.
    static func decodeSecret(_ input: String) -> [UInt8]? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 64, let bytes = Hex.bytes(value) { return bytes }
        return decode(value, prefix: "nsec")
    }

    static func decode(_ input: String, prefix: String) -> [UInt8]? {
        guard input == input.lowercased() || input == input.uppercased() else { return nil }
        let value = input.lowercased()
        guard value.hasPrefix(prefix + "1") else { return nil }
        let chars = value.dropFirst(prefix.count + 1)
        let words = chars.compactMap { charset.firstIndex(of: $0).map(UInt8.init) }
        guard words.count == chars.count, words.count > 6,
              polymod(hrpExpand(prefix) + words) == 1 else { return nil }
        let bytes = convertBits(Array(words.dropLast(6)), from: 5, to: 8, pad: false)
        return bytes.count == 32 ? bytes : nil
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 where (top >> i) & 1 != 0 { chk ^= gen[i] }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 }
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let mod = polymod(hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]) ^ 1
        return (0..<6).map { UInt8((mod >> UInt32(5 * (5 - $0))) & 31) }
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8] {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        let maxAcc = (1 << (from + to - 1)) - 1
        for value in data {
            if Int(value) >> from != 0 { return [] }
            acc = ((acc << from) | Int(value)) & maxAcc
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || (acc << (to - bits)) & maxv != 0 {
            return []
        }
        return out
    }
}
