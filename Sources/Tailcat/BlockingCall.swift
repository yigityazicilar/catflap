import CTailcat
import Foundation
import Synchronization

// The machinery behind the five wrapper lifetime rules:
//
// 1. Each blocking C call runs on its own thread, which owns its buffers and token.
// 2. The Swift caller resumes only when the C call has returned, cancelled or not.
// 3. Cancelling a Swift task calls tc_token_cancel and then waits for that return.
// 4. A handle the C call returns after cancellation is closed by the wrapper.
// 5. Every wrapper object has an async close() that runs tc_close off the caller's thread.

/// The status, value and error text of one C call.
struct CReturn<Value: Sendable>: Sendable {
    var status: Int32
    var value: Value
    var message: String?
}

let statusOK = Int32(TC_OK)
let statusClosed = Int32(TC_CLOSED)
let statusEOF = Int32(TC_EOF)

/// Takes ownership of a string the C library allocated and frees it.
func takeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { tc_free(pointer) }
    return String(cString: pointer)
}

/// Every handle the wrapper holds and has not yet closed, with the handle that owns it.
///
/// Closing a client or server retires the connections and listeners it owns, so they leave
/// the ledger with it.
final class HandleLedger: Sendable {
    static let shared = HandleLedger()
    private let live = Mutex<[tc_handle: tc_handle]>([:])
    private static let noParent: tc_handle = 0

    func opened(_ handle: tc_handle, parent: tc_handle?) {
        live.withLock { $0[handle] = parent ?? Self.noParent }
    }

    func retired(_ handle: tc_handle) {
        live.withLock { table in
            var pending = [handle]
            while let next = pending.popLast() {
                table[next] = nil
                pending += table.filter { $0.value == next }.map(\.key)
            }
        }
    }

    func children(of handle: tc_handle) -> [tc_handle] {
        live.withLock { table in table.filter { $0.value == handle }.map(\.key) }
    }

    func isLive(_ handle: tc_handle) -> Bool {
        live.withLock { $0[handle] != nil }
    }
}

/// What one blocking call did, reported to test hooks on the call's own thread.
struct CallReport: Sendable {
    var operation: String
    /// The handle the call operated on.
    var resource: tc_handle
    var token: tc_handle
    var status: Int32
    /// The handle the call returned, or 0.
    var produced: tc_handle
}

/// Test seams. Production code never sets them.
struct TestHooks: Sendable {
    /// Runs on the call thread just before the C function is entered.
    var beforeCCall: (@Sendable (CallReport) -> Void)?
    /// Runs on the call thread after the C function returned, before the wrapper looks at
    /// cancellation and before the Swift caller is resumed.
    var afterCReturn: (@Sendable (CallReport) -> Void)?

    static let current = Mutex<TestHooks>(TestHooks())
}

/// Closes a handle synchronously on the current thread and removes it from the ledger.
func closeHandleNow(_ handle: tc_handle) {
    var error: UnsafeMutablePointer<CChar>?
    _ = tc_close(handle, &error)
    _ = takeCString(error)
    // The handle is retired even when tc_close reports an error.
    HandleLedger.shared.retired(handle)
}

/// Closes a client or server so that its peers see their connections end.
///
/// tailcat's TCP stack runs in this process, and tc_close on a client or server tears it down
/// at once, which can drop the FIN of each open connection before it is sent. Upstream's
/// remedy: close the connections, wait for the stack with tc_drain under a short deadline,
/// then close the peer. The deadline bounds the wait when a peer never answers.
func closePeerNow(_ handle: tc_handle) {
    let children = HandleLedger.shared.children(of: handle)
    if !children.isEmpty {
        for child in children { closeHandleNow(child) }
        var token: tc_handle = 0
        var error: UnsafeMutablePointer<CChar>?
        if tc_token_new(1_000_000_000, &token, &error) == statusOK {
            _ = takeCString(error)
            _ = tc_drain(handle, token, &error)
            _ = takeCString(error)
            _ = tc_close(token, &error)
        }
        _ = takeCString(error)
    }
    closeHandleNow(handle)
}

/// Runs a close on a thread of its own and waits for it.
func closeHandleOffThread(_ handle: tc_handle, peer: Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let thread = Thread {
            if peer { closePeerNow(handle) } else { closeHandleNow(handle) }
            continuation.resume()
        }
        thread.start()
    }
}

/// Shared state between a call's thread and the cancellation handler of its Swift task.
private final class CallState: Sendable {
    let token: tc_handle
    private struct Flags { var cancelled = false; var returned = false }
    private let flags = Mutex(Flags())

    init(token: tc_handle) { self.token = token }

    /// From the cancellation handler: signal the token while the C call may still be inside.
    func cancel() {
        flags.withLock { flags in
            flags.cancelled = true
            if !flags.returned {
                var error: UnsafeMutablePointer<CChar>?
                _ = tc_token_cancel(token, &error)
                _ = takeCString(error)
            }
        }
    }

    /// From the call thread once the C call has returned. True when the Swift task was
    /// cancelled before that.
    func finish() -> Bool {
        flags.withLock { flags in
            flags.returned = true
            return flags.cancelled
        }
    }
}

enum BlockingCall {
    static func makeToken(timeout: Duration?, operation: String) throws -> tc_handle {
        var nanoseconds: Int64 = -1
        if let timeout {
            let (seconds, attoseconds) = timeout.components
            let total = seconds.multipliedReportingOverflow(by: 1_000_000_000)
            nanoseconds = total.overflow ? Int64.max : max(0, total.partialValue &+ attoseconds / 1_000_000_000)
        }
        var token: tc_handle = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = tc_token_new(nanoseconds, &token, &error)
        let message = takeCString(error)
        guard status == statusOK else {
            throw TailcatError(status: status, operation: operation, message: message)
        }
        HandleLedger.shared.opened(token, parent: nil)
        return token
    }

    /// Runs `body` on a new thread with a fresh token and suspends until it has returned.
    ///
    /// - Parameters:
    ///   - resource: the handle the call works on, reported to test hooks.
    ///   - produces: for calls that return a handle, how to read it from the value and which
    ///     handle owns it. A handle that arrives after the Swift task was cancelled is closed
    ///     here, and the caller gets `TailcatError.Code.cancelled`.
    static func run<Value: Sendable>(
        _ operation: String,
        resource: tc_handle,
        timeout: Duration?,
        produces: (handle: @Sendable (Value) -> tc_handle, owner: tc_handle)? = nil,
        _ body: @escaping @Sendable (tc_token) -> CReturn<Value>
    ) async throws -> CReturn<Value> {
        if Task.isCancelled { throw TailcatError(.cancelled, operation) }
        let token = try makeToken(timeout: timeout, operation: operation)
        let state = CallState(token: token)
        let (result, abandoned) = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(CReturn<Value>, Bool), Never>) in
                let thread = Thread {
                    let hooks = TestHooks.current.withLock { $0 }
                    var report = CallReport(operation: operation, resource: resource, token: token, status: 0, produced: 0)
                    hooks.beforeCCall?(report)
                    let result = body(token)
                    let produced = produces.map { $0.handle(result.value) } ?? 0
                    if produced != 0, let owner = produces?.owner {
                        HandleLedger.shared.opened(produced, parent: owner)
                    }
                    report.status = result.status
                    report.produced = produced
                    hooks.afterCReturn?(report)
                    let abandoned = state.finish()
                    // The token and the buffers in `body` lived until the C call returned.
                    closeHandleNow(token)
                    if abandoned && produced != 0 {
                        closeHandleNow(produced)
                    }
                    continuation.resume(returning: (result, abandoned))
                }
                thread.start()
            }
        } onCancel: {
            state.cancel()
        }
        if abandoned { throw TailcatError(.cancelled, operation) }
        return result
    }
}

/// One C handle owned by a wrapper object. It is closed once, by `close()` or, if the owner
/// forgot, when the last reference goes away.
final class OwnedHandle: Sendable {
    let handle: tc_handle
    /// True for clients and servers, which own connections.
    let isPeer: Bool
    private let closing = Mutex<Task<Void, Never>?>(nil)

    init(_ handle: tc_handle, parent: tc_handle?, isPeer: Bool = false) {
        self.handle = handle
        self.isPeer = isPeer
        HandleLedger.shared.opened(handle, parent: parent)
    }

    /// Closes the handle off the caller's thread. Concurrent and repeated calls all wait for
    /// the one tc_close.
    func close() async {
        let handle = self.handle
        let peer = isPeer
        let task = closing.withLock { current in
            if let current { return current }
            let started = Task { await closeHandleOffThread(handle, peer: peer) }
            current = started
            return started
        }
        await task.value
    }

    deinit {
        let neverClosed = closing.withLock { $0 == nil }
        if neverClosed {
            // tc_close can block until active calls end; never do that inside deinit.
            let handle = self.handle
            Thread { closeHandleNow(handle) }.start()
        }
    }
}
