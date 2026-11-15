import Foundation

/// The transfer step's frames, protocol v3:
/// `forget`? → `offer` → `hold`* → `want_manifest` and the manifest (folders) →
/// `accept {offset}` or `reject` → payload bytes `[offset, size)` → `done` or `abort` →
/// `hold`* → `ack` or `reject`.
public struct TransferOffer: WireMessage {
    public static let type = "offer"
    public let id: String
    /// `text`, `file`, `image` or `folder`.
    public let kind: String
    public let name: String
    /// Content bytes; for a folder the sum of its files' sizes.
    public let size: Int64
    public let mime: String
    public let keep: Bool
    /// The content's SHA-256 in lower-case hex: of the bytes for text, file and image, the
    /// manifest digest for a folder. A part is resumed only for the same value.
    public let sha256: String
    /// `deliver`, `follow` or `open`. The receiver records it; core-follow gives it behaviour.
    public let intent: String
    /// With `intent: follow` only: `text`, `url` or `image`.
    public let clipKind: String?
    /// Folders only: the manifest's entry count, and how many entries the sender skipped.
    public let entries: Int?
    public let skipped: Int?
    enum CodingKeys: String, CodingKey { case id, kind, name, size, mime, keep, sha256, intent, entries, skipped, clipKind = "clip_kind" }
    public init(id: String, kind: String, name: String, size: Int64, mime: String, keep: Bool = true,
                sha256: String = "", intent: String = "deliver", clipKind: String? = nil, entries: Int? = nil, skipped: Int? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.size = size; self.mime = mime; self.keep = keep
        self.sha256 = sha256; self.intent = intent; self.clipKind = clipKind; self.entries = entries; self.skipped = skipped
    }
}
/// The receiver takes bytes from `offset` on: 0, or the length it holds of the same transfer.
public struct TransferAccept: WireMessage {
    public static let type = "accept"
    public let offset: Int64
    public init(offset: Int64 = 0) { self.offset = offset }
}
/// "Still preparing": each one extends the sender's wait by its idle limit, up to 30 minutes.
public struct TransferHold: WireMessage { public static let type = "hold"; public init() {} }
/// Folders only: the receiver asks for the manifest.
public struct WantManifest: WireMessage { public static let type = "want_manifest"; public init() {} }
public struct ManifestEntry: Codable, Sendable, Equatable {
    /// Components relative to the folder; separators are never parsed.
    public let path: [String]
    /// `dir` or `file`.
    public let type: String
    public let size: Int64?
    public let sha256: String?
    public init(path: [String], type: String, size: Int64? = nil, sha256: String? = nil) {
        self.path = path; self.type = type; self.size = size; self.sha256 = sha256
    }
}
public struct ManifestFrame: WireMessage {
    public static let type = "manifest"
    public let first: Int
    public let entries: [ManifestEntry]
    public init(first: Int, entries: [ManifestEntry]) { self.first = first; self.entries = entries }
}
public struct ManifestEnd: WireMessage {
    public static let type = "manifest_end"
    public let count: Int
    public init(count: Int) { self.count = count }
}
public enum TransferRejectReason: String, Codable, Sendable {
    case tooLarge = "too_large", noSpace = "no_space", busy, duplicate
    case invalid, corrupt, folderLimits = "folder_limits"
}
public struct TransferReject: WireMessage {
    public static let type = "reject"
    public let reason: TransferRejectReason
    /// With `folder_limits`: `entries`, `depth`, `name`, `path`, `size` or `manifest`.
    public let limit: String?
    public init(_ reason: TransferRejectReason, limit: String? = nil) { self.reason = reason; self.limit = limit }
}
public struct TransferDone: WireMessage {
    public static let type = "done"
    public let sha256: String
    public init(sha256: String) { self.sha256 = sha256 }
}
/// Sent instead of `done`: `cancelled` (the person cancelled) or `source_changed`.
public struct TransferAbort: WireMessage {
    public static let type = "abort"
    public let reason: String
    public init(reason: String) { self.reason = reason }
}
public struct TransferAck: WireMessage {
    public static let type = "ack"
    public let storedAs: String
    enum CodingKeys: String, CodingKey { case storedAs = "stored_as" }
    public init(storedAs: String) { self.storedAs = storedAs }
}
/// The sender gave these transfers up: the receiver drops their parts. At most 256 ids.
public struct TransferForget: WireMessage {
    public static let type = "forget"
    public let ids: [String]
    public init(ids: [String]) { self.ids = ids }
}
public struct TransferForgotten: WireMessage {
    public static let type = "forgotten"
    public let count: Int
    public init(count: Int) { self.count = count }
}
