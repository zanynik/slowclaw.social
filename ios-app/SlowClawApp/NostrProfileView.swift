import SwiftUI

struct NostrProfileView: View {
    let pubkey: String
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var social = NostrSocialStore.shared
    @State private var loading = false
    @State private var error: String?
    private var posts: [PublishedEvent] { social.authorPosts[pubkey] ?? [] }
    private var ownKey: String? { try? NostrIdentity.publicKey(NostrIdentity.secret()) }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        AsyncImage(url: social.profile(pubkey)?.picture) { image in image.resizable().scaledToFill() } placeholder: {
                            Image(systemName: "person.circle.fill").resizable().foregroundStyle(.secondary)
                        }.frame(width: 72, height: 72).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(social.name(pubkey)).font(.title2.bold())
                            if let name = social.profile(pubkey)?.name, !name.isEmpty { Text("@" + name).foregroundStyle(.secondary) }
                        }
                    }
                    if let about = social.profile(pubkey)?.about, !about.isEmpty { NostrPostContent(content: about) }
                    if ownKey != pubkey {
                        Button(social.isFollowing(pubkey) ? "Unfollow" : "Follow", systemImage: social.isFollowing(pubkey) ? "person.badge.minus" : "person.badge.plus") {
                            let following = !social.isFollowing(pubkey)
                            Task {
                                do {
                                    try await social.setFollowing(pubkey, following: following)
                                    error = nil
                                    await state.loadReads(force: true)
                                } catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(.borderedProminent).disabled(!social.followsReady || social.followBusy)
                            .accessibilityIdentifier("nostr.profile.follow")
                        if let status = social.followStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                            Button("Retry follow list") { Task { await social.loadFollows() } }
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if let bytes = NostrEventVerifier.bytes(pubkey, count: 32) {
                        let npub = Nip19.encodeKey(bytes, prefix: "npub")
                        Text(npub).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                        ShareLink(item: URL(string: "https://njump.me/" + npub)!) { Label("Share profile", systemImage: "square.and.arrow.up") }
                    }
                    Text("Recent posts").font(.headline)
                    if loading { ProgressView("Loading posts…") }
                    ForEach(posts) { post in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Date(timeIntervalSince1970: Double(post.created_at)), style: .date).font(.caption).foregroundStyle(.secondary)
                            if post.kind == 30023 { Text(post.displayTitle).font(.headline) }
                            NostrPostContent(content: post.content, tags: post.tags, lineLimit: 12)
                            NavigationLink("Open conversation") { NostrPostDetail(post: post) }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    if let status = social.authorStatus[pubkey] { Text(status).font(.caption).foregroundStyle(.secondary) }
                    if !posts.isEmpty && posts.count < 120 {
                        Button("Older posts") { Task { await load(before: max(0, (posts.last?.created_at ?? 0) - 1)) } }.disabled(loading)
                    } else if posts.isEmpty && !loading { Text("No public posts found yet.").foregroundStyle(.secondary) }
                }.padding(20)
            }.navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await load(); await social.loadFollows() }
                .refreshable { await load(); await social.loadFollows() }
        }
    }
    private func load(before: Int? = nil) async {
        guard !loading else { return }
        loading = true
        await social.loadAuthor(pubkey, before: before)
        loading = false
    }
}
