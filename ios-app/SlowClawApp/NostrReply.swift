import Foundation

enum NostrReply {
    static func envelope(root: PublishedEvent, parent: PublishedEvent) throws -> (kind: Int, tags: [[String]]) {
        guard NostrEventVerifier.verify(root), NostrEventVerifier.verify(parent),
              root.id == parent.id || NostrConversationRules.belongs(parent, to: root) else {
            throw PublishingError.message("The original conversation could not be verified.")
        }
        if root.kind == 1, parent.kind == 1 {
            // Preserve the original thread root when replying to a note
            // that is itself a reply, rather than silently starting a fork.
            let rootTag = root.tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" }
                ?? ["e", root.id, "", "root", root.pubkey]
            var tags = [rootTag]
            if parent.id != rootTag[1] { tags.append(["e", parent.id, "", "reply", parent.pubkey]) }
            let people = Set([root.pubkey, parent.pubkey] + parent.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] })
            tags += people.sorted().filter { NostrEventVerifier.bytes($0, count: 32) != nil }.prefix(30).map { ["p", $0] }
            return (1, tags)
        }
        guard root.kind == 30023, parent.id == root.id || parent.kind == 1111 else {
            throw PublishingError.message("This conversation type is not supported yet.")
        }
        var tags = [["K", "30023"], ["P", root.pubkey], ["k", String(parent.kind)], ["p", parent.pubkey], ["e", parent.id, "", parent.pubkey]]
        if let address = root.address {
            tags.append(["A", address])
            if parent.id == root.id { tags.append(["a", address]) }
        } else { tags.append(["E", root.id, "", root.pubkey]) }
        return (1111, tags)
    }
}
