import SwiftUI

struct NostrProfileEditor: View {
    @StateObject private var social = NostrSocialStore.shared
    @StateObject private var publisher = NostrPublisher.shared
    @State private var key: String?
    @State private var name = ""
    @State private var about = ""
    @State private var importKey = ""
    @State private var loading = false
    @State private var ready = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            if let key {
                Section("Your public identity") {
                    NostrAuthorHeader(pubkey: key)
                    if let bytes = NostrEventVerifier.bytes(key, count: 32) {
                        Text(Nip19.encodeKey(bytes, prefix: "npub")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Public profile") {
                    TextField("Username", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("profile.username")
                    TextField("Description", text: $about, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("profile.description")
                    Text("Your name and description are public on Nostr. Names are not unique; your public key identifies you.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(loading || !ready)
                Section {
                    Button(saved ? "Profile published" : "Publish profile") { Task { await save() } }
                        .disabled(!ready || loading || publisher.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || about.count > 2000)
                        .accessibilityIdentifier("profile.publish")
                    if loading { ProgressView("Loading profile…") }
                    if !ready && !loading { Button("Retry loading profile") { Task { await load() } } }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            } else {
                Section("Your Nostr identity") {
                    Text("Use the same identity as your other Nostr apps, or create a new one.")
                    Button("Create a Nostr identity") { setup { try NostrIdentity.create() } }
                    SecureField("Existing nsec / hex secret", text: $importKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use existing identity") {
                        setup {
                            guard let bytes = Nip19.decodeSecret(importKey) else { throw PublishingError.message("Enter a valid nsec or hex secret key.") }
                            try NostrIdentity.install(bytes); importKey = ""
                        }
                    }.disabled(importKey.isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Edit profile")
        .interactiveDismissDisabled(loading || publisher.busy)
        .task { await load() }
        .onChange(of: name) { _, _ in saved = false }
        .onChange(of: about) { _, _ in saved = false }
    }
    private func setup(_ operation: () throws -> Void) {
        do { try operation(); Task { await load() } } catch { self.error = error.localizedDescription }
    }
    private func fetch(_ key: String) async throws -> PublishedEvent? {
        let batch = await NostrConversations.shared.read(filters: [["kinds": [0], "authors": [key], "limit": 1]], relays: NostrSocialStore.relays)
        guard batch.completed > 0 else { throw PublishingError.message("Couldn’t check your existing profile. Retry when connected to preserve your other profile details.") }
        let candidates = batch.events + NostrPublisher.confirmedEvents().filter { $0.kind == 0 && $0.pubkey == key }
            + (social.profiles[key].map { [$0] } ?? [])
        let current = NostrSocialRules.latest(candidates, kind: 0)[key]
        social.mergeProfiles(candidates)
        // Editing must not depend on whether this old profile survives the
        // bounded feed-avatar cache's eviction policy.
        return current
    }
    private func load() async {
        key = try? NostrIdentity.publicKey(NostrIdentity.secret())
        guard let key else { return }
        loading = true; error = nil; ready = false
        defer { loading = false }
        do {
            let current = try await fetch(key)
            if let current, NostrProfile(current) == nil { throw PublishingError.message("Your current profile is malformed. It was not overwritten.") }
            name = current.flatMap(NostrProfile.init)?.name ?? ""
            about = current.flatMap(NostrProfile.init)?.about ?? ""
            ready = true
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let key else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let existing = try await fetch(key)
            let content = try NostrProfile.editedContent(existing: existing, name: name, about: about)
            _ = try await publisher.publish(draftKey: "profile_" + key, content: content, title: "", article: false,
                metadata: true, metadataAfter: existing?.created_at)
            social.mergeProfiles(NostrPublisher.confirmedEvents().filter { $0.kind == 0 && $0.pubkey == key })
            saved = true
        } catch { self.error = error.localizedDescription }
    }
}

struct PulseSourcesView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var social = NostrSocialStore.shared
    @State private var keys = UserDefaults.standard.stringArray(forKey: NostrDiscovery.sourcesKey) ?? []
    @State private var input = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text("Start with popular public posts and their authors’ networks automatically—even before you follow anyone. As your network grows, Pulse mixes in your follows and people they follow, ranked by your journal interests.")
                Text("Popular discovery comes from Primal’s public feed. Your identity and journal interests are not sent to Primal.").font(.caption).foregroundStyle(.secondary)
                Text("Add a public account you trust or find interesting—even a well-known person—to explore their network. This does not follow them publicly.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Additional starting points") {
                ForEach(keys, id: \.self) { key in
                    HStack {
                        NostrAuthorHeader(pubkey: key)
                        Spacer()
                        Button(role: .destructive) { keys.removeAll { $0 == key }; persist() } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove source")
                    }
                }
                TextField("npub or public hex key", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add source") {
                    guard let key = Nip19.decodePublicKey(input) else { error = "Paste a public npub or 64-character public hex key."; return }
                    guard !keys.contains(key), keys.count < 8 else { error = "Use up to eight different starting accounts."; return }
                    keys.append(key); input = ""; error = nil; persist()
                    Task { await social.loadProfiles([key]) }
                }.disabled(input.isEmpty)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }.navigationTitle("Pulse sources")
            .task { await social.loadProfiles(keys) }
    }
    private func persist() {
        UserDefaults.standard.set(keys, forKey: NostrDiscovery.sourcesKey)
        Task { await state.loadReads(force: true) }
    }
}

struct NostrAuthorHeader: View {
    let pubkey: String
    var created: Int? = nil
    @StateObject private var social = NostrSocialStore.shared
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: social.profile(pubkey)?.picture) { image in image.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.fill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }.frame(width: 38, height: 38).clipShape(Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(social.name(pubkey)).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if let name = social.profile(pubkey)?.name, !name.isEmpty { Text("@" + name).lineLimit(1) }
                    else { Text(String(pubkey.prefix(10)) + "…").lineLimit(1) }
                    if let created { Text("·"); Text(Date(timeIntervalSince1970: Double(created)), style: .relative).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
