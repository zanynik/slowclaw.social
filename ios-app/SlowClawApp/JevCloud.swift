import Foundation
import CryptoKit
import AuthenticationServices
import UIKit
import Security

@MainActor
final class JevCloud: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = JevCloud()
    static let origin = "https://slowclaw-jev.zanynik.chatgpt.site"
    private var auth: ASWebAuthenticationSession?
    private let session = URLSession(configuration: .ephemeral)
    private let account = "slowclaw.jev.device.v1"
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fingerprint(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure(message: "Could not start a secure connection.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.slowclaw.app", kSecAttrAccount as String: account] }
    private var token: String? {
        var query = keyQuery; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    var connected: Bool { token != nil }
    private func saveToken(_ value: String) throws {
        SecItemDelete(keyQuery as CFDictionary)
        var query = keyQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure(message: "Could not save this device’s connection.") }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func connect() async throws {
        guard auth == nil else { return }
        defer { auth = nil }
        let verifier = try random(), state = try random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = URL(string: Self.origin + "/connect?challenge=\(challenge)&state=\(state)")!
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let flow = ASWebAuthenticationSession(url: url, callbackURLScheme: "slowclaw") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? Failure(message: "Connection cancelled.")) }
            }
            flow.presentationContextProvider = self
            auth = flow
            if !flow.start() { auth = nil; continuation.resume(throwing: Failure(message: "Could not open sign-in.")) }
        }
        auth = nil
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == "slowclaw", callback.host == "jev-auth", values.first(where: { $0.name == "state" })?.value == state,
              let code = values.first(where: { $0.name == "code" })?.value else { throw Failure(message: "The connection could not be verified.") }
        struct Exchange: Decodable { let token: String }
        let result: Exchange = try await request("exchange", body: ["code": code, "verifier": verifier], authenticated: false)
        guard result.token.count == 64, result.token.allSatisfy({ $0.isHexDigit }) else { throw Failure(message: "Invalid device connection.") }
        try saveToken(result.token)
    }
    func disconnect() async {
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
    private func request<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: Self.origin + "/api/" + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token else { throw Failure(message: "Connect to Jev in Personal memory first.") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Jev could not complete the request. Please retry."
            throw Failure(message: message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
