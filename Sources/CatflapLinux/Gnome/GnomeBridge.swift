import CatflapCore
import Foundation
import Synchronization

struct GnomeRequest: Decodable {
    let id: String
    let command: String
    var arguments: [String: String] = [:]
}

/// Owns the extension session, not GTK. Only the small event callbacks run on the GTK thread.
final class GnomeBridge: @unchecked Sendable {
    private static let installed = Mutex<GnomeBridge?>(nil)
    static var current: GnomeBridge? { installed.withLock { $0 } }
    private let lock = NSLock()
    private var ready = false
    private var bindings: [String: Int] = [:]
    var connected: Bool { lock.withLock { ready } }
    func isBound(_ action: String) -> Bool { lock.withLock { ready && (bindings[action] ?? 0) > 0 } }
    private let runtime: AgentRuntime
    let session: DesktopSession
    let directory: URL
    private let files = GnomeFiles()
    private let capture: GnomeCapture
    // GTK-thread-only listeners, installed by the desktop backends.
    var listeners: [UUID: (String, [String: String]) -> Void] = [:]
    private let onReady: @Sendable () async -> Void

    init(runtime: AgentRuntime, directory: URL, history: ClipboardHistory, onReady: @escaping @Sendable () async -> Void) throws {
        self.runtime = runtime; self.onReady = onReady; self.directory = directory
        session = try DesktopSession(path: directory.appendingPathComponent("session.sock"))
        capture = GnomeCapture(history: history)
    }
    func start() async {
        Self.installed.withLock { $0 = self }
        await runtime.updatePlatformStatus { $0.extensionState = "missing" }
        session.start(changed: { [weak self] connected in
            guard let self, !connected, !session.connected else { return }
            lock.withLock { ready = false; bindings = [:] }
            await capture.disconnected()
            await runtime.updatePlatformStatus { $0.extensionState = "missing"; $0.clipboardCapture = "unsupported" }
            notify("missing", [:])
        }, handler: { [weak self] bytes in
            guard let self else { return Data("{}".utf8) }
            return await receive(bytes)
        })
    }
    func updateFiles() async {
        let response = await runtime.handle(ControlRequest("devices"))
        if response.ok, let devices = try? response.decode([DeviceSummary].self) { try? await files.update(devices) }
    }
    func stop() async {
        Self.installed.withLock { $0 = nil }
        await capture.disconnected()
        await session.stop()
    }
    @discardableResult
    func push(_ event: String, _ arguments: [String: String] = [:]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["event": event, "arguments": arguments]) else { return false }
        return session.send(data)
    }
    private func notify(_ event: String, _ arguments: [String: String]) {
        GLib.idle { [weak self] in
            guard let self else { return }
            for callback in Array(listeners.values) { callback(event, arguments) }
        }
    }
    private func receive(_ data: Data) async -> Data {
        guard let request = try? ControlJSON.decoder.decode(GnomeRequest.self, from: data) else {
            return Data("{\"id\":\"invalid\",\"ok\":false}".utf8)
        }
        let response: ControlResponse
        do {
            switch request.command {
            case "hello":
                await capture.disconnected()
                let reported = request.arguments["bindings"]?.data(using: .utf8)
                    .flatMap { try? ControlJSON.decoder.decode([String: Int].self, from: $0) } ?? [:]
                lock.withLock { bindings = reported; ready = true }
                await runtime.updatePlatformStatus { $0.extensionState = "connected"; $0.clipboardCapture = "active" }
                await onReady()
                notify("connected", [:])
                response = try ControlResponse(value: ["version": "1"])
            case "clipboard.offer":
                response = try await capture.offer(request.arguments, bridge: self)
            case "clipboard.data":
                await capture.data(request.arguments)
                response = try ControlResponse(value: ["accepted": true])
            case "trigger":
                let action = request.arguments["action"] ?? ""
                let names = ["toggle", "send-latest", "band-enter", "band-leave", "drag-enter", "drag-leave"]
                let name = names.contains(action) ? action : "unknown"
                FileHandle.standardError.write(Data("catflap trigger \(name)\n".utf8))
                notify(request.arguments["action"] ?? "", request.arguments)
                response = try ControlResponse(value: ["accepted": true])
            case "control":
                guard let command = request.arguments["command"], ["toggle", "ui.invoke", "clip.send"].contains(command) else {
                    throw AgentError.invalidRequest
                }
                var arguments = request.arguments; arguments.removeValue(forKey: "command")
                response = await runtime.handle(ControlRequest(command, arguments: arguments))
            default: throw AgentError.invalidRequest
            }
        } catch { response = ControlResponse(failure: "The desktop request could not be completed.") }
        var object: [String: Any] = ["id": request.id, "ok": response.ok, "exit_code": response.exitCode]
        object["payload"] = (try? JSONSerialization.jsonObject(with: response.payload, options: .fragmentsAllowed)) ?? NSNull()
        if let error = response.error { object["error"] = error }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// The core gate authorizes every read. Marker, pause and size checks run before a read push.
private actor GnomeCapture {
    let history: ClipboardHistory
    private var pending: (token: String, continuation: CheckedContinuation<Data, any Error>)?
    private var sequence = 0
    init(history: ClipboardHistory) { self.history = history }
    func disconnected() { sequence = 0; cancelRead() }
    private func cancelRead() {
        if let pending { self.pending = nil; pending.continuation.resume(throwing: ClipboardFailure.invalid) }
    }
    func offer(_ arguments: [String: String], bridge: GnomeBridge) async throws -> ControlResponse {
        guard !Task.isCancelled, let token = arguments["token"], let serial = Int(token), serial > sequence,
              let raw = arguments["types"]?.data(using: .utf8),
              let types = try? ControlJSON.decoder.decode([String].self, from: raw), types.count <= 256 else { throw ClipboardFailure.invalid }
        sequence = serial
        cancelRead()
        let mime = ["text/uri-list", "image/png", "image/jpeg", "text/plain;charset=utf-8", "text/plain;charset=UTF-8", "text/plain", "UTF8_STRING"].first { types.contains($0) }
        let kind: ClipboardKind = mime?.hasPrefix("image/") == true ? .image : .text
        let result = try await history.ingest(offeredTypes: types, kind: kind) { [self] in
            guard let mime else { throw ClipboardFailure.invalid }
            let limit = kind == .image ? ClipboardHistory.imageLimit : ClipboardHistory.textLimit
            let bytes = try await read(token: token, mime: mime, limit: limit, bridge: bridge)
            if mime == "text/uri-list" {
                guard let text = String(data: bytes, encoding: .utf8) else { throw ClipboardFailure.invalid }
                let entries = text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                let files = !entries.isEmpty && entries.allSatisfy { URL(string: $0)?.isFileURL == true }
                guard files || (entries.count == 1 && ["http", "https"].contains(URL(string: entries[0])?.scheme)) else { throw ClipboardFailure.invalid }
                return ClipboardContent(kind: files ? .files : .url, data: Data(entries.joined(separator: "\n").utf8), mime: mime)
            }
            return ClipboardContent(kind: kind, data: bytes, mime: mime)
        }
        return try ControlResponse(value: result)
    }
    private func read(token: String, mime: String, limit: Int, bridge: GnomeBridge) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                pending = (token, done)
                if !bridge.push("clipboard-read", ["token": token, "mime": mime, "limit": String(limit)]) { cancelRead() }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    await self?.expire(token)
                }
            }
        } onCancel: { Task { await self.expire(token) } }
    }
    private func expire(_ token: String) { if pending?.token == token { cancelRead() } }
    func data(_ arguments: [String: String]) {
        guard let token = arguments["token"], let pending, pending.token == token else { return }
        self.pending = nil
        guard let encoded = arguments["content"], let bytes = Data(base64Encoded: encoded), bytes.count <= ClipboardHistory.imageLimit + 1 else {
            pending.continuation.resume(throwing: ClipboardFailure.invalid); return
        }
        pending.continuation.resume(returning: bytes)
    }
}
