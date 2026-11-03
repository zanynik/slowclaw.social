import Foundation
import Security

/// Text-only sync with Supabase (journals, spaces, items). Audio never leaves
/// the phone. Last edit wins per record; the server rejects older writes.
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

    // MARK: - Auth

    struct CloudError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func signIn(email: String, password: String) async throws {
        let v = try await authRequest(path: "/auth/v1/token?grant_type=password",
                                      body: ["email": email, "password": password])
        try adopt(v, fallbackEmail: email)
        // A new sign-in pushes everything once so the cloud has a full copy.
        store.markAllDirty()
        resetCursors()
        await sync()
    }

    /// Returns true when a session was created immediately (no email confirmation needed).
    func signUp(email: String, password: String) async throws -> Bool {
        let v = try await authRequest(path: "/auth/v1/signup", body: ["email": email, "password": password])
        if v["access_token"] != nil {
            try adopt(v, fallbackEmail: email)
            store.markAllDirty()
            resetCursors()
            await sync()
            return true
        }
        return false
    }

    func sendPasswordReset(email: String) async throws {
        _ = try await authRequest(path: "/auth/v1/recover", body: ["email": email])
    }

    func signOut() {
        session = nil
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
        let expiresIn = (v["expires_in"] as? Double) ?? Double(v["expires_in"] as? Int ?? 3600)
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
            let v = try await authRequest(path: "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": s.refresh])
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
            if let c = v["error_code"] as? String, let m = known[c] { throw CloudError(message: m) }
            let msg = (v["msg"] as? String) ?? (v["error_description"] as? String) ?? (v["message"] as? String)
            throw CloudError(message: msg ?? "Request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
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
        for t in ["journals", "spaces", "space_items"] { UserDefaults.standard.removeObject(forKey: cursorKey(t)) }
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
        do {
            // Pull first so same-named default spaces merge before we push ours.
            try await pull("spaces") { rows in for r in rows { if let s = Self.space(from: r) { self.store.applyRemote(space: s) } } }
            try await pull("journals") { rows in for r in rows { if let j = Self.journal(from: r) { self.store.applyRemote(journal: j) } } }
            try await pull("space_items") { rows in for r in rows { if let i = Self.item(from: r) { self.store.applyRemote(item: i) } } }
            try await push()
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced!.timeIntervalSince1970, forKey: "slowclaw.sync.last")
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func pull(_ table: String, apply: ([[String: Any]]) -> Void) async throws {
        while true {
            var query = "\(table)?select=*&order=synced_at.asc&limit=500"
            if let cursor = UserDefaults.standard.string(forKey: cursorKey(table)) {
                let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor
                query += "&synced_at=gt.\(encoded)"
            }
            let data = try await rest("GET", query)
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            apply(rows)
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

    private static func row(from j: Journal, user: String) -> [String: Any] {
        ["user_id": user, "id": j.id, "title": j.title, "body": j.body,
         "space_id": orNull(j.spaceID), "created_at": CloudDates.format(j.createdAt),
         "updated_at": CloudDates.format(j.updatedAt), "deleted": j.deleted]
    }

    private static func row(from s: Space, user: String) -> [String: Any] {
        ["user_id": user, "id": s.id, "name": s.name, "icon": s.icon, "summary": s.summary,
         "sort_order": s.sortOrder, "created_at": CloudDates.format(s.createdAt),
         "updated_at": CloudDates.format(s.updatedAt), "deleted": s.deleted]
    }

    private static func row(from i: SpaceItem, user: String) -> [String: Any] {
        ["user_id": user, "id": i.id, "space_id": i.spaceID, "journal_id": orNull(i.journalID),
         "kind": i.kind.rawValue, "text": i.text, "done": i.done,
         "created_at": CloudDates.format(i.createdAt), "updated_at": CloudDates.format(i.updatedAt),
         "deleted": i.deleted]
    }

    private static func journal(from r: [String: Any]) -> Journal? {
        guard let id = r["id"] as? String,
              let created = CloudDates.parse(r["created_at"] as? String),
              let updated = CloudDates.parse(r["updated_at"] as? String) else { return nil }
        let spaceID = r["space_id"] as? String
        return Journal(id: id, title: r["title"] as? String ?? "", body: r["body"] as? String ?? "",
                       transcript: nil, audioPath: nil, spaceID: spaceID, createdAt: created, updatedAt: updated,
                       status: .ready, organized: spaceID != nil, deleted: r["deleted"] as? Bool ?? false, dirty: false)
    }

    private static func space(from r: [String: Any]) -> Space? {
        guard let id = r["id"] as? String, let name = r["name"] as? String,
              let created = CloudDates.parse(r["created_at"] as? String),
              let updated = CloudDates.parse(r["updated_at"] as? String) else { return nil }
        return Space(id: id, name: name, icon: r["icon"] as? String ?? "tray", summary: r["summary"] as? String ?? "",
                     sortOrder: r["sort_order"] as? Int ?? 0, createdAt: created, updatedAt: updated,
                     deleted: r["deleted"] as? Bool ?? false, dirty: false)
    }

    private static func item(from r: [String: Any]) -> SpaceItem? {
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
