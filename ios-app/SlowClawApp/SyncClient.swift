// SyncClient.swift — LAN sync transport + orchestrator (iOS = client).
//
// Desktop is the server (renders the QR + runs the listener); iOS scans the QR
// and drives the exchange. This file owns the wire (URLSession) + the sync
// flow; the manifest/diff/apply logic lives in the Zig core via the
// SlowClawSqliteMemory overlay (AGENTS.md §6.3 — shells own transport).
//
// See windows-app/PROTOCOL.md for the wire contract.

import Foundation

/// The pairing payload decoded from the QR code.
struct SyncPairingPayload: Decodable {
    let v: Int
    let host: String
    let port: Int
    let token: String
    let name: String
}

/// One step of progress, surfaced to SyncView.
struct SyncProgress: Equatable {
    var phase: String
    var pulled: Int = 0
    var pushed: Int = 0
    var total: Int = 0
}

enum SyncClientError: Error, LocalizedError {
    case invalidPayload
    case server(Int, String)  // status code + body
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid QR code."
        case .server(let code, let body): return "Server error \(code): \(body)"
        case .decode(let msg): return "Decode error: \(msg)"
        }
    }
}

/// Drives one sync session against a paired desktop server.
final class SyncClient {
    private let payload: SyncPairingPayload
    private let memory: SlowClawSqliteMemory
    private let session: URLSession
    private let baseURL: URL

    /// `payload` is the decoded QR content; `memory` is the app's open store.
    init(payload: SyncPairingPayload, memory: SlowClawSqliteMemory) {
        self.payload = payload
        self.memory = memory
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        self.baseURL = URL(string: "http://\(payload.host):\(payload.port)")!
    }

    /// Run the full sync exchange until the diff is empty. Calls `onProgress`
    /// as entries move. Throws on any server/decode error.
    func run(onProgress: @escaping (SyncProgress) -> Void) async throws {
        var progress = SyncProgress(phase: "Exchanging manifests…")
        onProgress(progress)

        // 1. Build our manifest + fetch the server's, then diff.
        let localManifest = try memory.syncBuildManifest(mediaRoot: Self.documentsPath)
        let remoteManifest = try await getManifest()
        let diffJSON = try memory.syncDiff(local: localManifest, remote: remoteManifest)
        let diff = try decodeDiff(diffJSON)

        let toPull = diff.toPull
        let toPush = diff.toPush
        progress.total = toPull.count + toPush.count
        progress.phase = progress.total == 0
            ? "Already in sync."
            : "Syncing \(progress.total) item\(progress.total == 1 ? "" : "s")…"
        onProgress(progress)

        // 2. Pull: fetch each entry + its media from the server, apply locally.
        for key in toPull {
            try await pullEntry(key: key)
            progress.pulled += 1
            onProgress(progress)
        }

        // 3. Push: send each entry + its media to the server.
        for key in toPush {
            try await pushEntry(key: key)
            progress.pushed += 1
            onProgress(progress)
        }

        progress.phase = progress.total == 0 ? "Already in sync." : "Done."
        onProgress(progress)
    }

    // MARK: - Wire (URLSession)

    private func getManifest() async throws -> String {
        let (data, response) = try await send(.GET, "/v1/manifest")
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func pullEntry(key: String) async throws {
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let (data, _) = try await send(.GET, "/v1/entry?key=\(escaped)")
        guard let json = String(data: data, encoding: .utf8) else {
            throw SyncClientError.decode("entry body not UTF-8")
        }
        // Apply via the core (wrap as a one-element array, as the server does).
        try memory.syncApplyEntries("[\(json)]")

        // If the entry references media, pull + save the file.
        if let entry = try decodeTransferEntry(json), let mediaPath = entry.media_url, !mediaPath.isEmpty {
            try await pullMedia(path: mediaPath)
        }
    }

    private func pullMedia(path: String) async throws {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let (data, _) = try await send(.GET, "/v1/media?path=\(escaped)")
        try saveMedia(path: path, data: data)
    }

    private func pushEntry(key: String) async throws {
        guard let entry = try memory.syncEntryForTransfer(key: key) else { return }
        let json = encodeTransferEntry(entry)
        let body = json.data(using: .utf8) ?? Data()
        _ = try await sendBody(.POST, "/v1/entry", body: body)
        if let mediaPath = entry.mediaURL, !mediaPath.isEmpty {
            try await pushMedia(path: mediaPath)
        }
    }

    private func pushMedia(path: String) async throws {
        let url = mediaURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        _ = try await sendBody(.POST, "/v1/media?path=\(escaped)", body: data)
    }

    // MARK: - Low-level HTTP

    private enum Method: String { case GET, POST }

    private func send(_ method: Method, _ path: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method.rawValue
        req.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw SyncClientError.server(0, "no response")
        }
        if http.statusCode == 401 {
            let body = String(data: data, encoding: .utf8) ?? "unauthorized"
            throw SyncClientError.server(401, body)
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncClientError.server(http.statusCode, body)
        }
        return (data, http)
    }

    private func sendBody(_ method: Method, _ path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method.rawValue
        req.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw SyncClientError.server(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncClientError.server(http.statusCode, body)
        }
        return (data, http)
    }

    // MARK: - Media filesystem

    private static var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
    }

    private func mediaURL(for relativePath: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(relativePath)
    }

    private func saveMedia(path: String, data: Data) throws {
        let url = mediaURL(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Diff/entry JSON decoding (small Codable shapes)

    private struct DiffDTO: Decodable {
        let to_pull: [String]
        let to_push: [String]
    }
    private func decodeDiff(_ json: String) throws -> DiffDTO {
        guard let data = json.data(using: .utf8) else { throw SyncClientError.decode("diff not UTF-8") }
        do {
            return try JSONDecoder().decode(DiffDTO.self, from: data)
        } catch {
            throw SyncClientError.decode("diff: \(error)")
        }
    }

    private struct TransferEntryDTO: Decodable {
        let media_url: String?
    }
    private func decodeTransferEntry(_ json: String) throws -> TransferEntryDTO? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TransferEntryDTO.self, from: data)
    }

    /// Hand-encode a TransferEntry JSON for POST /v1/entry (the core's store
    /// upserts on key; only the sync-relevant fields need to cross the wire).
    private func encodeTransferEntry(_ e: SlowClawMemoryEntry) -> String {
        func jstr(_ s: String) -> String {
            // Minimal JSON string escaping (matches the Zig core's writer).
            var out = "\""
            for ch in s {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out + "\""
        }
        var parts: [String] = []
        parts.append("\"key\":\(jstr(e.key))")
        parts.append("\"content\":\(jstr(e.content))")
        parts.append("\"category\":\(jstr(e.category))")
        parts.append("\"updated_at\":\(jstr(e.timestamp))")
        if let s = e.source { parts.append("\"source\":\(jstr(s))") }
        if let m = e.mediaURL { parts.append("\"media_url\":\(jstr(m))") }
        return "{\(parts.joined(separator: ","))}"
    }
}
