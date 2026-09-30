import Foundation

/// NIP-92 media hints supplement normal URLs; they never replace the URL.
enum NostrContent {
    enum Kind: String { case image, video, audio, link }
    struct Attachment: Identifiable, Equatable {
        let url: URL
        let kind: Kind
        var id: String { url.absoluteString }
    }
    static func webURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2048, let url = URL(string: raw), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func links(_ text: String) -> [(range: NSRange, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let raw = $0.url?.absoluteString, let url = webURL(raw) else { return nil }
            return ($0.range, url)
        }
    }
    static func references(_ text: String) -> [(range: NSRange, url: URL)] {
        guard let regex = try? NSRegularExpression(pattern: #"nostr:(?:npub|nprofile|note|nevent|naddr)1[023456789acdefghjklmnpqrstuvwxyz]+"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (match.range, URL(string: "https://njump.me/" + text[range].dropFirst(6))!)
        }
    }
    static func attachments(_ text: String, tags: [[String]] = []) -> [Attachment] {
        var hints: [String: String] = [:], tagged: [URL] = []
        for tag in tags where tag.first == "imeta" {
            guard let raw = tag.dropFirst().first(where: { $0.hasPrefix("url ") }).map({ String($0.dropFirst(4)) }),
                  let url = webURL(raw) else { continue }
            hints[url.absoluteString] = tag.dropFirst().first(where: { $0.hasPrefix("m ") }).map { String($0.dropFirst(2)).lowercased() }
            tagged.append(url)
        }
        var seen = Set<URL>()
        return Array((links(text).map(\.url) + tagged).filter { seen.insert($0).inserted }.prefix(8)).map { url in
            let mime = hints[url.absoluteString] ?? "", ext = url.pathExtension.lowercased()
            let kind: Kind
            if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif"].contains(ext) { kind = .image }
            else if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "m3u8"].contains(ext) { kind = .video }
            else if mime.hasPrefix("audio/") || ["mp3", "m4a", "aac", "wav", "ogg", "flac"].contains(ext) { kind = .audio }
            else { kind = .link }
            return .init(url: url, kind: kind)
        }
    }
}
