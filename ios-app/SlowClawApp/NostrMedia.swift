import Foundation
import CryptoKit

/// Blossom BUD-02/11: only an explicitly reviewed studio export is uploaded.
/// Authorization is scoped to its hash, server and a five-minute lifetime.
enum NostrMedia {
    static var server: String {
        get { UserDefaults.standard.string(forKey: "slowclaw.nostr.media-server") ?? "https://blossom.primal.net" }
        set { UserDefaults.standard.set(newValue, forKey: "slowclaw.nostr.media-server") }
    }
    struct Descriptor: Decodable {
        let url: URL
        let sha256: String
        let size: Int
        let type: String
        func validate(hash: String, bytes: Int, mime: String) throws -> URL {
            guard sha256 == hash, size == bytes, type == mime,
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw PublishingError.message("The media server returned an invalid upload receipt.")
            }
            return url
        }
    }
    static func endpoint(_ server: String) throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw PublishingError.message("Enter an HTTPS Blossom server address without a path.")
        }
        return url.appendingPathComponent("upload")
    }
    static func authorization(hash: String, host: String, secret: [UInt8], now: Int) throws -> String {
        let pubkey = try NostrIdentity.publicKey(secret)
        let tags = [["t", "upload"], ["x", hash], ["server", host.lowercased()], ["expiration", String(now + 300)]]
        let content = "Upload this reviewed SlowClaw creation"
        let canonical = try JSONSerialization.data(withJSONObject: [0, pubkey, now, 24242, tags, content], options: [.withoutEscapingSlashes])
        let digest = Array(SHA256.hash(data: canonical))
        let event = PublishedEvent(id: NostrIdentity.hex(digest), pubkey: pubkey, created_at: now, kind: 24242,
            tags: tags, content: content, sig: try NostrIdentity.sign(hash: digest, secret: secret))
        return "Nostr " + (try JSONEncoder().encode(event)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func upload(_ file: URL, server: String) async throws -> URL {
        let destination = try endpoint(server)
        let mime: String
        switch file.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "mp4": mime = "video/mp4"
        case "m4a": mime = "audio/mp4"
        default: throw PublishingError.message("This export format cannot be published.")
        }
        let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard file.isFileURL, metadata.isRegularFile == true, let bytes = metadata.fileSize,
              bytes > 0, bytes <= 100_000_000 else { throw PublishingError.message("Choose an export smaller than 100 MB.") }
        let hash = try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        try Task.checkCancellation()
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"; request.timeoutInterval = 120
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
        request.setValue(hash, forHTTPHeaderField: "X-SHA-256")
        request.setValue(try authorization(hash: hash, host: destination.host!, secret: NostrIdentity.secret(), now: Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: NoUploadRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, [200, 201].contains(http.statusCode) else {
            throw PublishingError.message("Media upload failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the media server or try another; nothing was posted to Nostr.")
        }
        return try JSONDecoder().decode(Descriptor.self, from: data).validate(hash: hash, bytes: bytes, mime: mime)
    }
}
private final class NoUploadRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
