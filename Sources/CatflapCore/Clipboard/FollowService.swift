import Foundation

/// Origin metadata is for loop prevention, never permission. Keep it on the same clipboard
/// offer as the content. Unknown/malformed markers must also suppress onward follow.
public struct ClipboardOrigin: Codable, Sendable {
    public static let macType = "org.catflap.clipboard-origin"
    public static let linuxType = "application/x-catflap-clipboard-origin"
    public let deviceID: String
    public let keep: Bool
    public init(deviceID: String, keep: Bool) { self.deviceID = deviceID; self.keep = keep }
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", keep }
}
public enum FollowPermission: String, Codable, Sendable { case unset, allowed, refused }
public enum LinkOpenPolicy: String, Codable, Sendable { case ask, always }
public struct FollowPrompt: Codable, Sendable {
    public let id: String
    public let deviceID: String
    public let kind: String
    public let expiresAt: Date
    public let url: String?
    enum CodingKeys: String, CodingKey { case id, kind, url, deviceID = "device_id", expiresAt = "expires_at" }
}
/// Implemented by the desktop adapter. Prompt delivery must return without waiting for an
/// answer; answer through FollowService.answer or its control command. Core owns validation.
public protocol FollowPlatform: Sendable {
    func writeClipboard(_ content: ClipboardContent, origin: ClipboardOrigin) async throws
    func requestPermission(_ prompt: FollowPrompt) async
    func openURL(_ url: URL) async throws
}
public enum LinkNormalizer {
    public static func normalize(_ input: String) -> URL? {
        // Shell copies commonly include one terminating LF, never embedded whitespace.
        let text = input.hasSuffix("\n") ? String(input.dropLast()) : input
        guard !text.isEmpty, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\"), let decoded = text.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        parts.scheme = scheme; parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let url = parts.url, url.host != nil else { return nil }
        return url
    }
}

public actor FollowService {
    private struct Pending {
        let prompt: FollowPrompt
        let content: ClipboardContent
        let keep: Bool
        let transferID: String
    }
    private let store: Store
    private let transfers: TransferService
    private let clock: any TransferClock
    private let sleeper: any TransferSleeper
    private var platform: (any FollowPlatform)?
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var prompted: Set<String> = []
    public init(store: Store, transfers: TransferService, clock: any TransferClock = SystemTransferClock(), sleeper: any TransferSleeper = SystemTransferSleeper()) {
        self.store = store; self.transfers = transfers; self.clock = clock; self.sleeper = sleeper
    }
    public func setPlatform(_ platform: (any FollowPlatform)?) async {
        self.platform = platform
        if let platform {
            for item in pending.values where item.prompt.expiresAt > clock.now() { await platform.requestPermission(item.prompt) }
        }
    }
    public func stop() { for task in timers.values { task.cancel() }; timers = [:]; pending = [:]; platform = nil }
    private var lastFailure: String?
    func transfersForInstallation() -> TransferService { transfers }
    func noteFailure(_ error: any Error) {
        // Only fixed messages: errors from platform implementations may contain content.
        lastFailure = error is ClipboardFailure ? "Invalid clipboard content." : "The desktop action could not be completed."
    }
    func requirePaired(_ deviceID: String) async throws {
        guard try await store.devices().contains(where: { $0.id == deviceID }) else { throw TransferFailure.unknownDevice }
    }
    public func settings(deviceID: String? = nil) async throws -> FollowSettings {
        if let deviceID { try await requirePaired(deviceID) }
        return try await FollowSettings(target: target(), deviceID: deviceID,
            permission: deviceID == nil ? nil : permission(deviceID: deviceID!),
            openPolicy: deviceID == nil ? nil : openPolicy(deviceID: deviceID!), lastFailure: lastFailure)
    }
    public func target() async throws -> String? { try await store.setting("clipboard.follow_to").flatMap { $0.isEmpty ? nil : $0 } }
    public func setTarget(_ deviceID: String?) async throws {
        if let deviceID { guard try await store.devices().contains(where: { $0.id == deviceID }) else { throw TransferFailure.unknownDevice } }
        try await store.setSetting("clipboard.follow_to", value: deviceID ?? "")
    }
    public func permission(deviceID: String) async throws -> FollowPermission {
        FollowPermission(rawValue: try await store.setting("clipboard.follow_permission." + deviceID) ?? "") ?? .unset
    }
    public func openPolicy(deviceID: String) async throws -> LinkOpenPolicy {
        LinkOpenPolicy(rawValue: try await store.setting("links.open_policy." + deviceID) ?? "") ?? .ask
    }
    public func setPermission(_ value: FollowPermission, deviceID: String) async throws {
        try await store.setSetting("clipboard.follow_permission." + deviceID, value: value.rawValue)
        let key = "follow/" + deviceID
        // Reset is an explicit invitation to ask again, even after an earlier refusal or
        // expired question. Existing held content is not written by this transition.
        if value == .unset { prompted.remove(deviceID) }
        if value != .unset, let item = take(key), item.prompt.expiresAt > clock.now() {
            try await retain(item)
            if value == .allowed { try await write(item.content, deviceID: deviceID, keep: item.keep) }
        }
    }
    public func setOpenPolicy(_ value: LinkOpenPolicy, deviceID: String) async throws {
        try await store.setSetting("links.open_policy." + deviceID, value: value.rawValue)
    }
    public func prompts() -> [FollowPrompt] {
        expire()
        return pending.values.map(\.prompt).sorted { $0.id < $1.id }
    }
    public func answer(id: String, allow: Bool) async throws {
        expire()
        guard let key = pending.first(where: { $0.value.prompt.id == id })?.key, let item = take(key) else { throw ClipboardFailure.missing }
        if item.prompt.kind == "follow" {
            try await retain(item)
            try await setPermission(allow ? .allowed : .refused, deviceID: item.prompt.deviceID)
            if allow { try await write(item.content, deviceID: item.prompt.deviceID, keep: item.keep) }
        } else if allow, let text = String(data: item.content.data, encoding: .utf8), let url = LinkNormalizer.normalize(text) {
            guard let platform else { throw AgentError.unsupported }
            try await platform.openURL(url)
        }
    }
    private func take(_ key: String) -> Pending? {
        timers.removeValue(forKey: key)?.cancel()
        return pending.removeValue(forKey: key)
    }
    public func expire() {
        let expired = pending.filter { $0.value.prompt.expiresAt <= clock.now() }.map(\.key)
        for key in expired { _ = take(key) }
    }
    private func hold(deviceID: String, id: String, kind: String, content: ClipboardContent, keep: Bool) async {
        expire()
        let key = kind + "/" + deviceID
        // At most one item per sender/intent and 32 total, all memory-only.
        guard pending[key] != nil || pending.count < 32 else { return }
        let previous = take(key)
        let newPrompt = FollowPrompt(id: UUID().uuidString, deviceID: deviceID, kind: kind, expiresAt: clock.now().addingTimeInterval(600), url: kind == "open" ? String(data: content.data, encoding: .utf8) : nil)
        let prompt = kind == "follow" ? (previous?.prompt ?? newPrompt) : newPrompt
        pending[key] = Pending(prompt: prompt, content: content, keep: keep, transferID: id)
        let sleeper = sleeper
        let remaining = max(0, prompt.expiresAt.timeIntervalSince(clock.now()))
        timers[key] = Task { [weak self] in await sleeper.sleep(seconds: remaining); if !Task.isCancelled { await self?.expire() } }
        // Follow asks once per sender until answered/restarted. Explicit Open actions each ask.
        if kind == "open" || (previous == nil && prompted.insert(deviceID).inserted) { await platform?.requestPermission(prompt) }
    }
    private func retain(_ item: Pending) async throws {
        try await transfers.retainFollowed(deviceID: item.prompt.deviceID, id: item.transferID, content: item.content)
    }
    private func write(_ content: ClipboardContent, deviceID: String, keep: Bool) async throws {
        guard let platform else { throw AgentError.unsupported }
        try await platform.writeClipboard(content, origin: ClipboardOrigin(deviceID: deviceID, keep: keep))
    }
    public func received(deviceID: String, id: String, content: ClipboardContent, keep: Bool, intent: String) async throws {
        if intent == "follow" {
            switch try await permission(deviceID: deviceID) {
            case .unset: await hold(deviceID: deviceID, id: id, kind: "follow", content: content, keep: keep)
            case .allowed:
                try await transfers.retainFollowed(deviceID: deviceID, id: id, content: content)
                try await write(content, deviceID: deviceID, keep: keep)
            case .refused:
                try await transfers.retainFollowed(deviceID: deviceID, id: id, content: content)
            }
        } else if intent == "open" {
            guard let text = String(data: content.data, encoding: .utf8), let url = LinkNormalizer.normalize(text) else { throw ClipboardFailure.invalid }
            if try await openPolicy(deviceID: deviceID) == .always {
                guard let platform else { throw AgentError.unsupported }; try await platform.openURL(url)
            } else { await hold(deviceID: deviceID, id: id, kind: "open", content: .text(url.absoluteString), keep: keep) }
        }
    }
    /// Called only after capture's gates and commit; marked origins never call this.
    public func recorded(id: String, content: ClipboardContent, keep: Bool, clipboard: ClipboardService) async throws {
        guard let target = try await target(), content.kind != .files else { return }
        let payload = try await clipboard.payload(forItem: id, keep: keep)
        _ = try await transfers.send(.init(deviceIDs: [target], payloads: [payload], keep: keep, wait: false, intent: "follow", clipKind: content.kind.rawValue))
    }
    public func open(deviceID: String, id: String) async throws {
        guard let row = try await transfers.status(deviceID: deviceID, id: id), row.direction == "received", row.status == "ok",
              let text = try await transfers.copyText(deviceID: deviceID, id: id), LinkNormalizer.normalize(text) != nil else { throw ClipboardFailure.invalid }
        try await received(deviceID: deviceID, id: id, content: .text(text), keep: row.keep, intent: "open")
    }
}
