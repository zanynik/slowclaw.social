import SwiftUI
import UIKit

/// Old ranked posts stay visible while a replacement is fetched and ranked.
struct PulseView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var inbox = NostrInbox.shared
    @State private var showConversations = false
    @State private var compose = false
    @State private var latest = false
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
            .sheet(isPresented: $compose) { PulseComposer() }
            .refreshable { Task { await state.loadReads(force: true) } }
            .task { await state.loadReads() }
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

private struct PulseRow: View {
    @EnvironmentObject var state: AppState
    @StateObject private var inbox = NostrInbox.shared
    let item: RankedFeedItem
    @State private var expanded = false
    @State private var reply = false
    @State private var conversation = false
    private var event: PublishedEvent? { PulseNote.decode(item) }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.fill").font(.title3).foregroundStyle(DS.accentColor)
                .frame(width: 40, height: 40).background(DS.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let event {
                        Text(String(event.pubkey.prefix(8)) + "…" + String(event.pubkey.suffix(4)))
                            .font(.subheadline.monospaced()).lineLimit(1)
                        Text("·").foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: Double(event.created_at)), style: .relative)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else { Text("Nostr").font(.subheadline) }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.description }
                        if let event { Button("Mute author") { inbox.hide(event.pubkey) } }
                        Button("Less like this") { state.rememberArticle(item, preference: -1) }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                        .accessibilityLabel("Post actions")
                }
                Text(item.description).font(.body).lineLimit(expanded ? nil : 8).textSelection(.enabled)
                if item.description.count > 300 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.subheadline)
                }
                HStack {
                    Button { if event != nil { reply = true } else { state.openArticle(item) } } label: {
                        Label("Reply", systemImage: "bubble.left")
                    }
                    Spacer()
                    Button { if event != nil { conversation = true } else { state.openArticle(item) } } label: {
                        Image(systemName: "text.bubble")
                    }.accessibilityLabel("Open conversation")
                    Spacer()
                    if let url = URL(string: item.link) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share post")
                    }
                    Spacer()
                    CopyTextButton(text: item.description)
                }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.borderless)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
        .sheet(isPresented: $reply) { if let event { NostrReplySheet(root: event, parent: event) } }
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
