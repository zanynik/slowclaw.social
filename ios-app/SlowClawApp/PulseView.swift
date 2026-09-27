import SwiftUI
import UIKit

/// Old ranked posts stay visible while a replacement is fetched and ranked.
struct PulseView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var inbox = NostrInbox.shared
    @State private var showConversations = false
    @State private var compose = false
    @State private var latest = false
    @State private var sources = false
    @StateObject private var social = NostrSocialStore.shared
    private var items: [RankedFeedItem] {
        let visible = state.relevantPulse.filter { item in
            guard let event = PulseNote.decode(item) else { return true }
            return !inbox.hiddenAuthors.contains(event.pubkey)
        }
        return latest ? visible.sorted {
            let a = PulseNote.decode($0)?.created_at ?? 0, b = PulseNote.decode($1)?.created_at ?? 0
            return a == b ? $0.id < $1.id : a > b
        } : visible
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    Picker("Timeline", selection: $latest) {
                        Text("For you").tag(false)
                        Text("Latest").tag(true)
                    }.pickerStyle(.segmented).padding()
                    Text("Conversations picked for you").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
                    if items.isEmpty {
                        ContentUnavailableView("Find your conversations", systemImage: "bubble.left.and.bubble.right",
                            description: Text("Relevant Nostr posts appear here as you journal. Pull to refresh."))
                    }
                    if let status = state.pulseSnapshotError {
                        Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    ForEach(items) { item in
                        PulseRow(item: item)
                        Divider().padding(.leading, 64)
                    }
                }.padding(.bottom, 72)
            }
            .navigationTitle("Pulse").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { sources = true } label: { Image(systemName: "person.2") }.accessibilityLabel("Pulse sources")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showConversations = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .accessibilityLabel("My posts and replies")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { compose = true } label: {
                    Image(systemName: "square.and.pencil").font(.title2).padding(18)
                        .foregroundStyle(.white).background(DS.accentColor, in: Circle()).shadow(radius: 3, y: 2)
                }.padding().accessibilityLabel("Write a post")
            }
            .sheet(isPresented: $showConversations) { NostrPostsView() }
            .sheet(isPresented: $sources) { NavigationStack { PulseSourcesView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sources = false } } } } }
            .sheet(isPresented: $compose) { PulseComposer() }
            .refreshable { await state.loadReads(force: true); await social.load(items.compactMap(PulseNote.decode), force: true) }
            .task { await state.loadReads() }
            .task(id: items.map(\.id).sorted().joined()) { await social.load(items.compactMap(PulseNote.decode)) }
        }
    }
}

enum PulseNote {
    // Already verified at ingestion. Re-verify before any signing action in
    // NostrReply.envelope; this bounded decode only supplies presentation data.
    static func decode(_ item: RankedFeedItem) -> PublishedEvent? {
        guard let raw = item.nostrEventJSON, raw.utf8.count <= 128_000,
              let event = try? JSONDecoder().decode(PublishedEvent.self, from: Data(raw.utf8)),
              event.kind == 1, "nostr:" + event.id == item.id else { return nil }
        return event
    }
}

struct PulseRow: View {
    @EnvironmentObject var state: AppState
    @StateObject private var inbox = NostrInbox.shared
    @StateObject private var social = NostrSocialStore.shared
    let item: RankedFeedItem
    @State private var expanded = false
    @State private var showReplies = false
    @State private var replyTarget: PublishedEvent?
    @State private var conversation = false
    private var event: PublishedEvent? { PulseNote.decode(item) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if let event { NostrAuthorHeader(pubkey: event.pubkey, created: event.created_at) }
                else { Label("Nostr", systemImage: "person.circle") }
                Spacer(minLength: 0)
                Menu {
                    Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.description }
                    if let event {
                        Button("Mute author") { inbox.hide(event.pubkey) }
                        if let bytes = NostrEventVerifier.bytes(event.pubkey, count: 32) {
                            Button("Copy author’s public key") { UIPasteboard.general.string = Nip19.encodeKey(bytes, prefix: "npub") }
                        }
                        Button("Use author as a discovery source") {
                            var sources = UserDefaults.standard.stringArray(forKey: NostrDiscovery.sourcesKey) ?? []
                            if !sources.contains(event.pubkey) && sources.count < 8 {
                                sources.append(event.pubkey); UserDefaults.standard.set(sources, forKey: NostrDiscovery.sourcesKey)
                                Task { await state.loadReads(force: true) }
                            }
                        }
                    }
                    Button("Less like this") { state.rememberArticle(item, preference: -1) }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .accessibilityLabel("Post actions")
            }
            Text(item.description).font(.body).lineLimit(expanded ? nil : 8).textSelection(.enabled)
            if item.description.count > 300 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.subheadline)
            }
            if let event {
                let replies = social.replies(event, hidden: inbox.hiddenAuthors)
                let known = social.events[event.id] != nil
                let likes = NostrConversationRules.likes((social.events[event.id] ?? []).filter { !inbox.hiddenAuthors.contains($0.pubkey) }, to: event)
                HStack {
                    Label(known ? "\(likes)" : "—", systemImage: "heart")
                        .accessibilityLabel(known ? "\(likes) likes found" : "Likes loading")
                    Spacer()
                    Button { showReplies.toggle(); if !known { Task { await social.load([event], force: true) } } } label: {
                        Label(known ? "\(replies.count)" : "—", systemImage: "bubble.left.and.bubble.right")
                    }.accessibilityLabel("Show replies").accessibilityIdentifier("pulse.replies." + event.id)
                    Spacer()
                    Button { replyTarget = event } label: { Image(systemName: "arrowshape.turn.up.left") }.accessibilityLabel("Reply")
                    Spacer()
                    if let url = URL(string: item.link) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share post")
                    }
                }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.borderless)
                if !replies.isEmpty || showReplies {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(replies.prefix(showReplies ? 20 : 2))) { reply in
                            VStack(alignment: .leading, spacing: 6) {
                                NostrAuthorHeader(pubkey: reply.pubkey, created: reply.created_at)
                                if let parent = NostrSocialRules.parent(reply), parent != event.id {
                                    Text("Reply in thread").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(reply.content).font(.subheadline).lineLimit(showReplies ? nil : 3)
                                Button("Reply") { replyTarget = reply }.font(.caption)
                            }.accessibilityIdentifier("pulse.reply." + reply.id)
                        }
                        if replies.count > 2 {
                            Button(showReplies ? "Collapse replies" : "View \(replies.count) replies") { showReplies.toggle() }
                                .font(.caption.weight(.medium))
                        }
                        if showReplies {
                            if replies.isEmpty { Text(known ? "No replies found yet." : "Loading replies…").font(.caption).foregroundStyle(.secondary) }
                            Button(social.coverage[event.id] ?? "Load replies and likes") { Task { await social.load([event], force: true) } }
                                .font(.caption2).foregroundStyle(.secondary)
                            Button("Open full conversation") { conversation = true }.font(.caption)
                        }
                    }.padding(.leading, 14).padding(.vertical, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
        .sheet(item: $replyTarget, onDismiss: { if let event { Task { await social.load([event], force: true) } } }) { target in
            if let event { NostrReplySheet(root: event, parent: target) }
        }
        .sheet(isPresented: $conversation) { if let event { NavigationStack { NostrPostDetail(post: event) } } }
    }
}

private struct PulseComposer: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("slowclaw.pulse.unsent-text.v1") private var text = ""
    @AppStorage("slowclaw.pulse.unsent-key.v1") private var draftKey = ""
    @State private var review = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $text).font(.body).focused($focused)
                HStack { Text("\(text.count) characters").font(.caption).foregroundStyle(.secondary); Spacer(); CopyTextButton(text: text) }
                if text.utf8.count > 8000 { Text("Shorten this post before publishing.").foregroundStyle(.red).font(.caption) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding().navigationTitle("New post").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Review") {
                            do {
                                try state.memory.store(key: draftKey, content: text, category: "custom", sessionID: "drafts", source: "pulse", mediaURL: nil)
                                focused = false; review = true
                            } catch { self.error = "Could not save your draft. Please retry." }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 8000)
                    }
                }
                .sheet(isPresented: $review, onDismiss: {
                    Task { await state.refreshJournals() }
                    if UserDefaults.standard.string(forKey: "slowclaw.nostr.receipt." + draftKey) != nil { text = ""; draftKey = ""; dismiss() }
                }) { PublishDraftSheet(draftKey: draftKey, content: text, article: false) }
                .onAppear { if draftKey.isEmpty { draftKey = "pulse_" + UUID().uuidString }; focused = true }
        }
    }
}
