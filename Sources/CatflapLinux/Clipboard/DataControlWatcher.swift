import CatflapCore
import CDataControl
import Foundation

/// The worker serializes Wayland operations. Only its wake pipe is touched during stop.
final class DataControlWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: OpaquePointer?
    private let ended = DispatchGroup()
    private let history: ClipboardHistory
    private let runtime: AgentRuntime

    init(history: ClipboardHistory, runtime: AgentRuntime) {
        self.history = history
        self.runtime = runtime
        connection = cf_dc_create()
    }

    func start() async {
        ended.enter()
        await withCheckedContinuation { ready in
            Thread.detachNewThread { [self] in
                run(ready: ready)
                ended.leave()
            }
        }
    }

    private func run(ready: CheckedContinuation<Void, Never>) {
        guard let connection else {
            Task {
                await runtime.updatePlatformStatus { $0.clipboardCapture = "failed" }
                ready.resume()
            }
            return
        }
        let result = cf_dc_open(connection)
        let state = result == 1 ? "active" : result == 0 ? "unsupported" : "failed"
        let published = DispatchSemaphore(value: 0)
        Task {
            await runtime.updatePlatformStatus { $0.clipboardCapture = state }
            ready.resume()
            published.signal()
        }
        published.wait()
        if result == 1 {
            while true {
                let next = cf_dc_next(connection)
                if next != 1 {
                    if next < 0 {
                        let updated = DispatchSemaphore(value: 0)
                        Task {
                            await runtime.updatePlatformStatus { $0.clipboardCapture = "failed" }
                            updated.signal()
                        }
                        updated.wait()
                    }
                    break
                }
                let types = (0..<cf_dc_type_count(connection)).compactMap { index in
                    cf_dc_type(connection, index).map { String(cString: $0) }
                }
                let representation = Self.representation(types)
                let complete = DispatchSemaphore(value: 0)
                Task {
                    do {
                        // Even an unsupported/empty offer reaches the gate: it invalidates a
                        // previous pending Keep, and a marker is checked before the reader.
                        _ = try await history.ingest(offeredTypes: types, kind: representation?.kind ?? .text) { [self] in
                            guard let representation else { throw ClipboardFailure.invalid }
                            return try await read(representation)
                        }
                    } catch {
                        // An expired offer, invalid body or stalled source records nothing.
                        // Neither content nor raw types belong in an error log.
                    }
                    complete.signal()
                }
                complete.wait()
            }
        }
        lock.lock()
        self.connection = nil
        cf_dc_destroy(connection)
        lock.unlock()
    }

    private struct Representation: Sendable {
        let mime: String
        let kind: ClipboardKind
        var limit: Int { kind == .image ? ClipboardHistory.imageLimit : ClipboardHistory.textLimit }
    }

    private static func representation(_ types: [String]) -> Representation? {
        // File references must remain references, not a read of their target files.
        for mime in ["text/uri-list", "image/png", "image/jpeg", "text/plain;charset=utf-8", "text/plain;charset=UTF-8", "text/plain", "UTF8_STRING"] {
            if types.contains(mime) {
                return Representation(mime: mime, kind: mime.hasPrefix("image/") ? .image : .text)
            }
        }
        return nil
    }

    private func read(_ representation: Representation) async throws -> ClipboardContent {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                // There is no simultaneous dispatch while ingest's reader is active. Stop
                // only signals the wake pipe; the worker destroys the connection afterwards.
                guard let connection else {
                    continuation.resume(throwing: ClipboardFailure.invalid)
                    return
                }
                var bytes = Data(count: representation.limit + 1)
                var count = 0
                let result = bytes.withUnsafeMutableBytes { buffer in
                    cf_dc_receive(connection, representation.mime,
                                  buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &count)
                }
                guard result == 1 else {
                    continuation.resume(throwing: ClipboardFailure.invalid)
                    return
                }
                bytes.count = count
                var kind = representation.kind
                if representation.mime == "text/uri-list", count <= representation.limit {
                    guard let text = String(data: bytes, encoding: .utf8) else {
                        continuation.resume(throwing: ClipboardFailure.invalid)
                        return
                    }
                    let entries = text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    if !entries.isEmpty && entries.allSatisfy({ URL(string: $0)?.isFileURL == true }) {
                        kind = .files
                    } else if entries.count == 1, let url = URL(string: entries[0]), ["http", "https"].contains(url.scheme) {
                        kind = .url
                    } else {
                        continuation.resume(throwing: ClipboardFailure.invalid)
                        return
                    }
                    bytes = Data(entries.joined(separator: "\n").utf8)
                }
                continuation.resume(returning: ClipboardContent(kind: kind, data: bytes, mime: representation.mime))
            }
        }
    }

    func stop() async {
        cancel()
        await withCheckedContinuation { continuation in
            ended.notify(queue: .global()) { continuation.resume() }
        }
    }

    private func cancel() {
        lock.lock()
        if let connection { cf_dc_cancel(connection) }
        lock.unlock()
    }
}
