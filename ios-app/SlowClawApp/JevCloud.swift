import Foundation
import CryptoKit
import Security

@MainActor
final class JevCloud {
    static let shared = JevCloud()
    static let origin = "https://slowclaw-jev.zanynik.chatgpt.site"
    private let session = URLSession(configuration: .ephemeral)
    private let account = "slowclaw.jev.device.v1"
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fingerprint(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.slowclaw.app", kSecAttrAccount as String: account] }
    private var token: String? {
        var query = keyQuery; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    var connected: Bool { token != nil }
    private var testerConnection: Task<Void, Error>?
    private struct TesterSession: Decodable { let token: String }
    func connectForTesting() async throws {
        if connected { return }
        if let testerConnection { try await testerConnection.value; return }
        let work = Task { @MainActor in
            let session: TesterSession = try await request("testflight", body: [:], authenticated: false)
            guard session.token.count == 64, session.token.allSatisfy({ $0.isHexDigit }) else {
                throw Failure(message: "Could not connect. Please try again.")
            }
            try saveToken(session.token)
        }
        testerConnection = work
        defer { testerConnection = nil }
        try await work.value
    }
    private func saveToken(_ value: String) throws {
        SecItemDelete(keyQuery as CFDictionary)
        var query = keyQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure(message: "Could not save this device’s connection.") }
    }
    func disconnect() async {
        testerConnection?.cancel()
        let oldToken = token
        SecItemDelete(keyQuery as CFDictionary)
        guard let oldToken else { return }
        var request = URLRequest(url: URL(string: Self.origin + "/api/disconnect")!)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("Bearer " + oldToken, forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }
    func memory(_ text: String) async throws -> JevMemory.Answer {
        let answer: JevMemory.Answer = try await request("memory", body: ["text": text])
        guard answer.valid else { throw Failure(message: "Jev returned an invalid memory decision.") }
        return answer
    }
    struct Match: Decodable { let id: String; let score: Double }
    func reading(_ text: String, memories: [JevMemory.Passage]) async throws -> [Match] {
        struct Result: Decodable { let matches: [Match]; let version: String }
        let result: Result = try await request("reading", body: ["text": text, "memories": memories.map { ["id": $0.id, "text": $0.text] }])
        guard result.version == JevMemory.version, result.matches.count == memories.count,
              Set(result.matches.map(\.id)) == Set(memories.map(\.id)),
              result.matches.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }) else { throw Failure(message: "Jev returned an invalid reading decision.") }
        return result.matches
    }
    private struct ErrorBody: Decodable { let error: String }
    private func request<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true, retryConnection: Bool = true) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: Self.origin + "/api/" + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token else { throw Failure(message: "Connecting to Jev. Please try again shortly.") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if authenticated, retryConnection, (response as? HTTPURLResponse)?.statusCode == 401 {
            SecItemDelete(keyQuery as CFDictionary)
            try await connectForTesting()
            return try await self.request(path, body: body, retryConnection: false)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Jev could not complete the request. Please retry."
            throw Failure(message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
