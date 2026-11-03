import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    @EnvironmentObject private var cloud: CloudSync
    @AppStorage("slowclaw.open-into-recording") private var openIntoRecording = false
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let s = cloud.session {
                        LabeledContent("Signed in", value: s.email)
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
                        if busy { ProgressView() }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sign in to see your journals, spaces and lists at slowclaw.social. Only text is synced — recordings stay on this iPhone.")
                }

                Section {
                    Toggle("Open straight into recording", isOn: $openIntoRecording)
                    Toggle("Organize new entries automatically", isOn: Binding(
                        get: { processor.autoOrganize },
                        set: { processor.autoOrganize = $0 }))
                } header: {
                    Text("Capture")
                } footer: {
                    Text(OnDeviceAI.unavailableReason ?? "Cleanup and organizing run on this iPhone with Apple Intelligence.")
                }

                Section("On this iPhone") {
                    LabeledContent("Journal entries", value: "\(store.visibleJournals.count)")
                    LabeledContent("Spaces", value: "\(store.visibleSpaces.count)")
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
