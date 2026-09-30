import SwiftUI
import AVKit
import LinkPresentation

struct NostrPostContent: View {
    let content: String
    var tags: [[String]] = []
    var lineLimit: Int? = nil
    @State private var selected: NostrContent.Attachment?
    private var attachments: [NostrContent.Attachment] { NostrContent.attachments(content, tags: tags) }
    private var text: AttributedString {
        var value = AttributedString(content)
        for match in NostrContent.links(content) + NostrContent.references(content) {
            if let range = Range(match.range, in: content),
               let start = AttributedString.Index(range.lowerBound, within: value),
               let end = AttributedString.Index(range.upperBound, within: value) {
                value[start..<end].link = match.url
            }
        }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).lineLimit(lineLimit).textSelection(.enabled)
            ForEach(attachments) { asset in
                switch asset.kind {
                case .image:
                    Button { selected = asset } label: {
                        AsyncImage(url: asset.url) { phase in
                            if let image = phase.image { image.resizable().scaledToFit() }
                            else { Label(phase.error == nil ? "Loading image…" : "Open image", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 120) }
                        }.frame(maxWidth: .infinity, maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("Open image").accessibilityIdentifier("pulse.media.image")
                case .video, .audio:
                    Button { selected = asset } label: {
                        HStack(spacing: 12) {
                            Image(systemName: asset.kind == .video ? "play.rectangle.fill" : "waveform.circle.fill").font(.largeTitle)
                            VStack(alignment: .leading) {
                                Text(asset.kind == .video ? "Play video" : "Play audio").font(.headline)
                                Text(asset.url.lastPathComponent).font(.caption).lineLimit(1)
                            }
                            Spacer()
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("pulse.media." + asset.kind.rawValue)
                case .link:
                    if asset.id == attachments.first(where: { $0.kind == .link })?.id {
                        NostrLinkPreview(url: asset.url)
                    } else { Link(asset.url.host ?? "Open link", destination: asset.url).font(.subheadline) }
                }
            }
        }
        .sheet(item: $selected) { asset in NostrMediaViewer(asset: asset) }
    }
}

private struct NostrMediaViewer: View {
    let asset: NostrContent.Attachment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            Group {
                if asset.kind == .image {
                    AsyncImage(url: asset.url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { ContentUnavailableView("Image unavailable", systemImage: "photo") }
                        else { ProgressView() }
                    }
                } else if let player { VideoPlayer(player: player) }
                else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(asset.kind == .image ? "Image" : asset.kind == .video ? "Video" : "Audio")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) { Link("Open original", destination: asset.url) }
                }
        }.onAppear { if asset.kind != .image { player = AVPlayer(url: asset.url) } }
            .onDisappear { player?.pause(); player = nil }
    }
}

private struct NostrLinkPreview: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?
    @State private var provider: LPMetadataProvider?
    @MainActor private static var cache: [URL: LPLinkMetadata] = [:]
    var body: some View {
        Link(destination: url) {
            if let metadata {
                LinkCard(metadata: metadata).frame(height: 150).allowsHitTesting(false)
            } else {
                Label(url.host ?? "Open link", systemImage: "link").font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }.accessibilityLabel("Open link: " + (metadata?.title ?? url.host ?? url.absoluteString))
            .task(id: url) {
                if let cached = Self.cache[url] { metadata = cached; return }
                let loader = LPMetadataProvider(); loader.timeout = 6; loader.shouldFetchSubresources = true
                provider = loader
                if let result = try? await loader.startFetchingMetadata(for: url), !Task.isCancelled {
                    if Self.cache.count >= 60 { Self.cache.removeAll() }
                    Self.cache[url] = result; metadata = result
                }
            }.onDisappear { provider?.cancel() }
    }
    private struct LinkCard: UIViewRepresentable {
        let metadata: LPLinkMetadata
        func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }
        func updateUIView(_ view: LPLinkView, context: Context) { view.metadata = metadata }
    }
}
