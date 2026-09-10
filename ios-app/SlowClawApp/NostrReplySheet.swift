import SwiftUI

struct NostrReplySheet: View {
    let root: PublishedEvent
    let parent: PublishedEvent
    @Environment(\.dismiss) private var dismiss
    @StateObject private var publisher = NostrPublisher.shared
    @State private var text = ""
    @State private var draftID = UUID().uuidString
    @State private var error: String?
    @State private var sent = false
    private var storageKey: String { "slowclaw.nostr.reply-draft." + root.id + "." + parent.id }
    var body: some View {
        NavigationStack {
            Form {
                Section("Replying to") {
                    Text(parent.content).lineLimit(5).font(.callout).foregroundStyle(.secondary)
                    Text(String(parent.pubkey.prefix(12)) + "…").font(.caption.monospaced())
                }
                Section("Your reply") {
                    TextEditor(text: $text).frame(minHeight: 150).disabled(publisher.busy || sent)
                    Text("This reply will be public on Nostr. No journals or recordings are attached.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(sent ? "Published" : publisher.busy ? "Publishing…" : "Publish reply") {
                        Task {
                            do {
                                _ = try await publisher.publish(draftKey: "reply_" + draftID, content: text,
                                    title: "", article: false, replyRoot: root, replyParent: parent)
                                sent = true
                                UserDefaults.standard.removeObject(forKey: storageKey)
                                await NostrInbox.shared.refresh(force: true, post: root)
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(publisher.busy || sent || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 8000)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let status = publisher.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Reply")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(publisher.busy) } }
            .interactiveDismissDisabled(publisher.busy)
            .onAppear {
                if let saved = UserDefaults.standard.dictionary(forKey: storageKey),
                   let id = saved["id"] as? String, let content = saved["content"] as? String {
                    draftID = id; text = content
                }
            }
            .onChange(of: text) { _, value in
                guard !sent else { return }
                UserDefaults.standard.set(["id": draftID, "content": String(value.prefix(8000))], forKey: storageKey)
            }
        }
    }
}
