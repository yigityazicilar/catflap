import Foundation
import Synchronization

/// One CPU job and one replaceable pending job. Replaced callers settle as superseded;
/// neither the store actor nor Swift's cooperative executor runs the detector.
public final class ClipboardFilterWorker: Sendable {
    private struct Job: Sendable {
        let text: String
        let reply: CheckedContinuation<Bool?, Never>
    }
    private struct State {
        var active = false
        var pending: Job?
        var observers: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "catflap.clipboard-filter", qos: .utility)
    private let filter: @Sendable (String) -> Bool
    public init(filter: @escaping @Sendable (String) -> Bool = { SecretFilter.rejects($0) }) { self.filter = filter }
    public func rejects(_ text: String) async -> Bool? {
        await withCheckedContinuation { reply in
            let job = Job(text: text, reply: reply)
            let start = state.withLock { state in
                if state.active {

                    state.pending?.reply.resume(returning: nil)
                    state.pending = job
                    let observers = state.observers; state.observers = []
                    for observer in observers { observer.resume() }
                    return false
                }
                state.active = true
                return true
            }
            if start { run(job) }
        }
    }
    /// An ordering seam: observes submission, not elapsed time.
    func waitForPending() async {
        await withCheckedContinuation { reply in
            state.withLock { state in
                if state.pending != nil { reply.resume() } else { state.observers.append(reply) }
            }
        }
    }
    private func run(_ job: Job) {
        queue.async { [self] in
            let rejected = filter(job.text)
            job.reply.resume(returning: rejected)
            let next = state.withLock { state -> Job? in
                let next = state.pending; state.pending = nil
                if next == nil { state.active = false }
                return next
            }
            if let next { run(next) }
        }
    }
}
