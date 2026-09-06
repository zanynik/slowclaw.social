import Foundation

/// SpeechAnalyzer sessions share system resources. A live session keeps its
/// lease through finalization; imported files wait instead of starting over it.
actor SpeechSessionGate {
    static let shared = SpeechSessionGate()
    private var occupied = false
    func tryAcquire() -> Bool {
        guard !occupied else { return false }
        occupied = true
        return true
    }
    func acquire() async -> Bool {
        while occupied {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return false }
        }
        guard !Task.isCancelled else { return false }
        occupied = true
        return true
    }
    func release() { occupied = false }
}

@MainActor enum CaptureActivity {
    static var isCapturing = false
}
