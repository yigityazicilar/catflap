import Foundation

public struct TransferOffer: WireMessage {
    public static let type = "offer"
    public let id: String
    public let kind: String
    public let name: String
    public let size: Int64
    public let mime: String
    public let keep: Bool
    public init(id: String, kind: String, name: String, size: Int64, mime: String, keep: Bool = true) {
        self.id = id; self.kind = kind; self.name = name; self.size = size; self.mime = mime; self.keep = keep
    }
}
public struct TransferAccept: WireMessage { public static let type = "accept"; public init() {} }
public enum TransferRejectReason: String, Codable, Sendable { case tooLarge = "too_large", noSpace = "no_space", busy, duplicate }
public struct TransferReject: WireMessage {
    public static let type = "reject"
    public let reason: TransferRejectReason
    public init(_ reason: TransferRejectReason) { self.reason = reason }
}
public struct TransferDone: WireMessage {
    public static let type = "done"
    public let sha256: String
    public init(sha256: String) { self.sha256 = sha256 }
}
public struct TransferAck: WireMessage {
    public static let type = "ack"
    public let storedAs: String
    enum CodingKeys: String, CodingKey { case storedAs = "stored_as" }
    public init(storedAs: String) { self.storedAs = storedAs }
}
