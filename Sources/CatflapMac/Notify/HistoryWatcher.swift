#if os(macOS)
import CatflapCore
import Darwin
import Foundation

/// Watches the agent's transfer history for what happens without the panel's help: something
/// arriving, and a send ending, whichever started it (the panel, the send-clipboard shortcut,
/// the Services menu or the command line). It reacts to writes to the database's journal, not
/// to a timer, so an idle agent does no work.
@MainActor
final class HistoryWatcher {
    enum Change: Sendable {
        case arrived(TransferRecord)
        case sent(TransferRecord)
        /// A send that ended as `failed` or `unconfirmed`; `reason` is the sentence the agent
        /// gave, when it still holds one.
        case notSent(TransferRecord, reason: String?)
    }

    private let runtime: AgentRuntime
    var onChange: ((Change) -> Void)?
    /// Called after every read, once its changes are reported.
    var onRead: (() -> Void)?
    private var directory: URL?
    private var directorySource: DispatchSourceFileSystemObject?
    private var journalSource: DispatchSourceFileSystemObject?
    private var known: [String: String] = [:]
    /// Each history row's status as last read, by `device/id`.
    var statuses: [String: String] { known }
    /// Reads begun so far, and for each send marked as started, the reads begun before it:
    /// those read the row as it was and must not overwrite the mark.
    private var generation = 0
    private var marked: [String: Int] = [:]
    private var seeded = false
    private var reading = false
    private var again = false
    private var pending: Task<Void, Never>?
    private var stopped = false

    init(runtime: AgentRuntime) { self.runtime = runtime }

    func start() async {
        let store = await runtime.store
        let directory = await store.paths.directory
        self.directory = directory
        directorySource = watch(directory.path, events: [.write, .link, .rename, .delete])
        watchJournal()
        await read()
    }

    func stop() {
        stopped = true
        pending?.cancel()
        directorySource?.cancel()
        journalSource?.cancel()
        directorySource = nil
        journalSource = nil
    }

    /// Reads now instead of waiting for the next write, for callers that just changed history.
    func refresh() { schedule() }

    /// A send just started (or started again, for Retry) under `key`: it counts as sending
    /// until a read begun after this shows how it is, and whatever it ends as is reported, even
    /// when that is what it was before.
    func markSending(_ key: String) {
        known[key] = "sending"
        marked[key] = generation
        schedule()
    }

    private func watchJournal() {
        guard journalSource == nil, let directory else { return }
        journalSource = watch(directory.appendingPathComponent("store.sqlite-wal").path, events: [.write, .extend, .delete, .rename])
    }

    private func watch(_ path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed(path: path) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func changed(path: String) {
        guard !stopped else { return }
        // The journal can be replaced (deleted and created again); watch the new one.
        if path.hasSuffix("-wal"), let source = journalSource, !source.data.intersection([.delete, .rename]).isEmpty {
            source.cancel()
            journalSource = nil
        }
        watchJournal()
        schedule()
    }

    private func schedule() {
        guard pending == nil, !stopped else { return }
        pending = Task { [weak self] in
            // Several writes make one transfer; read once they have settled.
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            await self.read()
        }
    }

    private func read() async {
        if reading { again = true; return }
        reading = true
        generation += 1
        let current = generation
        let store = await runtime.store
        let rows = (try? await TransferHistory(store: store).rows()) ?? []
        let transfers = await runtime.service(TransferService.self)
        var changes: [Change] = []
        for row in rows {
            let key = row.deviceID + "/" + row.id
            if let mark = marked[key] {
                // This read began before the send was marked: it holds the row as it was.
                if mark >= current { continue }
                marked[key] = nil
            }
            let before = known[key]
            known[key] = row.status
            guard seeded, before != row.status else { continue }
            if row.direction == "received", row.status == "ok" {
                changes.append(.arrived(row))
            } else if row.direction == "sent", row.status == "ok" {
                changes.append(.sent(row))
            } else if row.direction == "sent", row.canRetry {
                // The sentence a failed send ended with is held in memory, not stored.
                var reason: String?
                if let transfers, let current = try? await transfers.status(deviceID: row.deviceID, id: row.id) { reason = current.error }
                changes.append(.notSent(row, reason: reason))
            }
        }
        seeded = true
        reading = false
        if !stopped {
            for change in changes { onChange?(change) }
            onRead?()
        }
        if again {
            again = false
            await read()
        }
    }
}
#endif
