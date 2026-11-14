import Foundation
import Network
import CryptoKit

/// A minimal HTTP/1.1 request, parsed from raw bytes. Kept separate so it can be tested.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    enum Parse { case incomplete, invalid, done(HTTPRequest, consumed: Int) }

    static let maxSize = 2_000_000

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 32_000 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxSize else { return .invalid }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        let target = String(start[1])
        let comps = URLComponents(string: "http://local" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(start[0]), path: comps?.path ?? target, query: query,
                                  headers: headers, body: Data(body))
        return .done(request, consumed: data.distance(from: data.startIndex, to: bodyStart) + length)
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(["error": message], status: status) }

    func serialized() -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Content-Security-Policy: default-src 'self'; img-src 'self' data: https://i.ytimg.com; style-src 'self' 'unsafe-inline'; connect-src 'self'\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Serves the website from this iPhone over the local network, so a computer's browser can
/// read and tend journals without anything going to the cloud. A browser gets in only after
/// the phone scans the QR code the browser shows. Runs while SlowClaw is open.
@MainActor
final class LocalServer: ObservableObject {
    static let shared = LocalServer()
    static let port: UInt16 = 8787

    @Published private(set) var running = false
    @Published private(set) var addresses: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var pairedCount = 0

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "slowclaw.local.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "slowclaw.local.enabled")
            objectWillChange.send()
            newValue ? start() : stop()
        }
    }

    private var listener: NWListener?
    private struct Pairing { var secretHash: String; var created: Date; var token: String? }
    private var pairings: [String: Pairing] = [:]
    /// SHA-256 hashes of browser tokens. The tokens themselves are only held by browsers.
    private var tokenHashes: Set<String> {
        didSet { UserDefaults.standard.set(Array(tokenHashes), forKey: "slowclaw.local.tokens"); pairedCount = tokenHashes.count }
    }

    init() {
        tokenHashes = Set(UserDefaults.standard.stringArray(forKey: "slowclaw.local.tokens") ?? [])
        pairedCount = tokenHashes.count
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        error = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.running = true; self.addresses = Self.localAddresses()
                    case .failed(let e): self.running = false; self.error = "Could not start: \(e.localizedDescription)"; self.listener = nil
                    case .cancelled: self.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            self.error = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        pairings = [:]
    }

    func forgetBrowsers() {
        tokenHashes = []
    }

    /// Called after the phone scans the code a browser shows.
    func approve(pairing id: String) throws {
        guard running else {
            throw NostrIdentity.Failure(message: "Turn on “View on a computer” in Settings first, then scan again.")
        }
        guard var p = pairings[id], p.created > Date().addingTimeInterval(-180) else {
            throw NostrIdentity.Failure(message: "That code has expired. Reload the page on your computer.")
        }
        let token = Hex.random(32)
        p.token = token
        pairings[id] = p
        tokenHashes.insert(Self.hash(token))
    }

    private static func hash(_ s: String) -> String { Hex.string(Array(SHA256.hash(data: Data(s.utf8)))) }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
        // Drop idle connections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequest.parse(buffer) {
                case .incomplete where !complete && error == nil && buffer.count < HTTPRequest.maxSize + 32_000:
                    self.receive(connection, buffer: buffer)
                case let .done(request, _):
                    let response = self.handle(request)
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
                default:
                    connection.send(content: HTTPResponse.error(400, "bad request").serialized(),
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    // MARK: - Routes

    func handle(_ r: HTTPRequest) -> HTTPResponse {
        switch (r.method, r.path) {
        case ("GET", "/mode.js"):
            return HTTPResponse(status: 200, contentType: "text/javascript", body: Data("window.SLOWCLAW_MODE = 'local';\n".utf8))
        case ("POST", "/api/pair/start"):
            return pairStart(r)
        case ("POST", "/api/pair/poll"):
            return pairPoll(r)
        case (_, let p) where p.hasPrefix("/api/"):
            guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer "),
                  tokenHashes.contains(Self.hash(String(auth.dropFirst(7)))) else {
                return .error(401, "pair this browser first")
            }
            return api(r)
        case ("GET", let p) where p.hasPrefix("/news-image/"):
            let id = String(p.dropFirst("/news-image/".count))
            guard id.hasPrefix("card_"), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  let data = try? Data(contentsOf: NewsStore.imageURL(for: id)) else { return .error(404, "not found") }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: data)
        case ("GET", _):
            return file(r.path)
        default:
            return .error(405, "method not allowed")
        }
    }

    private func bodyJSON(_ r: HTTPRequest) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
    }

    private func pairStart(_ r: HTTPRequest) -> HTTPResponse {
        guard let v = bodyJSON(r), let id = v["id"] as? String, let secret = v["secret"] as? String,
              id.count == 32, secret.count == 64, Hex.bytes(id) != nil, Hex.bytes(secret) != nil else {
            return .error(400, "invalid pairing request")
        }
        pairings = pairings.filter { $0.value.created > Date().addingTimeInterval(-180) }
        guard pairings.count < 8 else { return .error(429, "too many pending codes") }
        pairings[id.lowercased()] = Pairing(secretHash: Self.hash(secret.lowercased()), created: Date(), token: nil)
        return .json(["ok": true, "expires": Date().addingTimeInterval(180).timeIntervalSince1970])
    }

    private func pairPoll(_ r: HTTPRequest) -> HTTPResponse {
        guard let v = bodyJSON(r), let id = (v["id"] as? String)?.lowercased(), let secret = (v["secret"] as? String)?.lowercased(),
              let p = pairings[id], p.secretHash == Self.hash(secret) else {
            return .error(404, "expired")
        }
        guard let token = p.token else { return .json(["pending": true]) }
        pairings[id] = nil
        return .json(["token": token, "device": UIDeviceName.current])
    }

    private func api(_ r: HTTPRequest) -> HTTPResponse {
        let store = Store.shared
        switch (r.method, r.path) {
        case ("GET", "/api/data"):
            let book = BookStore.shared.path.map { BookStore.row(from: $0, user: nil) }
            let news = NewsStore.shared.cards.map { c -> [String: Any] in
                ["id": c.id, "topic": c.topic, "headline": c.headline, "summary": c.summary,
                 "has_image": c.hasImage, "sources": c.sourcesLabel,
                 "newest": c.newest.map { CloudDates.format($0) as Any } ?? NSNull(),
                 "articles": c.articles.map { ["title": $0.title, "source": $0.source, "url": $0.url] }]
            }
            return .json([
                "journals": store.visibleJournals.filter { $0.status == .ready }.map { CloudSync.row(from: $0, user: nil) },
                "spaces": store.visibleSpaces.map { CloudSync.row(from: $0, user: nil) },
                "space_items": store.items.filter { !$0.deleted }.map { CloudSync.row(from: $0, user: nil) },
                "book_nodes": book,
                "news": news,
                "videos": Dictionary(grouping: VideoStore.shared.videos, by: \.theme).map { theme, vs -> [String: Any] in
                    ["label": theme, "videos": vs.map { ["id": $0.id, "title": $0.title, "channel": $0.channel] }]
                },
                "reads": Dictionary(grouping: ReadsStore.shared.articles, by: \.theme).map { theme, list -> [String: Any] in
                    ["label": theme,
                     "articles": list.map { ["id": $0.id, "title": $0.title, "author": $0.author, "summary": $0.summary,
                                             "minutes": $0.minutes, "published": CloudDates.format($0.published),
                                             "url": $0.link?.absoluteString ?? ""] as [String: Any] }]
                },
                "device": UIDeviceName.current,
            ])
        case ("POST", "/api/save"):
            guard let v = bodyJSON(r), let table = v["table"] as? String, let row = v["row"] as? [String: Any] else {
                return .error(400, "invalid save")
            }
            guard let saved = save(table: table, row: row) else { return .error(400, "could not save") }
            return .json(["row": saved])
        case ("POST", "/api/signout"):
            if let auth = r.headers["authorization"] { tokenHashes.remove(Self.hash(String(auth.dropFirst(7)))) }
            return .json(["ok": true])
        default:
            return .error(404, "not found")
        }
    }

    /// Applies an edit from the browser as if it were made on the phone.
    private func save(table: String, row r: [String: Any]) -> [String: Any]? {
        let store = Store.shared
        guard let id = r["id"] as? String, (1...200).contains(id.count) else { return nil }
        let deleted = r["deleted"] as? Bool ?? false
        switch table {
        case "journals":
            let title = String((r["title"] as? String ?? "").prefix(300))
            let body = r["body"] as? String ?? ""
            let spaceID = r["space_id"] as? String
            if store.journal(id) != nil {
                if deleted { store.deleteJournal(id) } else {
                    store.updateJournal(id) { $0.title = title; $0.body = body; $0.spaceID = spaceID; if spaceID != nil { $0.organized = true } }
                }
            } else if !deleted {
                store.addJournal(title: title, body: body, id: id)
                if let spaceID { store.updateJournal(id) { $0.spaceID = spaceID; $0.organized = true } }
                Processor.shared.kick()
            }
            return store.journal(id).map { CloudSync.row(from: $0, user: nil) }
        case "spaces":
            let name = String((r["name"] as? String ?? "").prefix(80))
            if store.space(id) != nil {
                if deleted { store.deleteSpace(id) } else { store.updateSpace(id) { $0.name = name } }
                return store.spaces.first { $0.id == id }.map { CloudSync.row(from: $0, user: nil) }
            } else if !deleted, !name.isEmpty {
                let s = store.addSpace(name: name)
                return CloudSync.row(from: s, user: nil)
            }
            return nil
        case "space_items":
            let text = r["text"] as? String ?? ""
            let done = r["done"] as? Bool ?? false
            if store.items.contains(where: { $0.id == id }) {
                store.updateItem(id) { $0.text = String(text.prefix(500)); $0.done = done; $0.deleted = deleted }
                return store.items.first { $0.id == id }.map { CloudSync.row(from: $0, user: nil) }
            } else if !deleted, let spaceID = r["space_id"] as? String, store.space(spaceID) != nil,
                      let kind = ItemKind(rawValue: r["kind"] as? String ?? "") {
                return store.addItem(spaceID: spaceID, kind: kind, text: text).map { CloudSync.row(from: $0, user: nil) }
            }
            return nil
        default:
            return nil
        }
    }

    private func file(_ path: String) -> HTTPResponse {
        guard let root = Bundle.main.url(forResource: "web", withExtension: nil) else { return .error(404, "not found") }
        let clean = path == "/" ? "index.html" : String(path.dropFirst())
        guard !clean.contains(".."), !clean.hasPrefix("/"),
              clean.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) else { return .error(404, "not found") }
        let url = root.appendingPathComponent(clean)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: url) else { return .error(404, "not found") }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript", "css": "text/css",
                     "svg": "image/svg+xml", "png": "image/png", "json": "application/json"]
        return HTTPResponse(status: 200, contentType: types[url.pathExtension] ?? "application/octet-stream", body: data)
    }

    // MARK: - Addresses

    /// IPv4 addresses on Wi-Fi / Ethernet that a computer on the same network can reach.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                let name = String(cString: p.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        out.append(String(cString: host))
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return out
    }
}

enum UIDeviceName {
    @MainActor static var current: String { "SlowClaw on iPhone" }
}
