import SwiftUI

@MainActor
final class NostrInbox: ObservableObject {
    static let shared = NostrInbox()
    @Published var posts: [PublishedEvent] = []
    @Published var events: [PublishedEvent] = []
    @Published var busy = false
    @Published var status: String?
    @Published var seen = Set(UserDefaults.standard.stringArray(forKey: "slowclaw.nostr.seen-replies") ?? [])
    @Published var hiddenAuthors = Set(UserDefaults.standard.stringArray(forKey: "slowclaw.nostr.hidden-authors") ?? [])
    private var author: String?
    private var loaded = false

    func replies(to post: PublishedEvent) -> [PublishedEvent] {
        NostrConversationRules.replies(events.filter { !hiddenAuthors.contains($0.pubkey) }, to: post)
    }
    func unread(_ post: PublishedEvent) -> Int { replies(to: post).filter { !seen.contains($0.id) && $0.pubkey != author }.count }
    func markRead(_ post: PublishedEvent) {
        seen.formUnion(replies(to: post).map(\.id))
        // Retain a bounded, deterministic set of the latest seen event IDs.
        let known = events.sorted { $0.created_at > $1.created_at }.map(\.id).filter { seen.contains($0) }
        let old = seen.subtracting(known).sorted()
        seen = Set((known + old).prefix(1000))
        UserDefaults.standard.set(seen.sorted(), forKey: "slowclaw.nostr.seen-replies")
    }
    func hide(_ pubkey: String) {
        hiddenAuthors.insert(pubkey)
        UserDefaults.standard.set(hiddenAuthors.sorted(), forKey: "slowclaw.nostr.hidden-authors")
    }
    func resetHidden() {
        hiddenAuthors = []
        UserDefaults.standard.removeObject(forKey: "slowclaw.nostr.hidden-authors")
    }
    func refresh(force: Bool = false, post: PublishedEvent? = nil) async {
        guard !busy else { return }
        do {
            let key = try NostrIdentity.publicKey(NostrIdentity.secret())
            if key != author { author = key; posts = []; events = []; loaded = false }
            posts = NostrConversationRules.mergedPosts(posts + NostrPublisher.confirmedEvents(), author: key)
            guard force || !loaded else { return }
            busy = true
            defer { busy = false }
            let relays = NostrPublisher.relayText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if post == nil {
                status = "Checking your public posts…"
                let batch = await NostrConversations.shared.fetch(author: key, posts: [], relays: relays, includePosts: true)
                posts = Array(NostrConversationRules.mergedPosts(posts + batch.events, author: key).prefix(200))
                if posts.isEmpty {
                    status = batch.completed == 0 ? "Relays could not finish loading. Pull to retry." : "No posts found on these relays yet."
                    loaded = batch.completed > 0
                    return
                }
            }
            status = "Checking replies and likes…"
            let batch = await NostrConversations.shared.fetch(author: key, posts: post.map { [$0] } ?? Array(posts.prefix(20)), relays: relays, includePosts: false)
            var ids = Set<String>()
            events = Array((events + batch.events).sorted { $0.created_at > $1.created_at }
                .filter { ids.insert($0.id).inserted }.prefix(600))
            status = batch.completed == 0 ? "Replies may be incomplete. Relays could not finish loading; pull to retry."
                : "Checked \(batch.completed) of \(batch.total) relays. Counts cover fetched events, not all of Nostr."
            loaded = batch.completed > 0
        } catch { status = "Set up your Nostr identity when publishing a draft to see your posts here." }
    }
}

struct NostrPostsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var inbox = NostrInbox.shared
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if inbox.busy { ProgressView("Refreshing conversations…") }
                    if let status = inbox.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Text("Your posts and articles, including those found on your configured relays. Recent conversations are grouped below each post.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let unread = inbox.posts.filter { inbox.unread($0) > 0 }
                if !unread.isEmpty {
                    Section("New replies") { ForEach(unread) { post in postRow(post) } }
                }
                Section("Your publications") {
                    ForEach(inbox.posts.filter { inbox.unread($0) == 0 }) { post in postRow(post) }
                    if inbox.posts.isEmpty && !inbox.busy { Text("Your reviewed, published drafts will appear here.").foregroundStyle(.secondary) }
                }
                if !inbox.hiddenAuthors.isEmpty {
                    Section { Button("Show hidden authors again") { inbox.resetHidden() } }
                }
            }
            .navigationTitle("My Nostr posts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await inbox.refresh() }
            .refreshable { await inbox.refresh(force: true) }
        }
    }
    private func postRow(_ post: PublishedEvent) -> some View {
        NavigationLink { NostrPostDetail(post: post) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(post.displayTitle).lineLimit(3)
                Text(Date(timeIntervalSince1970: Double(post.created_at)), style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                let replies = inbox.replies(to: post).count
                let likes = NostrConversationRules.likes(inbox.events.filter { !inbox.hiddenAuthors.contains($0.pubkey) }, to: post)
                Text("\(replies) replies in thread · \(likes) likes" + (inbox.unread(post) > 0 ? " · \(inbox.unread(post)) new" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
    }
}

private struct NostrPostDetail: View {
    let post: PublishedEvent
    @StateObject private var inbox = NostrInbox.shared
    var body: some View {
        List {
            Section {
                Text(post.content).textSelection(.enabled)
                if let url = URL(string: "https://njump.me/" + post.id) {
                    Link("Open on the web", destination: url)
                    ShareLink(item: url)
                }
            }
            Section("Replies in this conversation") {
                if inbox.busy { ProgressView() }
                ForEach(inbox.replies(to: post)) { reply in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(reply.pubkey.prefix(12)) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(reply.content).textSelection(.enabled)
                        Text(Date(timeIntervalSince1970: Double(reply.created_at)), style: .date).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let url = URL(string: "https://njump.me/" + reply.id) { Link("Open conversation", destination: url) }
                            Spacer()
                            Button("Hide author") { inbox.hide(reply.pubkey) }
                        }.font(.caption)
                    }.padding(.vertical, 5)
                }
                if inbox.replies(to: post).isEmpty && !inbox.busy { Text("No replies found on the checked relays.").foregroundStyle(.secondary) }
                if let status = inbox.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Text("Signatures verify authorship, not accuracy. Open a conversation in another Nostr client to reply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(post.kind == 30023 ? "Your article" : "Your post")
        .task { await inbox.refresh(force: true, post: post); inbox.markRead(post) }
        .refreshable { await inbox.refresh(force: true, post: post); inbox.markRead(post) }
    }
}
