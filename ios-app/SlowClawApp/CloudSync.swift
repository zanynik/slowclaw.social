import Foundation
import CryptoKit
import Security

/// Text-only sync with Supabase (journals, spaces, items, book passages). Audio never
/// leaves the phone. Last edit wins per record; the server rejects older writes.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    // Public client configuration (safe to ship; access is enforced by row-level security).
    static let projectURL = "https://docmtelcjyvfyjlujibb.supabase.co"
    static let publishableKey = "sb_publishable_w9ZdQLfwKjo56BDs24ziag_tt2_X_Z3"

    struct Session: Codable {
        var access: String
        var refresh: String
        var expires: Double
        var userID: String
        var email: String
    }

    @Published private(set) var session: Session?
    @Published private(set) var syncing = false
    @Published private(set) var lastSynced: Date?
    @Published var status: String?

    private let store = Store.shared
    private var pushTask: Task<Void, Never>?
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.slowclaw.supabase",
        kSecAttrAccount as String: "session",
    ]

    init() {
        var q = Self.keychain
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
        if let t = UserDefaults.standard.object(forKey: "slowclaw.sync.last") as? Double {
            lastSynced = Date(timeIntervalSince1970: t)
        }
        store.onLocalChange = { [weak self] in self?.schedulePush() }
    }

    var signedIn: Bool { session != nil }

    /// Accounts created from the phone's Nostr key have a placeholder email.
    var accountLabel: String {
        guard let s = session else { return "" }
        return s.email.hasSuffix("@phone.slowclaw.invalid") ? "This iPhone's key" : s.email
    }

    // MARK: - Auth

    struct CloudError: LocalizedError {
        let message: String
        /// True when the auth server answered 400/401/403 (as opposed to a network failure).
        var rejected = false
        var errorDescription: String? { message }
    }

    func signIn(email: String, password: String) async throws {
        let v = try await authRequest(path: "/auth/v1/token?grant_type=password",
                                      body: ["email": email, "password": password])
        try adopt(v, fallbackEmail: email)
        // A new sign-in pushes everything once so the cloud has a full copy.
        store.markAllDirty()
        BookStore.shared.markAllDirty()
        resetCursors()
        await linkIdentity()
        await sync()
    }

    /// Returns true when a session was created immediately (no email confirmation needed).
    func signUp(email: String, password: String) async throws -> Bool {
        let v = try await authRequest(path: "/auth/v1/signup", body: ["email": email, "password": password])
        if v["access_token"] != nil {
            try adopt(v, fallbackEmail: email)
            store.markAllDirty()
            BookStore.shared.markAllDirty()
            resetCursors()
            await linkIdentity()
            await sync()
            return true
        }
        return false
    }

    // MARK: - Nostr key sign-in

    private var functionsURL: String { Self.projectURL + "/functions/v1/" }

    /// Calls an edge function. `nostr` signs the exact body with the phone's key (NIP-98).
    private func function(_ name: String, _ value: [String: Any], nostr: Bool = false, bearer: String? = nil) async throws -> [String: Any] {
        let url = functionsURL + name
        let body = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if nostr {
            r.setValue(try NostrIdentity.httpAuthorization(url: url, body: body), forHTTPHeaderField: "Authorization")
        } else if let bearer {
            r.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        r.httpBody = body
        let (data, response) = try await http.data(for: r)
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = v["error"] as? String {
            let known: [String: String] = [
                "QR_EXPIRED": "That code has expired. Refresh the page for a new one.",
                "PHONE_PROOF_INVALID": "This iPhone's clock looks wrong. Check Date & Time in Settings.",
                "SIGN_IN_REQUIRED": "Please sign in again.",
            ]
            throw CloudError(message: known[error] ?? "The server said: \(error)", rejected: true)
        }
        guard (200..<300).contains(code) else { throw CloudError(message: "Request failed (\(code)).") }
        return v
    }

    /// Signs in with the phone's Nostr key: no email or password. The first time this
    /// creates an account that belongs to the key.
    func signInWithKey() async throws {
        let v = try await function("cloud-login", ["action": "login", "nonce": Hex.random(32)], nostr: true)
        try adopt(v, fallbackEmail: "")
        UserDefaults.standard.set(session?.userID, forKey: linkedKey)
        store.markAllDirty()
        BookStore.shared.markAllDirty()
        resetCursors()
        await sync()
    }

    private var linkedKey: String { "slowclaw.nostr.linked-account" }

    /// Ties the phone's key to the signed-in account so browsers can be signed in by QR.
    /// Needs both a fresh signature from the key and this account's session.
    func linkIdentity() async {
        guard let s = try? await validSession(), UserDefaults.standard.string(forKey: linkedKey) != s.userID else { return }
        do {
            _ = try await function("cloud-login", ["action": "link", "access_token": s.access], nostr: true)
            UserDefaults.standard.set(s.userID, forKey: linkedKey)
        } catch {
            status = "Could not link this iPhone's key: \(error.localizedDescription)"
        }
    }

    /// Hands a browser its own session: the server issues one for this account after
    /// checking the key's signature, and the phone seals it with the key from the QR code
    /// so the relay only ever sees ciphertext.
    func approveBrowser(id: String, key: String) async throws {
        guard signedIn else { throw CloudError(message: "Turn on sync first (Settings → Sync), then scan again.") }
        UserDefaults.standard.removeObject(forKey: linkedKey)
        await linkIdentity()
        let current = try await validSession()
        let v = try await function("cloud-login", ["action": "login", "nonce": id], nostr: true)
        guard let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String,
              let user = v["user"] as? [String: Any], user["id"] as? String == current.userID else {
            throw CloudError(message: "This iPhone's key belongs to a different account. Sign out and back in, then try again.")
        }
        let payload: [String: Any] = ["nonce": id, "access_token": access, "refresh_token": refresh,
                                      "expires_in": v["expires_in"] ?? 3600,
                                      "email": current.email, "expires_at": Date().timeIntervalSince1970 + 120]
        guard let keyBytes = Hex.bytes(key), keyBytes.count == 32 else { throw CloudError(message: "Invalid code.") }
        let sealed = try AES.GCM.seal(try JSONSerialization.data(withJSONObject: payload),
                                      using: SymmetricKey(data: keyBytes),
                                      authenticating: Data(("cloud-qr/" + id).utf8))
        guard let combined = sealed.combined else { throw CloudError(message: "Could not seal the session.") }
        _ = try await function("cloud-qr", ["action": "complete", "id": id, "payload": combined.base64EncodedString()],
                               bearer: current.access)
    }

    func sendPasswordReset(email: String) async throws {
        _ = try await authRequest(path: "/auth/v1/recover", body: ["email": email])
    }

    func signOut() {
        session = nil
        UserDefaults.standard.removeObject(forKey: linkedKey)
        SecItemDelete(Self.keychain as CFDictionary)
        resetCursors()
        status = nil
    }

    private func adopt(_ v: [String: Any], fallbackEmail: String) throws {
        guard let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String else {
            throw CloudError(message: "Sign-in did not return a session.")
        }
        let user = v["user"] as? [String: Any]
        guard let id = user?["id"] as? String else { throw CloudError(message: "Sign-in returned no account.") }
        let expiresIn = (v["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let s = Session(access: access, refresh: refresh, expires: Date().timeIntervalSince1970 + expiresIn,
                        userID: id, email: (user?["email"] as? String) ?? fallbackEmail)
        if let old = session, old.userID != s.userID { resetCursors() }
        try saveSession(s)
    }

    private func saveSession(_ s: Session) throws {
        let data = try JSONEncoder().encode(s)
        SecItemDelete(Self.keychain as CFDictionary)
        var q = Self.keychain
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
            throw CloudError(message: "Could not save the sign-in securely.")
        }
        session = s
    }

    private func validSession() async throws -> Session {
        guard var s = session else { throw CloudError(message: "Not signed in.") }
        if s.expires < Date().timeIntervalSince1970 + 120 {
            let v: [String: Any]
            do {
                v = try await authRequest(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": s.refresh])
            } catch let error as CloudError where error.rejected {
                // The refresh token was revoked or already used: the session cannot recover.
                signOut()
                throw CloudError(message: "Signed out. Please sign in again to keep syncing.")
            }
            guard let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String else {
                throw CloudError(message: "Please sign in again.")
            }
            s.access = access
            s.refresh = refresh
            s.expires = Date().timeIntervalSince1970 + ((v["expires_in"] as? Double) ?? 3600)
            try saveSession(s)
        }
        return s
    }

    private func authRequest(path: String, body: [String: Any]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: Self.projectURL + path)!)
        r.httpMethod = "POST"
        r.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.data(for: r)
        let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            let known: [String: String] = [
                "invalid_credentials": "Email or password is incorrect.",
                "email_not_confirmed": "Confirm your email first (check your inbox), then sign in.",
                "user_already_exists": "An account with this email already exists. Sign in instead.",
                "weak_password": "Choose a longer password (at least 10 characters).",
                "over_email_send_rate_limit": "Too many emails were sent. Try again in an hour.",
                "over_request_rate_limit": "Too many attempts. Wait a few minutes.",
            ]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let rejected = [400, 401, 403].contains(status)
            if let c = v["error_code"] as? String, let m = known[c] { throw CloudError(message: m, rejected: rejected) }
            let msg = (v["msg"] as? String) ?? (v["error_description"] as? String) ?? (v["message"] as? String)
            throw CloudError(message: msg ?? "Request failed (\(status)).", rejected: rejected)
        }
        return v
    }

    // MARK: - REST

    private func rest(_ method: String, _ pathAndQuery: String, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        let s = try await validSession()
        var r = URLRequest(url: URL(string: Self.projectURL + "/rest/v1/" + pathAndQuery)!)
        r.httpMethod = method
        r.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer " + s.access, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
        r.httpBody = body
        let (data, response) = try await http.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            throw CloudError(message: "Session expired. Please sign in again.")
        }
        guard (200..<300).contains(code) else {
            let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudError(message: (v?["message"] as? String) ?? "Sync failed (\(code)).")
        }
        return data
    }

    // MARK: - Sync

    private func cursorKey(_ table: String) -> String { "slowclaw.sync.cursor.\(table)" }

    private func resetCursors() {
        for t in ["journals", "spaces", "space_items", "book_nodes"] { UserDefaults.standard.removeObject(forKey: cursorKey(t)) }
    }

    func schedulePush() {
        guard signedIn else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard signedIn, !syncing else { return }
        syncing = true
        defer { syncing = false }
        // Accounts signed in before keys existed get linked once, quietly.
        await linkIdentity()
        do {
            // Pull first so same-named default spaces merge before we push ours.
            try await pull("spaces") { rows in for r in rows { if let s = Self.space(from: r) { self.store.applyRemote(space: s) } } }
            try await pull("journals") { rows in for r in rows { if let j = Self.journal(from: r) { self.store.applyRemote(journal: j) } } }
            try await pull("space_items") { rows in for r in rows { if let i = Self.item(from: r) { self.store.applyRemote(item: i) } } }
            try await pull("book_nodes") { rows in BookStore.shared.applyRemote(rows: rows) }
            try await push()
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced!.timeIntervalSince1970, forKey: "slowclaw.sync.last")
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func pull(_ table: String, apply: ([[String: Any]]) -> Void) async throws {
        var firstPage = true
        while true {
            var query = "\(table)?select=*&order=synced_at.asc&limit=500"
            if let cursor = UserDefaults.standard.string(forKey: cursorKey(table)) {
                // Re-read a short window before the cursor: a row from a transaction that
                // committed late can carry an earlier synced_at. Re-applying rows is harmless.
                // Only on the first page, so paging always moves forward.
                let since = firstPage
                    ? (CloudDates.parse(cursor).map { CloudDates.format($0.addingTimeInterval(-60)) } ?? cursor)
                    : cursor
                let encoded = since.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? since
                query += "&synced_at=gt.\(encoded)"
            }
            let data = try await rest("GET", query)
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            apply(rows)
            firstPage = false
            if let last = rows.last?["synced_at"] as? String {
                UserDefaults.standard.set(last, forKey: cursorKey(table))
            }
            if rows.count < 500 { break }
        }
    }

    private func push() async throws {
        guard let s = session else { return }
        let spaces = store.dirtySpaces
        let journals = store.dirtyJournals
        let items = store.dirtyItems.filter { item in store.spaces.contains { $0.id == item.spaceID } }
        try await upsert("spaces", spaces.map { Self.row(from: $0, user: s.userID) })
        try await upsert("journals", journals.map { Self.row(from: $0, user: s.userID) })
        try await upsert("space_items", items.map { Self.row(from: $0, user: s.userID) })
        store.markPushed(journals: journals, spaces: spaces, items: items)
        let nodes = BookStore.shared.dirtyNodes
        try await upsert("book_nodes", nodes.map { BookStore.row(from: $0, user: s.userID) })
        BookStore.shared.markPushed(nodes)
    }

    private func upsert(_ table: String, _ rows: [[String: Any]]) async throws {
        var start = 0
        while start < rows.count {
            let batch = Array(rows[start..<min(start + 200, rows.count)])
            let body = try JSONSerialization.data(withJSONObject: batch)
            _ = try await rest("POST", "\(table)?on_conflict=user_id,id", body: body,
                               prefer: "resolution=merge-duplicates,return=minimal")
            start += 200
        }
    }

    // MARK: - Row mapping

    private static func orNull(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    static func row(from j: Journal, user: String?) -> [String: Any] {
        var r: [String: Any] = ["id": j.id, "title": j.title, "body": j.body,
         "space_id": orNull(j.spaceID), "created_at": CloudDates.format(j.createdAt),
         "updated_at": CloudDates.format(j.updatedAt), "deleted": j.deleted]
        if let user { r["user_id"] = user }
        return r
    }

    static func row(from s: Space, user: String?) -> [String: Any] {
        var r: [String: Any] = ["id": s.id, "name": s.name, "icon": s.icon, "summary": s.summary,
         "sort_order": s.sortOrder, "created_at": CloudDates.format(s.createdAt),
         "updated_at": CloudDates.format(s.updatedAt), "deleted": s.deleted]
        if let user { r["user_id"] = user }
        return r
    }

    static func row(from i: SpaceItem, user: String?) -> [String: Any] {
        var r: [String: Any] = ["id": i.id, "space_id": i.spaceID, "journal_id": orNull(i.journalID),
         "kind": i.kind.rawValue, "text": i.text, "done": i.done,
         "created_at": CloudDates.format(i.createdAt), "updated_at": CloudDates.format(i.updatedAt),
         "deleted": i.deleted]
        if let user { r["user_id"] = user }
        return r
    }

    static func journal(from r: [String: Any]) -> Journal? {
        guard let id = r["id"] as? String,
              let created = CloudDates.parse(r["created_at"] as? String),
              let updated = CloudDates.parse(r["updated_at"] as? String) else { return nil }
        let spaceID = r["space_id"] as? String
        return Journal(id: id, title: r["title"] as? String ?? "", body: r["body"] as? String ?? "",
                       transcript: nil, audioPath: nil, moreAudio: nil, spaceID: spaceID, createdAt: created, updatedAt: updated,
                       status: .ready, organized: spaceID != nil, deleted: r["deleted"] as? Bool ?? false, dirty: false)
    }

    static func space(from r: [String: Any]) -> Space? {
        guard let id = r["id"] as? String, let name = r["name"] as? String,
              let created = CloudDates.parse(r["created_at"] as? String),
              let updated = CloudDates.parse(r["updated_at"] as? String) else { return nil }
        return Space(id: id, name: name, icon: r["icon"] as? String ?? "tray", summary: r["summary"] as? String ?? "",
                     sortOrder: r["sort_order"] as? Int ?? 0, createdAt: created, updatedAt: updated,
                     deleted: r["deleted"] as? Bool ?? false, dirty: false)
    }

    static func item(from r: [String: Any]) -> SpaceItem? {
        guard let id = r["id"] as? String, let spaceID = r["space_id"] as? String,
              let kind = ItemKind(rawValue: r["kind"] as? String ?? ""),
              let created = CloudDates.parse(r["created_at"] as? String),
              let updated = CloudDates.parse(r["updated_at"] as? String) else { return nil }
        return SpaceItem(id: id, spaceID: spaceID, journalID: r["journal_id"] as? String, kind: kind,
                         text: r["text"] as? String ?? "", done: r["done"] as? Bool ?? false,
                         createdAt: created, updatedAt: updated, deleted: r["deleted"] as? Bool ?? false, dirty: false)
    }
}

/// Postgres timestamps come back with microseconds and an offset; normalize to milliseconds.
enum CloudDates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func format(_ date: Date) -> String { withFraction.string(from: date) }

    static func parse(_ raw: String?) -> Date? {
        guard var s = raw, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " ", with: "T")
        s = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        if s.hasSuffix("+00") { s += ":00" }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}
