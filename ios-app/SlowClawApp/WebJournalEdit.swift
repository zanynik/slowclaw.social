import Foundation

/// Encrypted browser operations. The phone remains the canonical journal store.
struct WebJournalEdit: Decodable {
    let kind: String
    let key: String
    let base: String?
    let title: String?
    let text: String?

    var content: String { (title ?? "Journal") + "\n\n" + (text ?? "") }
    func validate() throws {
        guard key.utf8.count <= 240, !key.isEmpty, ["read", "write"].contains(kind) else {
            throw PublishingError.message("Invalid journal operation.")
        }
        if kind == "write" {
            guard let title, let text, !title.contains("\n"), !title.contains("\r"),
                  title.utf8.count <= 960, content.utf8.count <= 1_000_000,
                  base == nil || WebSessionProtocol.validID(base!) else {
                throw PublishingError.message("Journal text is too large or invalid.")
            }
        }
    }
    /// A null base creates only browser-owned keys, never resurrects an old note.
    func decision(current: String?, revision: String?, available: Bool) -> String {
        if kind == "read" { return available ? "loaded" : "rejected" }
        if let current, available {
            if current == content { return "saved" } // Lost receipt / retry.
            return base == revision ? "saved" : "conflict"
        }
        return current == nil && base == nil && key.hasPrefix("journal_web_") &&
            WebSessionProtocol.validID(String(key.dropFirst("journal_web_".count))) ? "saved" : "rejected"
    }
}
