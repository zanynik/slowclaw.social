import XCTest
import Foundation
import WebRTC
@testable import StudioSmokeHost

// Real simulator data channels, with synthetic local signaling only. This
// exercises the production phone transport, including its encrypted framing.
@MainActor
final class WebPeerTransportTests: XCTestCase {
    func testApprovalStatusAndLargeSnapshotOverActualDataChannel() async throws {
        let browser = PeerBrowserFixture()
        let offer = try await browser.offer()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PeerSignalFixture.self]
        PeerSignalFixture.reply = { request in
            if request.url!.path.hasSuffix("/offer") {
                let sealed = try WebSessionProtocol.seal(offer, key: browser.key, context: browser.id + "/signal/offer")
                return try JSONSerialization.data(withJSONObject: ["sealed": sealed.base64EncodedString(), "iceServers": []])
            }
            let body: Data
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(contentsOf: buffer.prefix(n)) }
                body = result
            } else { throw PublishingError.message("Missing synthetic answer") }
            let value = try JSONSerialization.jsonObject(with: body) as! [String: String]
            let plain = try WebSessionProtocol.open(Data(base64Encoded: value["sealed"]!)!, key: browser.key, context: browser.id + "/signal/answer")
            let answer = try JSONSerialization.jsonObject(with: plain) as! [String: String]
            try await browser.answer(answer["sdp"]!)
            return Data("{}".utf8)
        }
        let transport = WebPeerTransport(http: URLSession(configuration: config))
        defer { transport.close(); browser.close(); PeerSignalFixture.reply = nil }
        let pairing = WebSessionProtocol.Pairing(id: browser.id, pair: String(repeating: "2", count: 64), key: browser.key, origin: "https://slowclaw.social", signaling: "https://slowclaw-fixture.workers.dev")
        try await transport.connect(pairing)
        XCTAssertTrue(transport.online)
        for (path, body) in [("/pair", Data("{}".utf8)), ("", Data()), ("/snapshot", Data(repeating: 65, count: 650_000))] {
            let response = try await transport.request(path: path, method: path.isEmpty ? "GET" : "POST", body: body, authorization: "synthetic-test-only")
            XCTAssertEqual(String(decoding: response, as: UTF8.self), "received")
        }
        XCTAssertEqual(browser.paths, ["/pair", "", "/snapshot"])
        XCTAssertEqual(browser.lengths, [2, 0, 650_000])
        XCTAssertTrue(transport.online)
    }
}

private final class PeerSignalFixture: URLProtocol {
    @MainActor static var reply: ((URLRequest) async throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "slowclaw-fixture.workers.dev" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            do {
                let data = try await Self.reply!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class PeerBrowserFixture: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let id = String(repeating: "1", count: 64), key = Data(repeating: 3, count: 32)
    private let factory: RTCPeerConnectionFactory
    private var pc: RTCPeerConnection!
    private var channel: RTCDataChannel!
    private var parts: [String] = [], received = 0
    var paths: [String] = [], lengths: [Int] = []
    override init() {
        RTCInitializeSSL(); factory = RTCPeerConnectionFactory(); super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan; config.iceServers = []
        pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let data = RTCDataChannelConfiguration(); data.isOrdered = true
        channel = pc.dataChannel(forLabel: "slowclaw-v1", configuration: data); channel.delegate = self
    }
    func offer() async throws -> Data {
        let desc: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let value { c.resume(returning: value) } else { c.resume(throwing: error!) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in pc.setLocalDescription(desc) { error in if let error { c.resume(throwing: error) } else { c.resume() } } }
        let deadline = Date().addingTimeInterval(10)
        while pc.iceGatheringState != .complete { guard Date() < deadline else { throw PublishingError.message("Synthetic ICE timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
        return try JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": pc.localDescription!.sdp])
    }
    func answer(_ sdp: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in if let error { c.resume(throwing: error) } else { c.resume() } } }
    }
    func close() { channel.close(); pc.close() }
    private func receive(_ data: Data) {
        do {
            let frame = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(frame["seq"] as? Int, received + 1); XCTAssertEqual(frame["part"] as? Int, parts.count)
            parts.append(frame["data"] as! String); guard frame["last"] as! Bool else { return }
            received += 1
            let plain = try WebSessionProtocol.open(Data(base64Encoded: parts.joined())!, key: key, context: id + "/rpc/phone/" + String(received))
            parts = []
            let request = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            paths.append(request["path"] as! String); lengths.append(Data(base64Encoded: request["body"] as! String)!.count)
            let response = try JSONSerialization.data(withJSONObject: ["id": request["id"]!, "body": Data("received".utf8).base64EncodedString()])
            let sealed = try WebSessionProtocol.seal(response, key: key, context: id + "/rpc/browser/" + String(received)).base64EncodedString()
            let reply = try JSONSerialization.data(withJSONObject: ["seq": received, "part": 0, "last": true, "data": sealed])
            XCTAssertTrue(channel.sendData(RTCDataBuffer(data: reply, isBinary: false)))
        } catch { XCTFail("Synthetic peer framing failed: \(error.localizedDescription)") }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) { let data = buffer.data; Task { @MainActor in self.receive(data) } }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
