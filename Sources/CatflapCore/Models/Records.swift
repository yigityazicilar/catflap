import Foundation

public struct DeviceRecord: Codable, Sendable, Identifiable, CustomStringConvertible, CustomReflectable {
    public var description: String { "DeviceRecord(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
    public var id: String
    public var name: String
    public var clientPublicKey: String
    public var address: String
    public var pairSecret: Data
    public var build: String
    public var pairedAt: Date
    public var lastSentAt: Date?
    public init(id: String, name: String, clientPublicKey: String, address: String, pairSecret: Data,
                build: String, pairedAt: Date = Date(), lastSentAt: Date? = nil) {
        self.id = id; self.name = name; self.clientPublicKey = clientPublicKey
        self.address = address; self.pairSecret = pairSecret; self.build = build
        self.pairedAt = pairedAt; self.lastSentAt = lastSentAt
    }
}

// Only this public projection may cross the ordinary CLI control channel.
public struct DeviceSummary: Codable, Sendable {
    public let id: String
    public let name: String
    public let build: String
    public let pairedAt: Date
    public let lastSentAt: Date?
    public init(_ device: DeviceRecord) {
        id = device.id; name = device.name; build = device.build
        pairedAt = device.pairedAt; lastSentAt = device.lastSentAt
    }
}

public struct HistoryRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var deviceID: String
    public var timestamp: Date
    public var direction: String
    public var kind: String
    public var size: Int64
    public var status: String
    public var text: String?
    public var path: String?
    public init(id: String = UUID().uuidString, deviceID: String, timestamp: Date = Date(),
                direction: String, kind: String, size: Int64, status: String, text: String? = nil, path: String? = nil) {
        self.id = id; self.deviceID = deviceID; self.timestamp = timestamp
        self.direction = direction; self.kind = kind; self.size = size
        self.status = status; self.text = text; self.path = path
    }
}
