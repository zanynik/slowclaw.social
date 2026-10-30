import Foundation
import SwiftUI
import CryptoKit
import Security

/// Opt-in cloud transport. Native capture and SQLite persistence still use the existing Swift/Zig boundary.
@MainActor final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    struct Account: Codable { var url: String; var key: String; var access: String; var refresh: String; var expires: Double; var user: String }
    struct Entry: Codable { var id: String; var text: String; var title: String; var source: String; var recorded_at: String; var revision: Int; var content_hash: String; var deleted_at: String? }
    struct Checkpoint: Codable { var revision: Int; var localHash: String; var remoteHash: String; var audioHash: String?; var deleted: Bool }
    struct Conflict: Codable, Identifiable { var id: String; var local: String; var remote: Entry }
    struct Ledger: Codable { var entries: [String:Checkpoint] = [:]; var deletions: [String:Bool] = [:]; var conflicts: [String:Conflict] = [:] }
    struct Suggestion: Identifiable { var id: String; var kind: String; var title: String; var text: String; var state: String; var sources: [String]; var url: URL? }
    @Published private(set) var signInError: String?
    @Published var projectURL = ""
    @Published var publishableKey = ""
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var syncEnabled = false
    @Published private(set) var aiEnabled = false
    @Published private(set) var dailyEnabled = false
    @Published private(set) var status = "Cloud sync is optional."
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var conflicts: [Conflict] = []
    private var account: Account?
    private var ledger = Ledger()
    private var editingKeys = Set<String>()
    private var retryAfter = Date.distantPast
    private static let keychain: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.slowclaw.cloud",kSecAttrAccount as String:"account"]
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 180
        c.urlCache = nil; c.httpCookieStorage = nil
        return URLSession(configuration:c)
    }()
    init() {
        var q = Self.keychain; q[kSecReturnData as String] = true; var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary,&item) == errSecSuccess, let data = item as? Data, let saved = try? JSONDecoder().decode(Account.self,from:data) {
            account = saved; projectURL = saved.url; publishableKey = saved.key
            do { try readLedger(); connected = true } catch { status = "Cloud checkpoints could not be read. Sync is paused." }
        }
    }
    func beginEditing(_ key: String) { editingKeys.insert(key) }
    func endEditing(_ key: String) { editingKeys.remove(key) }
    private static func hash(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined() }
    private func validate(_ raw: String, key: String) throws -> String {
        guard let u = URL(string:raw), u.scheme == "https", let host = u.host, host.hasSuffix(".supabase.co"), u.user == nil, u.password == nil, u.port == nil, u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/", key.hasPrefix("sb_publishable_"), key.count < 500 else { throw PublishingError.message("Use your Supabase project HTTPS URL and publishable key, never a secret key.") }
        return "https://"+host
    }
    func connectionLink(_ url: URL) {
        guard !connected, url.scheme == "slowclaw", url.host == "cloud", let parts = URLComponents(url:url,resolvingAgainstBaseURL:false), let raw = parts.queryItems?.first(where:{$0.name == "url"})?.value, let key = parts.queryItems?.first(where:{$0.name == "key"})?.value else { return }
        do { projectURL = try validate(raw,key:key); publishableKey = key; status = "Connection ready. Open Profile → Cloud workspace to sign in." } catch { status = error.localizedDescription }
    }
    private func saveAccount(_ next: Account) throws {
        let bytes = try JSONEncoder().encode(next)
        var q = Self.keychain; q[kSecValueData as String] = bytes; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary,nil)
        if result == errSecDuplicateItem {
            guard SecItemUpdate(Self.keychain as CFDictionary,[kSecValueData as String:bytes] as CFDictionary) == errSecSuccess else { throw PublishingError.message("Could not securely save cloud sign-in.") }
        } else if result != errSecSuccess { throw PublishingError.message("Could not securely save cloud sign-in.") }
        account = next
    }
    private var ledgerURL: URL? {
        guard let account, let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else { return nil }
        return directory.appendingPathComponent("CloudSync",isDirectory:true).appendingPathComponent(Self.hash(account.user)+".json")
    }
    private func readLedger() throws {
        guard let url = ledgerURL else { return }
        ledger = FileManager.default.fileExists(atPath:url.path) ? try JSONDecoder().decode(Ledger.self,from:Data(contentsOf:url)) : Ledger()
        conflicts = Array(ledger.conflicts.values)
    }
    private func saveLedger() throws {
        guard let url = ledgerURL else { throw PublishingError.message("Connect a cloud account first.") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(ledger).write(to:url,options:[.atomic,.completeFileProtection])
        conflicts = Array(ledger.conflicts.values)
    }
    private func request(_ url: URL, method: String = "POST", value: [String:Any]? = nil, bytes: Data? = nil, key: String, token: String? = nil, mime: String = "application/json") async throws -> Data {
        var r = URLRequest(url:url); r.httpMethod = method; r.setValue(key,forHTTPHeaderField:"apikey"); r.setValue(mime,forHTTPHeaderField:"Content-Type")
        if let token { r.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        r.httpBody = try value.map{try JSONSerialization.data(withJSONObject:$0)} ?? bytes
        let (data,response) = try await http.data(for:r)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let failure = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let descriptions = ["email_not_confirmed":"Confirm your email first. Request a new confirmation link on SlowClaw Web.", "invalid_credentials":"Email or password is incorrect. Check both and try again.", "over_request_rate_limit":"Too many attempts. Wait a few minutes before signing in again."]
            if let code = failure?["error_code"] as? String, let message = descriptions[code] { throw PublishingError.message(message) }
            let code = failure?["error"] as? String
            throw PublishingError.message(code?.range(of:"^[A-Z_]{3,80}$",options:.regularExpression) != nil ? code! : "Cloud request failed. Local journals and pending edits are kept.")
        }
        return data
    }
    private func session() async throws -> Account {
        guard var a = account else { throw PublishingError.message("Sign in to your cloud account first.") }
        if a.expires < Date().timeIntervalSince1970+120 {
            let data = try await request(URL(string:a.url+"/auth/v1/token?grant_type=refresh_token")!,value:["refresh_token":a.refresh],key:a.key)
            guard let v = try JSONSerialization.jsonObject(with:data) as? [String:Any], let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String else { throw PublishingError.message("Sign in again to renew your cloud connection.") }
            a.access = access; a.refresh = refresh; a.expires = Date().timeIntervalSince1970+(v["expires_in"] as? Double ?? 3600); try saveAccount(a)
        }
        return a
    }
    private func api(_ value: [String:Any], worker: Bool = false) async throws -> [String:Any] {
        let a = try await session()
        let data = try await request(URL(string:a.url+"/functions/v1/"+(worker ? "cloud-worker":"cloud-api"))!,value:value,key:a.key,token:a.access)
        guard let v = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw PublishingError.message("Cloud returned an unreadable response.") }
        if let error = v["error"] as? String { throw PublishingError.message(error) }
        return v
    }
    private func entries(_ value: Any?) throws -> [Entry] { try JSONDecoder().decode([Entry].self,from:JSONSerialization.data(withJSONObject:value ?? [])) }
    private func loadSettings() async throws {
        let value = try await api(["action":"settings"])
        if let s = value["settings"] as? [String:Any] { syncEnabled = s["sync_enabled"] as? Bool ?? false; aiEnabled = s["ai_enabled"] as? Bool ?? false; dailyEnabled = s["daily_enabled"] as? Bool ?? false }
    }
    /// Only the approved, encrypted browser connection may request this scoped login.
    func authorizeBrowser(_ input: [String:Any]) async throws -> [String:Any] {
        guard !busy, let config = input["config"] as? [String:Any], let raw = config["url"] as? String, let key = config["publishableKey"] as? String, let nonce = input["nonce"] as? String, WebSessionProtocol.validID(nonce), let expires = input["expires"] as? Double, expires > Date().timeIntervalSince1970, expires < Date().timeIntervalSince1970+125 else { throw PublishingError.message("Cloud sign-in expired. Retry from your connected browser.") }
        busy = true; defer { busy = false }
        let host = try validate(raw,key:key)
        // Trust deployment configuration, never an arbitrary project supplied by a browser.
        let (data,response) = try await http.data(from:URL(string:"https://slowclaw-cloud-config.zanynik.workers.dev/")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let trusted = try JSONSerialization.jsonObject(with:data) as? [String:Any], trusted["url"] as? String == host, trusted["publishableKey"] as? String == key else { throw PublishingError.message("Cloud connection does not match SlowClaw's deployed project.") }
        let endpoint = URL(string:host+"/functions/v1/cloud-login")!, secret = try NostrIdentity.secret()
        func login() async throws -> [String:Any] {
            let body = try JSONSerialization.data(withJSONObject:["nonce":nonce],options:[.withoutEscapingSlashes])
            var request = URLRequest(url:endpoint); request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue(key,forHTTPHeaderField:"apikey")
            request.setValue(try WebSessionProtocol.authorization(url:endpoint,method:"POST",body:body,secret:secret),forHTTPHeaderField:"Authorization")
            let (bytes,result) = try await http.data(for:request)
            guard let result = result as? HTTPURLResponse, result.statusCode == 200, let value = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw PublishingError.message("Cloud phone sign-in failed. Retry shortly.") }
            return value
        }
        let browser = try await login()
        guard let user = browser["user"] as? [String:Any], let id = user["id"] as? String else { throw PublishingError.message("Cloud sign-in returned no account.") }
        let binding = Self.hash(host+id)
        if let owner = UserDefaults.standard.string(forKey:"slowclaw.cloud.local-owner"), owner != binding { throw PublishingError.message("Local journals belong to another cloud account. Sign in with that account first.") }
        if let account, account.user != id || account.url != host { throw PublishingError.message("This phone is connected to a different cloud account.") }
        if account == nil {
            // Separate Auth sessions: browser logout/refresh never consumes the phone's refresh token.
            let phone = try await login()
            guard let access = phone["access_token"] as? String, let refresh = phone["refresh_token"] as? String else { throw PublishingError.message("Could not save the phone connection.") }
            try saveAccount(Account(url:host,key:key,access:access,refresh:refresh,expires:Date().timeIntervalSince1970+(phone["expires_in"] as? Double ?? 3600),user:id))
            UserDefaults.standard.set(binding,forKey:"slowclaw.cloud.local-owner")
            try readLedger(); projectURL = host; publishableKey = key; connected = true
        }
        status = "Browser signed in with this phone. Enable cloud sync when ready."
        return browser
    }
    func signIn(email: String, password: String) async -> Bool {
        guard !busy else { return false }; busy = true; signInError = nil; defer { busy = false }
        do {
            if projectURL.isEmpty || publishableKey.isEmpty {
                let (bytes,response) = try await http.data(from:URL(string:"https://slowclaw-cloud-config.zanynik.workers.dev/")!)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let value = try JSONSerialization.jsonObject(with:bytes) as? [String:Any], let url = value["url"] as? String, let key = value["publishableKey"] as? String else { throw PublishingError.message("Could not load the cloud connection. Check your internet and try again.") }
                projectURL = try validate(url,key:key); publishableKey = key
            }
            let host = try validate(projectURL,key:publishableKey)
            let data = try await request(URL(string:host+"/auth/v1/token?grant_type=password")!,value:["email":email,"password":password],key:publishableKey)
            guard let v = try JSONSerialization.jsonObject(with:data) as? [String:Any], let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String, let u = v["user"] as? [String:Any], let id = u["id"] as? String else { throw PublishingError.message("Confirm your email on SlowClaw Web, then sign in.") }
            if let owner = UserDefaults.standard.string(forKey:"slowclaw.cloud.local-owner"), owner != Self.hash(host+id) { throw PublishingError.message("These local journals are linked to another cloud account. Sign in to that account to avoid mixing private workspaces.") }
            try saveAccount(Account(url:host,key:publishableKey,access:access,refresh:refresh,expires:Date().timeIntervalSince1970+(v["expires_in"] as? Double ?? 3600),user:id))
            UserDefaults.standard.set(Self.hash(host+id),forKey:"slowclaw.cloud.local-owner")
            try readLedger(); connected = true; try await loadSettings(); status = "Signed in. Cloud sync uploads your journals when enabled."
            return true
        } catch { status = error.localizedDescription; signInError = error.localizedDescription; return false }
    }
    func signOut() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { let a = try await session(); _ = try await request(URL(string:a.url+"/auth/v1/logout?scope=local")!,value:[:],key:a.key,token:a.access)
            SecItemDelete(Self.keychain as CFDictionary); account = nil; connected = false; syncEnabled = false; aiEnabled = false; dailyEnabled = false; suggestions = []; conflicts = []; status = "Signed out. Local journals and pending checkpoints are kept."
        } catch { status = "Could not revoke the session. Retry sign out. "+error.localizedDescription }
    }
    func configure(_ name: String, enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await api(["action":"configure",name:enabled]); try await loadSettings(); status = "Cloud choices saved." } catch { status = error.localizedDescription }
    }
    func markDeleted(_ key: String, deleted: Bool) {
        guard connected else { return }; ledger.deletions[key] = deleted
        if !deleted { ledger.entries[key]?.audioHash = nil }
        do { try saveLedger() } catch { status = "Cloud deletion could not be queued. Retry sync before clearing the local journal." }
    }
    private func remember(_ row: Entry, local: String, audio: String? = nil) throws {
        ledger.entries[row.id] = Checkpoint(revision:row.revision,localHash:Self.hash(local),remoteHash:row.content_hash,audioHash:audio ?? ledger.entries[row.id]?.audioHash,deleted:row.deleted_at != nil)
        // Do not lose a deletion/restore intent that arrived while a network save was in flight.
        if let intent = ledger.deletions[row.id], intent == (row.deleted_at != nil) { ledger.deletions.removeValue(forKey:row.id) }
        try saveLedger()
    }
    private func push(id: String, text: String, title: String, source: String, revision: Int, deleted: Bool = false, recordedAt: String? = nil) async throws -> Entry? {
        var v: [String:Any] = ["action":"save","id":id,"text":text,"title":String(title.prefix(240)),"source":source,"revision":revision,"deleted":deleted]
        if let recordedAt {
            let raw = recordedAt.replacingOccurrences(of:" ",with:"T"), f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            if let date = f.date(from:raw) ?? ISO8601DateFormatter().date(from:raw.hasSuffix("Z") ? raw:raw+"Z") { v["recorded_at"] = ISO8601DateFormatter().string(from:date) }
        }
        let result = try await api(v)
        if result["ok"] as? Bool == true { return try entries([result["entry"]!]).first }
        if let r = result["conflict"] as? [String:Any], let row = try entries([r]).first { ledger.conflicts[id] = Conflict(id:id,local:text,remote:row); try saveLedger() }
        throw PublishingError.message("A journal changed on another device. Both versions are kept under Cloud conflicts.")
    }
    func sync(state: AppState, force: Bool = false) async {
        guard connected, !busy, force || Date() >= retryAfter else { return }; busy = true; defer { busy = false }
        do {
            try await loadSettings(); guard syncEnabled else { status = "Cloud sync paused. Journals stay on this phone."; return }
            let snapshot = try await api(["action":"snapshot"])
            var remote = try entries(snapshot["entries"]), offset = remote.count
            while offset > 0 && offset % 200 == 0 && offset < 20000 { let p = try entries(try await api(["action":"snapshot","offset":offset])["entries"]); remote += p; offset += p.count; if p.count < 200 { break } }
            for row in remote where ledger.conflicts[row.id] == nil && !editingKeys.contains(row.id) {
                let local = try state.memory.get(key:row.id), old = ledger.entries[row.id]
                if ledger.deletions[row.id] != nil { continue }
                if row.deleted_at != nil, old?.deleted == true, old?.revision == row.revision { continue }
                if let local, let old, Self.hash(local.content) != old.localHash {
                    if row.revision != old.revision { ledger.conflicts[row.id] = Conflict(id:row.id,local:local.content,remote:row); try saveLedger() }; continue
                }
                if let local, old == nil, Self.hash(local.content) != row.content_hash { ledger.conflicts[row.id] = Conflict(id:row.id,local:local.content,remote:row); try saveLedger(); continue }
                if row.deleted_at != nil { if local != nil { state.softDelete(key:row.id) }; try remember(row,local:local?.content ?? "") }
                else if old?.revision != row.revision || local == nil {
                    if AppState.softDeletedKeys()[row.id] != nil { ledger.deletions[row.id] = true; try saveLedger(); continue }
                    try state.memory.store(key:row.id,content:row.text,category:"daily",sessionID:nil,source:row.source,mediaURL:local?.mediaURL); try remember(row,local:row.text)
                }
            }
            for (id,deleted) in Array(ledger.deletions) where ledger.conflicts[id] == nil {
                let local = try state.memory.get(key:id)
                if let row = try await push(id:id,text:deleted ? "":local?.content ?? "",title:"",source:local?.source ?? "text",revision:ledger.entries[id]?.revision ?? 0,deleted:deleted) { try remember(row,local:local?.content ?? "") }
            }
            await state.refreshJournals(); var count = 0
            for entry in state.journals where !state.excludedMemoryKeys.contains(entry.key) && !editingKeys.contains(entry.key) && ledger.conflicts[entry.key] == nil {
                if count >= 10 { break }; let old = ledger.entries[entry.key]
                if old?.localHash != Self.hash(entry.content) || old?.deleted == true {
                    if let row = try await push(id:entry.key,text:entry.content,title:journalTitleOf(entry),source:entry.source ?? "text",revision:old?.revision ?? 0,recordedAt:entry.timestamp) { try remember(row,local:entry.content); count += 1 }
                }
                if let rel = entry.mediaURL, let file = AudioRecorder.absoluteURL(forMediaRelativePath:rel), ledger.entries[entry.key]?.audioHash == nil { try await upload(file,entry:entry.key); count += 1 }
            }
            try await downloadAudio(snapshot["media"],state:state); suggestions = decodeSuggestions(snapshot)
            status = conflicts.isEmpty ? "Cloud checked. \(count) uploads saved." : "\(conflicts.count) cloud conflict(s) need review. Both versions are kept."
            retryAfter = Date().addingTimeInterval(30)
        } catch { status = error.localizedDescription; retryAfter = Date().addingTimeInterval(60) }
    }
    private func upload(_ file: URL, entry: String) async throws {
        guard let docs = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first, file.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path+"/") else { throw PublishingError.message("Audio must be inside the app's own recordings directory.") }
        let size = (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 52428800 else { throw PublishingError.message("Cloud audio uploads support files up to 50 MB. The original stays on this phone.") }
        let bytes = try Data(contentsOf:file,options:.mappedIfSafe), hash = SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        let mime = ["m4a":"audio/mp4","mp3":"audio/mpeg","wav":"audio/wav","aac":"audio/aac","flac":"audio/flac"][file.pathExtension.lowercased()] ?? "application/octet-stream"
        let start = try await api(["action":"upload_start","entry_id":entry,"filename":file.lastPathComponent,"mime":mime,"bytes":size,"sha256":hash])
        if start["complete"] as? Bool != true {
            guard let m = start["media"] as? [String:Any], let id = m["id"] as? String, let signed = start["upload"] as? [String:Any], let raw = signed["signedUrl"] as? String, let url = URL(string:raw), url.host == URL(string:account!.url)?.host else { throw PublishingError.message("Cloud upload could not be prepared.") }
            let a = try await session()
            do { _ = try await request(url,method:"PUT",bytes:bytes,key:a.key,mime:mime) } catch { /* The verification endpoint resolves an already uploaded object or a lost receipt. */ }
            _ = try await api(["action":"upload_finish","id":id])
        }
        ledger.entries[entry]?.audioHash = hash; try saveLedger()
    }
    private func downloadAudio(_ value: Any?, state: AppState) async throws {
        guard let rows = value as? [[String:Any]], let docs = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }; var count = 0
        for m in rows where count < 2 {
            guard m["status"] as? String == "uploaded", let key = m["entry_id"] as? String, ledger.conflicts[key] == nil, !editingKeys.contains(key), let id = m["id"] as? String, let hash = m["sha256"] as? String, let local = try state.memory.get(key:key), local.mediaURL == nil, let size = m["bytes"] as? Int, size <= 52428800, AppState.softDeletedKeys()[key] == nil else { continue }
            let link = try await api(["action":"audio_url","id":id])
            guard let raw = link["signedUrl"] as? String, let url = URL(string:raw), url.host == URL(string:account!.url)?.host else { continue }
            let a = try await session(), bytes = try await request(url,method:"GET",key:a.key)
            guard bytes.count == size, SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == hash else { throw PublishingError.message("Downloaded audio failed its checksum. Retry sync.") }
            let ext = URL(fileURLWithPath:m["filename"] as? String ?? "audio.m4a").pathExtension.lowercased()
            let rel = "CloudAudio/"+Self.hash(id)+"."+(["m4a","mp3","wav","aac","flac","webm"].contains(ext) ? ext:"m4a"), file = docs.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true); try bytes.write(to:file,options:[.atomic,.completeFileProtection])
            try state.memory.store(key:key,content:local.content,category:local.category,sessionID:local.sessionID,source:local.source,mediaURL:rel); ledger.entries[key]?.audioHash = hash; try saveLedger(); count += 1
        }
    }
    private func decodeSuggestions(_ snapshot: [String:Any]) -> [Suggestion] {
        var rows: [Suggestion] = []
        for a in snapshot["artifacts"] as? [[String:Any]] ?? [] {
            guard a["stale"] as? Bool != true, a["state"] as? String != "dismissed", let id = a["id"] as? String, let kind = a["kind"] as? String, let body = a["body"] as? [String:Any] else { continue }
            rows.append(Suggestion(id:id,kind:kind,title:a["title"] as? String ?? "Reflection",text:body["text"] as? String ?? "",state:a["state"] as? String ?? "proposed",sources:(a["sources"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String},url:nil))
        }
        for r in snapshot["reads"] as? [[String:Any]] ?? [] where r["read_at"] is NSNull {
            if let raw = r["url"] as? String, let url = URL(string:raw), url.scheme == "https" { rows.append(Suggestion(id:raw,kind:"read",title:r["title"] as? String ?? "Read",text:r["reason"] as? String ?? "",state:"unread",sources:[],url:url)) }
        }
        return rows
    }
    func review(_ item: Suggestion, state: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await api(item.kind == "read" ? ["action":"read","url":item.id] : ["action":"artifact_state","id":item.id,"state":state]); suggestions = decodeSuggestions(try await api(["action":"snapshot"])); status = "Saved." } catch { status = error.localizedDescription }
    }
    func processNow() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { _ = try await api(["action":"enqueue","daily":dailyEnabled,"retry":true]); _ = try await api([:],worker:true); status = "Processing requested. Remaining work continues in the cloud." } catch { status = error.localizedDescription }
    }
    func keepConflictAsCopy(_ conflict: Conflict, state: AppState) async {
        guard !busy else { return }
        let key = await state.storeJournalNow(text:conflict.local,source:"cloud_conflict_copy",mediaURL:nil)
        guard !key.isEmpty else { status = "Could not save the copy. Both versions are still kept."; return }
        do {
            if conflict.remote.deleted_at != nil { state.softDelete(key:conflict.id) }
            else { let old = try state.memory.get(key:conflict.id); try state.memory.store(key:conflict.id,content:conflict.remote.text,category:"daily",sessionID:nil,source:conflict.remote.source,mediaURL:old?.mediaURL) }
            try remember(conflict.remote,local:conflict.remote.text); ledger.conflicts.removeValue(forKey:conflict.id); try saveLedger(); await state.refreshJournals(); status = "Your edit is a new journal. The original now follows the cloud revision."
        } catch { status = error.localizedDescription }
    }
}

struct CloudWorkspaceView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var cloud = CloudSync.shared
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        Form {
            if let error = cloud.signInError { Section { Text(error).foregroundStyle(.red).accessibilityLabel("Sign-in error: "+error) } }
            if !cloud.connected {
                Section("Connect your cloud account") {
                    DisclosureGroup("Advanced connection") {
                        TextField("Project URL",text:$cloud.projectURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Publishable key",text:$cloud.publishableKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Email",text:$email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                    SecureField("Password",text:$password)
                    Button("Sign in") { Task { if await cloud.signIn(email:email,password:password) { password = "" } } }.disabled(cloud.busy)
                    Link("Create an account on SlowClaw Web",destination:URL(string:"https://slowclaw.social/?cloud")!)
                    Text("The cloud connection is loaded automatically. Sign-in errors appear above.").font(.caption)
                }
            } else {
                Section("Your choices") {
                    Text("Cloud sync uploads your journals and recordings into your private account. Cloud AI sends selected content to your chosen model provider. Local capture remains available.")
                    Toggle("Sync journals & audio",isOn:Binding(get:{cloud.syncEnabled},set:{v in Task { await cloud.configure("sync_enabled",enabled:v) }}))
                    Toggle("Allow cloud AI",isOn:Binding(get:{cloud.aiEnabled},set:{v in Task { await cloud.configure("ai_enabled",enabled:v) }}))
                    Toggle("Daily reflection, Spaces & Reads",isOn:Binding(get:{cloud.dailyEnabled},set:{v in Task { await cloud.configure("daily_enabled",enabled:v) }}))
                    Button("Sync now") { Task { await cloud.sync(state:state,force:true) } }
                    Button("Process now") { Task { await cloud.processNow() } }.disabled(!cloud.syncEnabled || !cloud.aiEnabled)
                    Link("Provider keys, budgets & export",destination:URL(string:"https://slowclaw.social/?cloud")!)
                    Button("Sign out") { Task { await cloud.signOut() } }
                }.disabled(cloud.busy)
                if !cloud.conflicts.isEmpty { Section("Cloud conflicts") { ForEach(cloud.conflicts) { item in VStack(alignment:.leading,spacing:8) { Text(item.local).lineLimit(5); Text("Cloud: "+(item.remote.deleted_at == nil ? item.remote.text:"Deleted")).font(.caption).lineLimit(5); Button("Keep my edit as a new journal") { Task { await cloud.keepConflictAsCopy(item,state:state) } } } } } }
                ForEach(["space","action","read","moment","daily","summary"],id:\.self) { kind in
                    let items = cloud.suggestions.filter{$0.kind == kind}
                    if !items.isEmpty { Section(["space":"Spaces","action":"Action points","read":"Reads","moment":"Moments","daily":"Daily reflection","summary":"Journal summaries"][kind] ?? kind) { ForEach(items) { item in
                        VStack(alignment:.leading,spacing:8) {
                            Text(item.title).font(.headline); Text(item.text).textSelection(.enabled)
                            if let url = item.url { Link("Open article",destination:url); Button("Mark read") { Task { await cloud.review(item,state:"completed") } } }
                            else { Text(item.state == "proposed" ? "Suggestion for your review":item.state).font(.caption).foregroundStyle(.secondary)
                                HStack { if item.state == "proposed" { Button("Keep") { Task { await cloud.review(item,state:"accepted") } } }; if kind == "action" && item.state != "completed" { Button("Done") { Task { await cloud.review(item,state:"completed") } } }; Button("Dismiss") { Task { await cloud.review(item,state:"dismissed") } } }
                                ForEach(item.sources,id:\.self) { key in if let entry = state.journals.first(where:{$0.key == key}) { NavigationLink("Source journal") { JournalDetailView(entry:entry) } } }
                            }
                        }.padding(.vertical,6)
                    } } }
                }
            }
            Section { Text(cloud.status).font(.caption); if cloud.busy { ProgressView() } }
        }.navigationTitle("Cloud workspace").task { if cloud.connected { await cloud.sync(state:state,force:true) } }
    }
}

struct CloudSuggestionCards: View {
    let kind: String
    @EnvironmentObject var state: AppState
    @StateObject private var cloud = CloudSync.shared
    var body: some View {
        if cloud.connected && cloud.syncEnabled { ForEach(Array(cloud.suggestions.filter{$0.kind == kind}.prefix(6))) { item in
            VStack(alignment:.leading,spacing:10) {
                Text(kind == "read" ? "From your cloud reading refresh":"A moment from your journals").font(.caption).foregroundStyle(.secondary)
                Text(item.title).font(.headline); Text(item.text).textSelection(.enabled)
                if let url = item.url { Link("Open article",destination:url); Button("Mark read") { Task { await cloud.review(item,state:"completed") } } }
                else { ShareLink(item:item.text) { Label("Share…",systemImage:"square.and.arrow.up") }; Text("Sharing happens only when you choose it.").font(.caption).foregroundStyle(.secondary); Button("Dismiss") { Task { await cloud.review(item,state:"dismissed") } } }
            }.padding(16).background(Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:20))
        } }
    }
}
