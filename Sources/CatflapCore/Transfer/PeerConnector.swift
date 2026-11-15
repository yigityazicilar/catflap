import Foundation
import Tailcat

/// How a device was reached: directly, or through a relay with its region code. Never the
/// endpoint itself.
public enum PeerPath: Sendable, Equatable {
    case direct
    case relayed(regionCode: String)
}
public struct PeerPing: Sendable, Equatable {
    public let latency: Duration
    public let path: PeerPath
    public init(latency: Duration, path: PeerPath) { self.latency = latency; self.path = path }
}
/// An authenticated connection to a paired device, for one transfer.
public struct PeerLink: Sendable {
    public let deviceID: String
    public let deviceName: String
    public let connection: WireConnection
    public let close: @Sendable () async -> Void
    public init(deviceID: String, deviceName: String, connection: WireConnection, close: @escaping @Sendable () async -> Void) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.connection = connection; self.close = close
    }
}
/// What transfers dial through: the peer service in the agent, a stand-in in tests, which
/// can then fail any frame write without a fault hook in the shipped binary.
public protocol PeerConnector: Sendable {
    func link(deviceID: String, timeout: Duration) async throws -> PeerLink
    /// Bounded by `timeout`. Throws when the device does not answer.
    func ping(deviceID: String, timeout: Duration) async throws -> PeerPing
}

extension PeerService: PeerConnector {
    public func link(deviceID: String, timeout: Duration) async throws -> PeerLink {
        let session = try await open(deviceID: deviceID, timeout: timeout)
        return PeerLink(deviceID: session.device.id, deviceName: session.device.name, connection: session.connection) { [weak self] in
            if let self { await self.release(session) } else { await session.close() }
        }
    }
}
