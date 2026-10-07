import SwiftUI
import Foundation
import CryptoKit
import Security
import AVFoundation

@MainActor
final class WebCompanion: ObservableObject {
    static let shared = WebCompanion()
    struct Session: Codable { let id: String; let key: Data; let pubkey: String; let expires: Int; var pair: String? = nil }
    struct Transfer: Decodable { let id: String; let meta: String; let bytes: Int; let status: String }
    struct Edit: Decodable { let id: String; let sealed: String; let status: String }
    struct Status: Decodable { let expires: Int; let transfers: [Transfer]; let edits: [Edit]? }
    struct Metadata: Decodable { let name: String; let type: String }
    @Published private(set) var session: Session?
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var lastSync: Date?
    private var lastSnapshot: String?
    private static let keychain: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.slowclaw.web", kSecAttrAccount as String: "temporary-session"]
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 180
        config.urlCache = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    init() {
        var query = Self.keychain; query[kSecReturnData as String] = true
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data, let stored = try? JSONDecoder().decode(Session.self, from: data),
           stored.expires > Int(Date().timeIntervalSince1970) { session = stored }
        else { SecItemDelete(Self.keychain as CFDictionary) }
    }
    private func save(_ next: Session) throws {
        let data = try JSONEncoder().encode(next)
        var attrs = Self.keychain; attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(attrs as CFDictionary, nil)
        if result == errSecDuplicateItem {
            guard SecItemUpdate(Self.keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw PublishingError.message("Could not save this connection securely.") }
        } else if result != errSecSuccess { throw PublishingError.message("Could not save this connection securely.") }
        session = next
    }
    private func forget() { SecItemDelete(Self.keychain as CFDictionary); session = nil; lastSnapshot = nil; lastSync = nil }
    private func request(_ session: Session, path: String = "", method: String = "GET", body: Data = Data()) async throws -> Data {
        let secret = try NostrIdentity.secret()
        guard try NostrIdentity.publicKey(secret) == session.pubkey else { throw PublishingError.message("This session belongs to a different Nostr identity.") }
        let url = URL(string: WebSessionProtocol.origin + "/api/session/" + session.id + path)!
        var req = URLRequest(url: url); req.httpMethod = method
        if method != "GET" { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.setValue(try WebSessionProtocol.authorization(url: url, method: method, body: body, secret: secret), forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw PublishingError.message("No response from SlowClaw Web.") }
        guard (200..<300).contains(response.statusCode) else {
            if self.session?.id == session.id,
               response.statusCode == 410 || (response.statusCode == 403 && self.session?.pair != nil) { forget() }
            let problem = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PublishingError.message(problem ?? "Web sync could not finish. Please retry.")
        }
        return data
    }
    func connect(_ pairing: WebSessionProtocol.Pairing, state: AppState) async {
        guard !busy, session == nil else { return }
        busy = true; message = nil
        do {
            let key = try NostrIdentity.publicKey(NostrIdentity.secret())
            let provisional = Session(id: pairing.id, key: pairing.key, pubkey: key, expires: Int(Date().timeIntervalSince1970) + 86400, pair: pairing.pair)
            // Save the recovery key before approving the server session.
            try save(provisional)
            try await completePair(provisional)
            message = "Connected. Preparing your journal workspace…"
        } catch { message = error.localizedDescription }
        busy = false
        if session != nil { await sync(state: state) }
    }
    private func completePair(_ pending: Session) async throws {
        guard let pair = pending.pair else { return }
        let body = try JSONSerialization.data(withJSONObject: ["pair": pair])
        var expires = pending.expires
        do {
            let result = try await request(pending, path: "/pair", method: "POST", body: body)
            struct Response: Decodable { let expires: Int }
            expires = try JSONDecoder().decode(Response.self, from: result).expires
        } catch {
            // A lost approval response is recoverable only if this identity can
            // read the now-paired session. No alternate identity is accepted.
            do { expires = try JSONDecoder().decode(Status.self, from: await request(pending)).expires }
            catch { throw error }
        }
        try save(.init(id: pending.id, key: pending.key, pubkey: pending.pubkey, expires: expires))
    }
    func disconnect() async {
        guard let session, !busy else { return }; busy = true
        do { _ = try await request(session, method: "DELETE"); forget(); message = "Web session deleted." }
        catch { message = error.localizedDescription }
        busy = false
    }
    func sync(state: AppState) async {
        guard let session, !busy else { return }
        if session.expires <= Int(Date().timeIntervalSince1970) { forget(); message = "Web session expired."; return }
        busy = true; defer { busy = false }
        do {
            try await completePair(session)
            let status = try JSONDecoder().decode(Status.self, from: await request(session))
            var failed = 0, received = 0
            for edit in status.edits ?? [] where edit.status == "queued" {
                do { try await receiveEdit(edit, session: session, state: state); received += 1 }
                catch { failed += 1; message = "A journal edit is waiting: " + error.localizedDescription }
            }
            for transfer in status.transfers where transfer.status == "ready" {
                do { try await receive(transfer, session: session, state: state); received += 1 }
                catch { failed += 1; message = "A file could not be imported: " + error.localizedDescription }
            }
            if received > 0 { await state.refreshJournals() }
            let snapshot = try makeSnapshot(state: state)
            let fingerprint = WebSessionProtocol.digest(snapshot)
            if fingerprint != lastSnapshot {
                let sealed = try WebSessionProtocol.seal(snapshot, key: session.key, context: session.id + "/snapshot")
                let body = try JSONSerialization.data(withJSONObject: ["sealed": sealed.base64EncodedString()])
                _ = try await request(session, path: "/snapshot", method: "PUT", body: body)
                lastSnapshot = fingerprint
            }
            lastSync = Date()
            if failed == 0 { message = "Journals, browser edits, moments and Pulse are synced." }
        } catch { message = error.localizedDescription }
    }
    private func makeSnapshot(state: AppState) throws -> Data {
        let since = Date().addingTimeInterval(-7 * 86400)
        let available = state.journals.filter { !state.excludedMemoryKeys.contains($0.key) }
        var index: [[String: String]] = available.map {
            ["id": $0.key, "title": String(journalTitleOf($0).prefix(240)),
             "date": ISO8601DateFormatter().string(from: journalDate($0) ?? Date()),
             "kind": $0.mediaURL == nil ? "JOURNAL" : "TRANSCRIPT",
             "revision": WebSessionProtocol.digest(Data($0.content.utf8))]
        }
        let recent = state.journals.filter { !state.excludedMemoryKeys.contains($0.key) && (journalDate($0) ?? .distantPast) >= since }.prefix(200)
        let keys = Set(recent.map(\.key))
        var budget = 650_000
        var journals: [[String: String]] = recent.compactMap { entry in
            guard entry.content.utf8.count <= budget else { return nil }; budget -= entry.content.utf8.count
            return journalPayload(entry)
        }
        var creations: [[String: String]] = state.createIdeas.filter { keys.contains($0.key) }.prefix(100).map {
            ["id": $0.id, "text": $0.text, "kind": $0.start == nil ? "QUOTE" : "STORY EXCERPT"]
        }
        var pulse: [[String: String]] = state.relevantPulse.prefix(40).compactMap { item in
            guard let raw = item.nostrEventJSON, let event = try? JSONDecoder().decode(PublishedEvent.self, from: Data(raw.utf8)),
                  event.created_at >= Int(since.timeIntervalSince1970), !NostrInbox.shared.hiddenAuthors.contains(event.pubkey) else { return nil }
            return ["id": event.id, "text": String(event.content.prefix(2000)), "author": NostrSocialStore.shared.profiles[event.pubkey].flatMap(NostrProfile.init)?.displayName ?? String(event.pubkey.prefix(12)),
                    "date": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(event.created_at))), "url": "https://njump.me/" + event.id]
        }
        var unitGroups: [[String: Any]] = state.journalUnitGroups.prefix(100).map { group in
            ["id": group.id, "title": group.title, "units": group.units.prefix(30).map {
                ["id": $0.id, "sourceKey": $0.sourceKey, "text": $0.text]
            }]
        }
        // Only text and an encrypted history index; never audio originals or Nostr secrets.
        func encode() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["journals": journals, "index": index, "editorVersion": 1, "unitsVersion": 1, "unitRevisions": state.journalUnitRevisions, "unitGroups": unitGroups, "creations": creations, "pulse": pulse], options: [.sortedKeys, .withoutEscapingSlashes])
        }
        var encoded = try encode()
        while encoded.count > 1_200_000 {
            if !unitGroups.isEmpty { unitGroups.removeLast() }
            else if !journals.isEmpty { journals.removeLast() }
            else if !creations.isEmpty { creations.removeLast() }
            else if !pulse.isEmpty { pulse.removeLast() }
            else if !index.isEmpty { index.removeLast() }
            else { break }
            encoded = try encode()
        }
        return encoded
    }
    private func journalPayload(_ entry: SlowClawMemoryEntry) -> [String: String] {
        let lines = entry.content.components(separatedBy: "\n")
        var body = lines.dropFirst().joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        // The phone keeps the canonical journal; the browser receives a
        // readable projection for audio transcripts and may edit that text.
        let displayBody = entry.mediaURL == nil ? body : TranscriptCleanup.clean(body)
        return ["id": entry.key, "title": lines.first ?? "Journal", "text": displayBody,
                "revision": WebSessionProtocol.digest(Data(entry.content.utf8)),
                "date": ISO8601DateFormatter().string(from: journalDate(entry) ?? Date()),
                "kind": entry.mediaURL == nil ? "JOURNAL" : "TRANSCRIPT"]
    }
    private func receiveEdit(_ edit: Edit, session: Session, state: AppState) async throws {
        guard WebSessionProtocol.validID(edit.id), let sealed = Data(base64Encoded: edit.sealed) else {
            throw PublishingError.message("Invalid journal operation.")
        }
        let context = session.id + "/note/" + edit.id
        let plaintext = try WebSessionProtocol.open(sealed, key: session.key, context: context)
        if (try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any])?["kind"] as? String == "units" {
            try await receiveUnits(plaintext, edit: edit, session: session, state: state, context: context)
            return
        }
        let operation = try JSONDecoder().decode(WebJournalEdit.self, from: plaintext)
        try operation.validate()
        let existing = try state.memory.get(key: operation.key)
        let available = state.journals.contains { $0.key == operation.key } && !state.excludedMemoryKeys.contains(operation.key)
        let revision = existing.map { WebSessionProtocol.digest(Data($0.content.utf8)) }
        var outcome = operation.decision(current: existing?.content, revision: revision, available: available)
        if AppState.softDeletedKeys()[operation.key] != nil || state.excludedMemoryKeys.contains(operation.key) { outcome = "rejected" }
        // No suspension between revision check and SQLite upsert. Preserve audio
        // provenance and never turn an excluded/deleted record back into a journal.
        if outcome == "saved" {
            if let existing {
                try state.memory.store(key: existing.key, content: operation.content, category: existing.category,
                                       sessionID: existing.sessionID, source: existing.source, mediaURL: existing.mediaURL)
            } else {
                try state.memory.store(key: operation.key, content: operation.content, category: "daily",
                                       sessionID: nil, source: "text", mediaURL: nil)
            }
        }
        var result: [String: Any] = ["key": operation.key]
        if outcome != "rejected", let entry = try state.memory.get(key: operation.key) {
            if entry.content.utf8.count <= 1_000_000 { result["entry"] = journalPayload(entry) }
            else { outcome = "rejected"; result["error"] = "This transcript is over the 1 MB editor limit." }
        } else { result["error"] = "This entry is unavailable or excluded on your phone." }
        let response = try WebSessionProtocol.seal(JSONSerialization.data(withJSONObject: result), key: session.key, context: context + "/result")
        let body = try JSONSerialization.data(withJSONObject: ["status": outcome, "result": response.base64EncodedString()])
        _ = try await request(session, path: "/note/" + edit.id, method: "POST", body: body)
    }
    private func receiveUnits(_ plaintext: Data, edit: Edit, session: Session, state: AppState, context: String) async throws {
        var status = "rejected"
        var result: [String: Any] = [:]
        do {
            let operation = try JSONDecoder().decode(JournalUnits.Submission.self, from: plaintext)
            guard let entry = try state.memory.get(key: operation.key),
                  state.journals.contains(where: { $0.key == entry.key }),
                  !state.excludedMemoryKeys.contains(entry.key), AppState.softDeletedKeys()[entry.key] == nil else {
                throw PublishingError.message("This entry is unavailable on your phone.")
            }
            guard operation.base == WebSessionProtocol.digest(Data(entry.content.utf8)) else {
                throw PublishingError.message("This journal changed. Organize its current version again.")
            }
            let record = try operation.record(source: journalPayload(entry)["text"] ?? "")
            try state.saveJournalUnits(record, key: entry.key)
            status = "saved"; result = ["key": entry.key, "revision": record.revision]
        } catch { result["error"] = error.localizedDescription }
        let response = try WebSessionProtocol.seal(JSONSerialization.data(withJSONObject: result), key: session.key, context: context + "/result")
        let body = try JSONSerialization.data(withJSONObject: ["status": status, "result": response.base64EncodedString()])
        _ = try await request(session, path: "/note/" + edit.id, method: "POST", body: body)
    }
    private func receive(_ transfer: Transfer, session: Session, state: AppState) async throws {
        guard WebSessionProtocol.validID(transfer.id), transfer.bytes > 28, transfer.bytes <= 50 * 1024 * 1024 + 28,
              let sealedMeta = Data(base64Encoded: transfer.meta) else { throw PublishingError.message("Invalid transfer.") }
        let context = session.id + "/" + transfer.id
        let metadata = try JSONDecoder().decode(Metadata.self, from: WebSessionProtocol.open(sealedMeta, key: session.key, context: context + "/meta"))
        let encrypted = try await request(session, path: "/file/" + transfer.id)
        guard encrypted.count == transfer.bytes else { throw PublishingError.message("Incomplete file. Retry while connected.") }
        let data = try WebSessionProtocol.open(encrypted, key: session.key, context: context + "/file")
        let title = String(URL(fileURLWithPath: metadata.name).deletingPathExtension().lastPathComponent.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        if metadata.type == "text" {
            guard let text = JournalTextImport.decode(data) else { throw PublishingError.message("Text must be UTF-8 and at most \(JournalTextImport.maximumBytes / 1024) KB.") }
            let key = "journal_import_" + WebSessionProtocol.digest(Data(text.utf8))
            if try state.memory.get(key: key) == nil {
                try state.memory.store(key: key, content: title + "\n\n" + text, category: "daily", sessionID: nil, source: "text_import", mediaURL: nil)
            }
        } else if metadata.type == "audio" {
            let ext = URL(fileURLWithPath: metadata.name).pathExtension.lowercased()
            guard ["m4a", "mp3", "wav", "aac", "aiff", "caf", "flac"].contains(ext) else { throw PublishingError.message("Unsupported audio format.") }
            let hash = WebSessionProtocol.digest(data), key = "journal_web_audio_" + hash
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = docs.appendingPathComponent("ImportedAudio", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("web-" + hash + "." + ext)
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: [.atomic, .completeFileProtection]) }
            let audio = try AVAudioFile(forReading: file)
            guard audio.length > 0 else { throw PublishingError.message("This file contains no decodable audio.") }
            let path = "ImportedAudio/" + file.lastPathComponent
            if try state.memory.get(key: key) == nil {
                try state.memory.store(key: key, content: title + "\n\n" + AppState.transcribingPlaceholder,
                                       category: "daily", sessionID: nil, source: "audio_imported", mediaURL: path)
            }
            if AppState.needsTranscript(try state.memory.get(key: key)?.content) {
                guard await state.enqueuePendingTranscription(key: key, mediaPath: path, drainNow: false) else { throw PublishingError.message("Could not save the transcription queue. Retry.") }
                Task { await state.drainPendingTranscriptions() }
            }
        } else { throw PublishingError.message("Unsupported file type.") }
        // Only acknowledge after the durable SQLite row AND audio/transcription
        // intent exist. Content-derived keys make crash/retry imports idempotent.
        _ = try await request(session, path: "/file/" + transfer.id, method: "POST")
    }
}

struct WebCompanionView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var web = WebCompanion.shared
    @State private var scanning = false
    @State private var pairing: WebSessionProtocol.Pairing?
    @State private var pendingPairing: WebSessionProtocol.Pairing?
    @State private var problem: String?
    @State private var confirmDisconnect = false
    var body: some View {
        Form {
            Section {
                Text("Write journals on your laptop and edit notes or transcripts.")
                Link("Open SlowClaw Web", destination: URL(string: WebSessionProtocol.origin)!)
                if web.session == nil {
                    Button { scanning = true } label: { Label("Scan web sign-in code", systemImage: "qrcode.viewfinder") }
                    Text("Open the site on your laptop, show its QR code, then scan it here. Set up your Nostr identity in Username & description first.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label(web.session?.pair == nil ? "Browser paired" : "Pairing not finished", systemImage: "laptopcomputer")
                    if let date = web.lastSync { Text("Last sync: \(date.formatted(date: .omitted, time: .shortened))").font(.footnote) }
                    Button("Sync now") { Task { await web.sync(state: state) } }.disabled(web.busy)
                    Button("Disconnect & delete web session", role: .destructive) { confirmDisconnect = true }.disabled(web.busy)
                }
                if web.busy { ProgressView("Syncing…") }
                if let message = web.message { Text(message).font(.footnote) }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            Section("Temporary by design") {
                Text("Your journal index, recent text, requested older entries, selected moment excerpts and current Pulse are encrypted for this browser. Audio recordings and your Nostr secret key stay on this iPhone.")
                Text("Keep SlowClaw open to save browser edits and receive laptop uploads. Files marked Saved on phone stay here after logout. Sessions expire after 24 hours; logging out deletes pending uploads too.")
            }.font(.footnote)
        }.navigationTitle("SlowClaw Web")
        .sheet(isPresented: $scanning, onDismiss: {
            pairing = pendingPairing
            pendingPairing = nil
        }) {
            NavigationStack { WebQRScanner { value in
                do { pendingPairing = try WebSessionProtocol.pairing(value); problem = nil }
                catch { pendingPairing = nil; problem = error.localizedDescription }
                scanning = false
            }.ignoresSafeArea(edges: .bottom).navigationTitle("Scan laptop QR code")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
        .confirmationDialog("Connect this browser?", isPresented: Binding(get: { pairing != nil }, set: { if !$0 { pairing = nil } }), titleVisibility: .visible) {
            if let next = pairing { Button("Connect journal workspace") { pairing = nil; Task { await web.connect(next, state: state) } } }
            Button("Cancel", role: .cancel) { pairing = nil }
        } message: { Text("Only approve a code displayed on your own laptop at slowclaw-web.zanynik.chatgpt.site. This browser can read and edit journals and transcripts, create text entries and send imports until logout or expiry. Your Nostr signing key stays here.") }
        .confirmationDialog("Delete this web session?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect & delete", role: .destructive) { Task { await web.disconnect() } }
        } message: { Text("Uploads not yet received by this iPhone will be deleted. Check the browser transfer list first. Files already saved here are kept.") }
    }
}

private struct WebQRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(scanned: scanned) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        let capture = AVCaptureSession()
        private let cameraQueue = DispatchQueue(label: "com.slowclaw.web.camera")
        let scanned: (String) -> Void
        var preview: AVCaptureVideoPreviewLayer?
        var delivered = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            Task { @MainActor in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard viewIfLoaded?.window != nil else { return }
                guard allowed, let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), capture.canAddInput(input) else { showError(); return }
                capture.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard capture.canAddOutput(output) else { showError(); return }
                capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill
                view.layer.addSublayer(layer); preview = layer; layer.frame = view.bounds
                let capture = self.capture
                cameraQueue.async { capture.startRunning() }
            }
        }
        private func showError() {
            let label = UILabel(); label.text = "Camera access is needed to scan the code. Enable Camera for SlowClaw in Settings."; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 30, dy: 100); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); let capture = self.capture; cameraQueue.async { capture.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = object.stringValue else { return }
            delivered = true; scanned(value)
        }
    }
}
