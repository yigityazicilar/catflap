import Foundation
import Crypto

public struct TransferLimits: Sendable {
    public var textBytes: Int64 = 4 * 1024 * 1024
    public var fileBytes: Int64 = 20 * 1024 * 1024 * 1024
    public var imageBytes: Int64 = 20 * 1024 * 1024
    public var freeReserve: Int64 = 1024 * 1024 * 1024
    public var receivesPerDevice = 2
    public var idle: Duration = .seconds(30)
    public var dial: Duration = .seconds(30)
    /// A ping before each waiting delivery. tailcat resends its registration once a second,
    /// so anything under a few seconds can fail on a cold start alone.
    public var ping: Duration = .seconds(10)
    /// How long a waiting send waits, and how long a receiver keeps an interrupted part.
    public var waitLifetime: TimeInterval = 7 * 24 * 3600
    public var partLifetime: TimeInterval = 7 * 24 * 3600
    public var partsPerDevice = 8
    /// A receiver makes its part durable, and records how far, after this many bytes.
    public var syncEvery: Int64 = 16 * 1024 * 1024
    /// The longest a receiver may hold the sender with `hold` frames.
    public var maxHold: Duration = .seconds(1800)
    /// Devices the waiting queue serves at once.
    public var queueDevices = 4
    public var folder = FolderLimits()
    public init() {}
}
public enum TransferCommitPoint: String, CaseIterable, Sendable { case recorded, written, hashed, renamed, committed }
public enum TransferFailure: Error, LocalizedError, Sendable {
    case rejected(TransferRejectReason), invalid, missingRetryContent, crash
    case unknownDevice, unreadableFile, tooLarge, alreadySending, nothingToRetry
    case sourceChanged, sourceGone, folderChanged, folderLimit(FolderLimitError), isFolder, notFolder, notImage, cancelled, nothingToCancel
    public var errorDescription: String? {
        switch self {
        case .rejected(.tooLarge): "The other device refused it: too large."
        case .rejected(.noSpace): "The other device refused it: not enough free space there."
        case .rejected(.busy): "The other device is busy receiving. Try again in a moment."
        case .rejected(.duplicate): "The other device already has it."
        case .rejected(.invalid): "The other device refused it as invalid."
        case .rejected(.corrupt): "It arrived damaged, so the other device did not save it. Retry sends it again."
        case .rejected(.folderLimits): "The other device refused the folder: it is over the folder limits."
        case .invalid: "Invalid transfer."
        case .missingRetryContent: "Retry needs the original content."
        case .crash: "Transfer interrupted."
        case .unknownDevice: "No paired device has that id."
        case .unreadableFile: "Cannot read that file."
        case .tooLarge: "Too large to send."
        case .alreadySending: "That item is already being sent."
        case .nothingToRetry: "Nothing to retry under that id."
        case .sourceChanged: "The file changed after it was queued."
        case .sourceGone: "The file is gone."
        case .folderChanged: "The folder changed after it was queued: send it again."
        case .folderLimit(let limit): limit.sentence
        case .isFolder: "Use --folder for a folder."
        case .notFolder: "That is not a folder."
        case .notImage: "That is not an image Catflap can send."
        case .cancelled: "Cancelled."
        case .nothingToCancel: "Nothing to cancel under that id."
        }
    }
}
public enum TransferPayload: Sendable {
    case text(String)
    case file(URL)
    /// A clipboard image: a private copy of its bytes and its MIME type.
    case image(URL, mime: String)
    case folder(URL)
}
/// One send: to every device, every payload, each pair its own transfer and outcome.
public struct SendRequest: Sendable {
    public var deviceIDs: [String]
    public var payloads: [TransferPayload]
    public var keep = true
    /// Whether an item whose device is away waits for it. Never for a don't-keep item.
    public var wait = true
    public var intent = "deliver"
    public var clipKind: String?
    /// The transfer id, for a request with one device and one payload.
    public var id: String?
    public init(deviceIDs: [String], payloads: [TransferPayload], keep: Bool = true, wait: Bool = true,
                intent: String = "deliver", clipKind: String? = nil, id: String? = nil) {
        self.deviceIDs = deviceIDs; self.payloads = payloads; self.keep = keep; self.wait = wait
        self.intent = intent; self.clipKind = clipKind; self.id = id
    }
}
/// A device or file that got no transfer, and why.
public struct TransferRefusal: Codable, Sendable {
    public let deviceID: String?
    public let file: String?
    public let error: String
    enum CodingKeys: String, CodingKey { case file, error, deviceID = "device_id" }
    public init(deviceID: String?, file: String?, error: String) { self.deviceID = deviceID; self.file = file; self.error = error }
}
public struct TransferBatch: Codable, Sendable {
    public let sendID: String
    public let transfers: [TransferRecord]
    public let refused: [TransferRefusal]
    enum CodingKeys: String, CodingKey { case transfers, refused, sendID = "send_id" }
    public init(sendID: String, transfers: [TransferRecord], refused: [TransferRefusal]) { self.sendID = sendID; self.transfers = transfers; self.refused = refused }
}
/// What the platform module may want to tell the person.
public enum TransferEvent: Sendable {
    /// A waiting send gave up after its device stayed away for the whole wait.
    case expired(TransferRecord)
}
public protocol TransferClock: Sendable { func now() -> Date }
/// How the waiting queue's scheduler sleeps. Returns early when its task is cancelled.
public protocol TransferSleeper: Sendable { func sleep(seconds: Double) async }
public struct SystemTransferSleeper: TransferSleeper {
    public init() {}
    public func sleep(seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
}
public struct SystemTransferClock: TransferClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// The content of one outgoing item once prepared: hashed, and for a folder listed.
struct PreparedSource: Sendable {
    var kind: String
    var size: Int64
    var sha256: String
    var mime: String
    var name: String
    var text: Data?
    var url: URL?
    var stat: SourceStat?
    var manifest: FolderManifest?
}
/// One outgoing item while this agent runs.
struct OutgoingItem: Sendable {
    var row: TransferRecord
    var payload: TransferPayload
    var prepared: PreparedSource?
    /// Whether it waits for its device instead of failing.
    var waits: Bool
    var cancelRequested = false
}

public actor TransferService {
    public nonisolated let history: TransferHistory
    public let inbox: TransferInbox
    public let peers: PeerService?
    public var limits: TransferLimits
    let connector: (any PeerConnector)?
    let clock: any TransferClock
    let sleeper: any TransferSleeper
    var active: [String: Set<String>] = [:]
    var reservedBytes: Int64 = 0
    var outgoing: [String: OutgoingItem] = [:]
    var sending: Set<String> = []
    var results: [String: TransferRecord] = [:]
    var ephemeral: [String: (Date, String)] = [:]
    var ephemeralImages: [String: (Date, Data, String)] = [:]
    var inboxes: [String: TransferInbox] = [:]
    /// Receives under way, by device and id: what they show while running.
    var receiving: [String: TransferRecord] = [:]
    // Waiting queue: consecutive failed attempts per device, and devices being served.
    var failures: [String: Int] = [:]
    var serving: Set<String> = []
    var wake: AsyncStream<Void>.Continuation?
    var schedulerTask: Task<Void, Never>?
    var sweepTask: Task<Void, Never>?
    var receivedHandler: (@Sendable (String, String, ClipboardContent, Bool, String) async -> Void)?
    public func setReceivedHandler(_ handler: (@Sendable (String, String, ClipboardContent, Bool, String) async -> Void)?) { receivedHandler = handler }
    var eventHandler: (@Sendable (TransferEvent) async -> Void)?
    nonisolated var outbox: URL { history.store.paths.directory.appendingPathComponent("outbox") }
    public var freeBytesOverride: Int64?
    public var crashAt: TransferCommitPoint?
    public var dropAck = false

    public init(store: Store, inbox: TransferInbox, peers: PeerService? = nil, limits: TransferLimits = .init(),
                connector: (any PeerConnector)? = nil, clock: any TransferClock = SystemTransferClock(),
                sleeper: any TransferSleeper = SystemTransferSleeper()) {
        history = TransferHistory(store: store); self.inbox = inbox; self.peers = peers; self.limits = limits
        self.connector = connector ?? peers; self.clock = clock; self.sleeper = sleeper
    }
    public func configure(freeBytes: Int64? = nil, crashAt: TransferCommitPoint? = nil, dropAck: Bool = false) {
        freeBytesOverride = freeBytes; self.crashAt = crashAt; self.dropAck = dropAck
    }
    public func configure(limits: TransferLimits) { self.limits = limits }
    public func setEventHandler(_ handler: (@Sendable (TransferEvent) async -> Void)?) { eventHandler = handler }

    public func install(on runtime: AgentRuntime) async throws {
        try await reconcile()
        await peers?.setSessionHandler { [weak self] session, inbound in
            if inbound { await self?.receive(deviceID: session.device.id, connection: session.connection) }
        }
        await peers?.setContactHandler { [weak self] deviceID in await self?.peerSeen(deviceID: deviceID) }
        await runtime.provide(self)
        await TransferControl.register(self, on: runtime)
        startScheduler()
    }
    /// Ends the background work; transfers under way finish or fail on their own.
    public func stop() {
        schedulerTask?.cancel(); schedulerTask = nil
        sweepTask?.cancel(); sweepTask = nil
        wake?.finish(); wake = nil
    }

    // MARK: The folder received items go to

    /// The inbox new transfers use: the `inbox` setting if set, else the one this service
    /// was made with. Read at each admission, so a new choice applies at once.
    public func currentInbox() async throws -> TransferInbox {
        let configured = try await history.store.setting("inbox").flatMap { $0.isEmpty ? nil : $0 }
        guard let configured else { return inbox }
        if let cached = inboxes[configured] { return cached }
        let made = try TransferInbox(directory: URL(fileURLWithPath: configured), create: false)
        inboxes[configured] = made
        return made
    }
    /// Every folder a kept part lives in, for the audit.
    public func partDirectories() async throws -> [URL] {
        let rows = try await history.store.query("SELECT DISTINCT directory FROM parts")
        return rows.compactMap { if case .text(let path) = $0["directory"] { URL(fileURLWithPath: path) } else { nil } }
    }

    // MARK: Memory-only content

    public func copyText(deviceID: String, id: String, now: Date = Date()) async throws -> String? {
        let key = deviceID + "/" + id
        if let item = ephemeral[key] {
            if now.timeIntervalSince(item.0) < 600 { return item.1 }
            ephemeral[key] = nil
        }
        return try await history.record(deviceID: deviceID, id: id)?.text
    }
    /// A received image: from memory for 10 minutes when it was not kept, else its file.
    public func copyImage(deviceID: String, id: String, now: Date = Date()) async throws -> (data: Data, mime: String)? {
        let key = deviceID + "/" + id
        if let item = ephemeralImages[key] {
            if now.timeIntervalSince(item.0) < 600 { return (item.1, item.2) }
            ephemeralImages[key] = nil
        }
        guard let row = try await history.record(deviceID: deviceID, id: id), row.kind == "image", let path = row.path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (data, row.mime ?? "application/octet-stream")
    }
    func rememberText(_ text: String, key: String) {
        let created = Date()
        ephemeral[key] = (created, text)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            await self?.forgetMemory(key: key, created: created)
        }
    }
    func rememberImage(_ data: Data, mime: String, key: String) {
        let created = Date()
        ephemeralImages[key] = (created, data, mime)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            await self?.forgetMemory(key: key, created: created)
        }
    }
    private func forgetMemory(key: String, created: Date) {
        if ephemeral[key]?.0 == created { ephemeral[key] = nil }
        if ephemeralImages[key]?.0 == created { ephemeralImages[key] = nil }
    }
    func checkpoint(_ point: TransferCommitPoint) throws { if crashAt == point { throw TransferFailure.crash } }

    // MARK: Reading rows

    public func status(deviceID: String, id: String) async throws -> TransferRecord? {
        let key = deviceID + "/" + id
        if let row = results[key] {
            // The waiting details live in the store.
            if row.status == "waiting", let stored = try await history.record(deviceID: deviceID, id: id) {
                var merged = row; merged.waiting = stored.waiting; return merged
            }
            return try await withOpenable(row)
        }
        if let row = receiving[key] { return row }
        guard let row = try await history.record(deviceID: deviceID, id: id) else { return nil }
        return try await withOpenable(row)
    }
    public func list(_ query: TransferQuery) async throws -> TransferPage {
        let page = try await history.page(query)
        // Rows under way carry their progress and phase from memory.
        var items: [TransferRecord] = []
        for row in page.items {
            let key = row.deviceID + "/" + row.id
            var selected = row
            if var live = results[key] ?? receiving[key], live.status == row.status {
                live.waiting = row.waiting; selected = live
            }
            items.append(try await withOpenable(selected).listed)
        }
        return TransferPage(items: items, nextBefore: page.nextBefore)
    }

    private func withOpenable(_ record: TransferRecord) async throws -> TransferRecord {
        var row = record
        if row.direction == "received", row.kind == "text", row.status == "ok" {
            row.linkOpenable = try await copyText(deviceID: row.deviceID, id: row.id).flatMap(LinkNormalizer.normalize) != nil
        }
        return row
    }

    // MARK: Cancelling

    public func cancel(deviceID: String, id: String) async throws -> TransferRecord {
        let key = deviceID + "/" + id
        guard let row = try await status(deviceID: deviceID, id: id), row.canCancel else { throw TransferFailure.nothingToCancel }
        if row.direction == "received" {
            // An interrupted part this device keeps for the sender: gone now.
            try await dropPart(deviceID: deviceID, id: id, status: "cancelled")
            return try await history.record(deviceID: deviceID, id: id) ?? row
        }
        // A send under way stops at its next chunk and tells the other device.
        if sending.contains(key) { outgoing[key]?.cancelRequested = true }
        var cancelled = row
        cancelled.status = "cancelled"; cancelled.phase = nil; cancelled.error = nil; cancelled.waiting = nil
        try await history.store.execute("DELETE FROM queue WHERE device_id=? AND id=?", bindings: [.text(deviceID), .text(id)])
        try await history.save(cancelled)
        if ["file", "folder"].contains(row.kind) { try await rememberForget(deviceID: deviceID, id: id) }
        results[key] = cancelled
        try await cleanOwnedCopy(cancelled)
        return cancelled
    }
    public func cancel(sendID: String) async throws -> (cancelled: [TransferRecord], notCancelled: [(TransferRecord, String)]) {
        var done: [TransferRecord] = [], refused: [(TransferRecord, String)] = []
        for row in try await history.rows(sendID: sendID) {
            do { done.append(try await cancel(deviceID: row.deviceID, id: row.id)) }
            catch { refused.append((row, (error as? LocalizedError)?.errorDescription ?? "Cannot cancel it.")) }
        }
        return (done, refused)
    }
    func rememberForget(deviceID: String, id: String) async throws {
        try await history.store.execute("INSERT INTO forget(device_id,id,created_at) VALUES(?,?,?) ON CONFLICT DO NOTHING",
                                        bindings: [.text(deviceID), .text(id), .real(clock.now().timeIntervalSince1970)])
    }
    /// A folder's listing in the outbox is needed only while its send can still go.
    func cleanOwnedCopy(_ row: TransferRecord) async throws {
        guard row.direction == "sent", row.kind == "folder" else { return }
        let file = outbox.appendingPathComponent(row.id + ".manifest")
        if ["ok", "cancelled", "expired"].contains(row.status) || !row.keep { try? FileManager.default.removeItem(at: file) }
    }
}
