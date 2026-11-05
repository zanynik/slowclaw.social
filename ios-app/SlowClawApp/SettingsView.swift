import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var local: LocalServer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("slowclaw.open-into-recording") private var openIntoRecording = false
    @State private var email = ""
    @State private var password = ""
    @State private var useEmail = false
    @State private var busy = false
    @State private var message: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                syncSection
                browserSection
                Section {
                    NavigationLink {
                        IdentityView()
                    } label: {
                        LabeledContent("Nostr identity", value: NostrIdentity.npub.map { String($0.prefix(14)) + "…" } ?? "Not set up")
                    }
                } footer: {
                    Text("Created on this iPhone and kept in your iCloud Keychain. It signs you in to browsers by QR code.")
                }

                Section {
                    Toggle("Open straight into recording", isOn: $openIntoRecording)
                    Toggle("Organize new entries automatically", isOn: Binding(
                        get: { processor.autoOrganize },
                        set: { processor.autoOrganize = $0 }))
                } header: {
                    Text("Capture")
                } footer: {
                    Text(OnDeviceAI.unavailableReason ?? "Cleanup, organizing, the book and news summaries run on this iPhone with Apple Intelligence.")
                }

                Section("On this iPhone") {
                    LabeledContent("Journal entries", value: "\(store.visibleJournals.count)")
                    LabeledContent("Spaces", value: "\(store.visibleSpaces.count)")
                    LabeledContent("Book passages", value: "\(BookStore.shared.passages.count)")
                    LabeledContent("Open to-dos", value: "\(store.items.filter { !$0.deleted && $0.kind == .todo && !$0.done }.count)")
                    ShareLink(item: exportText()) {
                        Label("Export all journals as text", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) { BrowserSignInSheet() }
        }
    }

    // MARK: - Sync

    @ViewBuilder private var syncSection: some View {
        Section {
            if cloud.session != nil {
                LabeledContent("Signed in", value: cloud.accountLabel)
                HStack {
                    Button("Sync now") { Task { await cloud.sync() } }
                        .disabled(cloud.syncing)
                    Spacer()
                    if cloud.syncing { ProgressView() }
                    else if let last = cloud.lastSynced {
                        Text(last.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = cloud.status {
                    Text(status).font(.footnote).foregroundStyle(.orange)
                }
                Link("Open slowclaw.social", destination: URL(string: "https://slowclaw.social")!)
                Button("Sign out", role: .destructive) { cloud.signOut() }
            } else {
                Button {
                    run { try await cloud.signInWithKey() }
                } label: {
                    Label("Turn on sync with this iPhone", systemImage: "key")
                }
                .disabled(busy)
                DisclosureGroup("Use email and password instead", isExpanded: $useEmail) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    HStack {
                        Button("Sign in") { run { try await cloud.signIn(email: email, password: password) } }
                        Spacer()
                        Button("Create account") {
                            run {
                                let immediate = try await cloud.signUp(email: email, password: password)
                                if !immediate { message = "Check your email to confirm, then sign in here." }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy || email.isEmpty || password.count < 6)
                    Button("Forgot password") {
                        run {
                            try await cloud.sendPasswordReset(email: email)
                            message = "Password reset email sent."
                        }
                    }
                    .font(.footnote)
                    .disabled(busy || email.isEmpty)
                }
                if busy { ProgressView() }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Cloud sync")
        } footer: {
            Text(cloud.session == nil
                 ? "Syncs journals, spaces, lists and your book as text, so you can use slowclaw.social. Recordings stay on this iPhone. Already have an email account? Sign in with it to keep your data."
                 : "Only text is synced. Recordings stay on this iPhone.")
        }
    }

    // MARK: - Browsers

    @ViewBuilder private var browserSection: some View {
        Section {
            Button {
                scanning = true
            } label: {
                Label("Scan a browser's sign-in code", systemImage: "qrcode.viewfinder")
            }
            Toggle("View on a computer, without the cloud", isOn: Binding(get: { local.enabled }, set: { local.enabled = $0 }))
            if local.enabled {
                if local.running {
                    if local.addresses.isEmpty {
                        Text("Connect this iPhone to Wi-Fi to get an address.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(local.addresses, id: \.self) { address in
                        let url = "http://\(address):\(LocalServer.port)"
                        HStack {
                            Text(url).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button { UIPasteboard.general.string = url } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Copy address")
                        }
                    }
                } else if let error = local.error {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
                if local.pairedCount > 0 {
                    Button("Forget \(local.pairedCount) paired \(local.pairedCount == 1 ? "browser" : "browsers")", role: .destructive) {
                        local.forgetBrowsers()
                    }
                }
            }
        } header: {
            Text("Browsers")
        } footer: {
            Text(local.enabled
                 ? "Open the address on a computer on the same Wi-Fi, then scan the code it shows. Your journals go straight from this iPhone to that browser and nowhere else. Keep SlowClaw open while you use it, and use a network you trust."
                 : "Sign in at slowclaw.social by scanning its code, or turn on the local view to browse on a bigger screen with nothing going online.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do { try await action() } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func exportText() -> String {
        store.visibleJournals.filter { $0.status == .ready }.map { j in
            let space = store.space(j.spaceID)?.name ?? "Unsorted"
            return "# \(j.displayTitle)\n\(j.createdAt.formatted(date: .long, time: .shortened)) · \(space)\n\n\(j.body)"
        }.joined(separator: "\n\n---\n\n")
    }
}

struct IdentityView: View {
    @State private var revealed: String?
    @State private var confirmReveal = false
    @State private var restoring = false
    @State private var restoreText = ""
    @State private var message: String?
    @State private var npub = NostrIdentity.npub

    var body: some View {
        Form {
            Section {
                if let npub {
                    Text(npub).font(.callout.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = npub } label: { Label("Copy public key", systemImage: "doc.on.doc") }
                } else {
                    Text("Could not read the key from the Keychain.").foregroundStyle(.orange)
                }
            } header: {
                Text("Public key (npub)")
            } footer: {
                Text("Safe to share. It identifies you on Nostr.")
            }

            Section {
                if let revealed {
                    Text(revealed).font(.callout.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = revealed } label: { Label("Copy secret key", systemImage: "doc.on.doc") }
                } else {
                    Button("Show secret key…") { confirmReveal = true }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("The key is saved in your iCloud Keychain, so a new iPhone signed in to the same Apple Account gets it back. For an extra copy, keep the secret key (nsec) in a password manager. Anyone with it can act as you.")
            }

            Section {
                if restoring {
                    TextField("nsec1…", text: $restoreText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                    Button("Use this key", role: .destructive) {
                        do {
                            try NostrIdentity.restore(restoreText)
                            npub = NostrIdentity.npub
                            UserDefaults.standard.removeObject(forKey: "slowclaw.nostr.linked-account")
                            message = "Key restored. It will be linked to your account on the next sync."
                            restoring = false; restoreText = ""; revealed = nil
                        } catch { message = error.localizedDescription }
                    }
                } else {
                    Button("Restore from a backup key…") { restoring = true }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Nostr identity")
        .confirmationDialog("Show the secret key?", isPresented: $confirmReveal, titleVisibility: .visible) {
            Button("Show") { revealed = try? NostrIdentity.nsec() }
        } message: {
            Text("Make sure nobody can see your screen.")
        }
    }
}
