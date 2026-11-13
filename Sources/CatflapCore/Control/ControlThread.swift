import Foundation
import Synchronization

/// Blocking local I/O must not occupy Swift's cooperative executor threads.
enum ControlThread {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try body() })
            }
        }
    }
    static func wait<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Mutex<Result<T, Error>?>(nil)
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let value = Result { try body() }
            result.withLock { $0 = value }
            ready.signal()
        }
        ready.wait()
        return try result.withLock { try $0!.get() }
    }
}
