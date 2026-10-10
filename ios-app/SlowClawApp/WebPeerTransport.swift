import Foundation
import WebRTC

/// Only encrypted SDP goes to the Worker. All companion operations use the data
/// channel. No audio/video tracks or background audio entitlement are created.
@MainActor
final class WebPeerTransport: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private static let factory: RTCPeerConnectionFactory = { RTCInitializeSSL(); return RTCPeerConnectionFactory() }()
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var pairing: WebSessionProtocol.Pairing?
    private var sent = 0, received = 0, frameSequence = 0, frameBytes = 0
    private var fragments: [String] = []
    private var sending: [Int: Task<Void, Never>] = [:]
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private let http = URLSession(configuration: .ephemeral)
    private var generation = UUID()
    var online: Bool { channel?.readyState == .open }
    private func problem(_ text: String = "Phone connection ended. Browser drafts are kept; disconnect and scan a fresh code.") -> Error { PublishingError.message(text) }
    func connect(_ pairing: WebSessionProtocol.Pairing) async throws {
        close(); self.pairing = pairing
        guard let signaling = pairing.signaling else { throw problem("This is not a peer pairing code.") }
        func signal(_ action: String, method: String = "GET", body: Data? = nil) async throws -> Data {
            var request = URLRequest(url: URL(string: signaling + "/v1/rooms/" + pairing.id + "/" + action)!)
            request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer " + pairing.pair, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            let (data, response) = try await http.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 120_000 else { throw problem("Pairing code expired. Show a fresh code in the browser.") }
            return data
        }
        struct Ice: Decodable { let urls: [String]; let username: String?; let credential: String? }
        struct Offer: Decodable { let sealed: String?; let iceServers: [Ice] }
        let offer = try JSONDecoder().decode(Offer.self, from: await signal("offer"))
        guard let raw = offer.sealed, let encrypted = Data(base64Encoded: raw), offer.iceServers.count <= 5 else { throw problem("Browser offer is not ready. Scan again.") }
        struct Description: Codable { let type: String; let sdp: String }
        let remote = try JSONDecoder().decode(Description.self, from: WebSessionProtocol.open(encrypted, key: pairing.key, context: pairing.id + "/signal/offer"))
        guard remote.type == "offer", remote.sdp.utf8.count < 60_000 else { throw problem("Invalid browser offer.") }
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = try offer.iceServers.map { ice in
            guard !ice.urls.isEmpty, ice.urls.count <= 3, ice.urls.allSatisfy({ $0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }) else { throw problem("Invalid network configuration.") }
            return RTCIceServer(urlStrings: ice.urls, username: ice.username, credential: ice.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else { throw problem("Peer networking is unavailable.") }
        connection = pc
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: remote.sdp)) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.answer(for: constraints) { answer, error in if let answer { c.resume(returning: answer) } else { c.resume(throwing: error ?? PublishingError.message("Peer answer failed.")) } }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        let deadline = Date().addingTimeInterval(20)
        while pc.iceGatheringState != .complete {
            guard Date() < deadline, connection === pc else { throw problem("Network setup timed out. Try again.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let local = pc.localDescription else { throw problem() }
        let encoded = try JSONEncoder().encode(Description(type: "answer", sdp: local.sdp))
        let sealed = try WebSessionProtocol.seal(encoded, key: pairing.key, context: pairing.id + "/signal/answer")
        _ = try await signal("answer", method: "PUT", body: JSONSerialization.data(withJSONObject: ["sealed": sealed.base64EncodedString()]))
        let connectedBy = Date().addingTimeInterval(30)
        while !online { guard Date() < connectedBy, connection === pc else { throw problem("Could not reach the browser. Try the same Wi-Fi or configure a TURN relay.") }; try await Task.sleep(nanoseconds: 50_000_000) }
    }
    func request(path: String, method: String, body: Data, authorization: String) async throws -> Data {
        guard let pairing, let channel, online, pending.isEmpty else { throw problem() }
        sent += 1; let id = sent, generation = self.generation
        let request = try JSONSerialization.data(withJSONObject: ["id": id, "path": path, "method": method, "body": body.base64EncodedString(), "authorization": authorization])
        let sealed = try WebSessionProtocol.seal(request, key: pairing.key, context: pairing.id + "/rpc/phone/" + String(id)).base64EncodedString()
        // Responses can only arrive after the final frame, so register before send.
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            sending[id] = Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                do {
                    let deadline = Date().addingTimeInterval(45)
                    let characters = Array(sealed.utf8); var offset = 0, part = 0
                    while offset < characters.count {
                        while channel.bufferedAmount > 512_000 { guard Date() < deadline, self.online else { throw self.problem() }; try await Task.sleep(nanoseconds: 20_000_000) }
                        let end = min(offset + 14_000, characters.count)
                        let frame = try JSONSerialization.data(withJSONObject: ["seq": id, "part": part, "last": end == characters.count, "data": String(decoding: characters[offset..<end], as: UTF8.self)])
                        guard self.generation == generation, self.online, channel.sendData(RTCDataBuffer(data: frame, isBinary: false)) else { throw self.problem() }
                        offset = end; part += 1
                    }
                    try await Task.sleep(nanoseconds: 45_000_000_000)
                    if self.generation == generation, self.pending[id] != nil { self.close() }
                } catch { if !Task.isCancelled, self.generation == generation { self.close() } }
            }
        }
    }
    private func receive(_ data: Data) {
        do {
            guard data.count <= 18_000, let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let seq = frame["seq"] as? Int, seq == received + 1,
                  let part = frame["part"] as? Int, part == fragments.count,
                  let text = frame["data"] as? String, text.utf8.count <= 14_000,
                  let last = frame["last"] as? Bool, frameSequence == 0 || frameSequence == seq else { throw problem() }
            frameSequence = seq; frameBytes += text.utf8.count
            guard frameBytes <= 5_000_000 else { throw problem() }
            fragments.append(text); if !last { return }
            guard let pairing, let encrypted = Data(base64Encoded: fragments.joined()) else { throw problem() }
            let plaintext = try WebSessionProtocol.open(encrypted, key: pairing.key, context: pairing.id + "/rpc/browser/" + String(seq))
            fragments = []; frameSequence = 0; frameBytes = 0; received = seq
            guard let response = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any], let id = response["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { throw problem() }
            sending.removeValue(forKey: id)?.cancel()
            if let error = response["error"] as? String { continuation.resume(throwing: problem(error)) }
            else if let value = response["body"] as? String, let decoded = Data(base64Encoded: value) { continuation.resume(returning: decoded) }
            else { continuation.resume(throwing: problem()) }
        } catch { close() }
    }
    func close() {
        generation = UUID()
        let tasks = Array(sending.values); sending.removeAll(); tasks.forEach { $0.cancel() }
        channel?.close(); connection?.close(); channel = nil; connection = nil
        let continuations = Array(pending.values); pending.removeAll(); for c in continuations { c.resume(throwing: problem()) }
        sent = 0; received = 0; fragments = []; frameSequence = 0; frameBytes = 0
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in guard self.connection === peerConnection, dataChannel.label == "slowclaw-v1", self.channel == nil else { dataChannel.close(); return }; self.channel = dataChannel; dataChannel.delegate = self }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        DispatchQueue.main.async { guard self.channel === dataChannel else { return }; self.receive(data) }
    }
}
