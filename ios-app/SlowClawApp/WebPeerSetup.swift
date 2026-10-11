import Foundation

/// Complete ICE discovery is preferable, but a stalled STUN server must not
/// discard usable local candidates. No candidates means no usable route.
enum WebPeerSetup {
    static func ready(sdp: String, complete: Bool, elapsed: TimeInterval) throws -> Bool {
        guard complete || elapsed >= 12 else { return false }
        guard sdp.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("a=candidate:") }) else {
            throw PublishingError.message("No network route was found. Try the same Wi-Fi, allow Local Network access, and check whether a VPN blocks WebRTC.")
        }
        return true
    }
}
