import SwiftUI
import AVKit

struct PublishDraftSheet: View {
    let draftKey: String
    let content: String
    let article: Bool
    var contentHasTitle = false
    var mediaURL: URL? = nil
    var validate: (() throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var publisher = NostrPublisher.shared
    @State private var identity: String?
    @State private var importKey = ""
    @State private var backup: String?
    @State private var error: String?
    @State private var published = false
    @State private var relays = NostrPublisher.relayText
    @State private var acknowledge = false
    @State private var mediaServer = NostrMedia.server
    @State private var uploadedMedia: URL?
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What will be public") {
                    Text(content).textSelection(.enabled)
                    if let mediaURL {
                        if mediaURL.pathExtension == "png", let image = UIImage(contentsOfFile: mediaURL.path) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                        } else { VideoPlayer(player: AVPlayer(url: mediaURL)).frame(height: 220) }
                    }
                    Text(mediaURL == nil
                        ? "Only this draft is sent. Your source journals and recordings stay private. Public posts may be copied by others and cannot be reliably recalled."
                        : "This exported card or clip will be uploaded publicly to the media server below, then linked in your Nostr post. Your full journal and recording stay private.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Your Nostr identity") {
                    if let identity {
                        Text(identity).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Show recovery key") {
                            do { backup = Nip19.encodeKey(try NostrIdentity.secret(), prefix: "nsec") }
                            catch { self.error = error.localizedDescription }
                        }
                        if let backup {
                            Text("Keep this secret. It controls your account and lets you use any Nostr app.").font(.caption)
                            Text(backup).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Hide recovery key") { self.backup = nil }
                        }
                    } else {
                        Button("Create a Nostr identity") { setup { try NostrIdentity.create() } }
                        SecureField("Or paste an existing nsec / hex secret", text: $importKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Use existing identity") {
                            setup {
                                guard let key = Nip19.decodeSecret(importKey) else { throw PublishingError.message("Enter a valid nsec or 64-character hex secret key.") }
                                try NostrIdentity.install(key)
                                importKey = ""
                            }
                        }.disabled(importKey.isEmpty)
                    }
                }
                if mediaURL != nil {
                    Section("Media server") {
                        TextField("HTTPS Blossom server", text: $mediaServer)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(submitting || uploadedMedia != nil)
                        if uploadedMedia != nil { Text("Media uploaded. Retry publishes the same link.").font(.caption) }
                    }
                }
                Section("Relays") {
                    TextEditor(text: $relays).frame(minHeight: 70).font(.caption.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text("Use your preferred Nostr relays, one wss:// address per line.").font(.caption)
                }
                Section {
                    Toggle("I reviewed this draft for public sharing", isOn: $acknowledge)
                    Button {
                        NostrPublisher.relayText = relays
                        submitting = true; error = nil
                        Task {
                            defer { submitting = false }
                            do {
                                try validate?()
                                if let mediaURL, uploadedMedia == nil {
                                    NostrMedia.server = mediaServer
                                    uploadedMedia = try await NostrMedia.upload(mediaURL, server: mediaServer)
                                }
                                try validate?()
                                let body = article && contentHasTitle ? journalBodyOf(content) : content
                                let post = body + (uploadedMedia.map { "\n\n" + $0.absoluteString } ?? "")
                                _ = try await publisher.publish(draftKey: draftKey,
                                    content: post,
                                    title: String((content.components(separatedBy: "\n").first ?? "Reflection").prefix(120)),
                                    article: article)
                                published = true
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Label(published ? "Published" : submitting ? "Publishing…" : "Publish to Nostr",
                              systemImage: published ? "checkmark.circle.fill" : "paperplane.fill")
                    }.disabled(identity == nil || !acknowledge || publisher.busy || submitting || published)
                    if let status = publisher.status { Text(status).font(.caption) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(article ? "Publish article" : "Publish post")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(submitting) } }
            .interactiveDismissDisabled(submitting)
            .task { identity = try? NostrIdentity.publicKey(NostrIdentity.secret()) }
        }
    }

    private func setup(_ operation: () throws -> Void) {
        do { try operation(); identity = try NostrIdentity.publicKey(NostrIdentity.secret()); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
