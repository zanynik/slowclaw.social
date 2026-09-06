import Foundation

/// A real serial queue: unlike a reentrant actor awaiting detached work,
/// only one synchronous native call can execute at a time. Status, loading,
/// unloading and generation all use this same off-main executor.
final class OnDeviceAIExecutor: @unchecked Sendable {
    static let shared = OnDeviceAIExecutor()
    private let queue = DispatchQueue(label: "com.slowclaw.inference", qos: .utility)

    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
