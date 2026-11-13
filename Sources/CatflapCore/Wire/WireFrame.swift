import Foundation

/// Wire protocol v2: frames of a 4-byte big-endian length and a JSON header of at most 64 KiB.
public enum WireProtocol {
    public static let version = 2
    public static let maxHeader = 64 * 1024
    /// The one TCP port the permanent server listens on inside the tunnel.
    public static let port: UInt16 = 7447
}

public enum WireError: Error, Sendable, Equatable {
    case frameTooLarge
    case emptyFrame
    case malformed
    case unexpected(String)
    case timedOut
    /// The stream ended inside a frame.
    case truncated
    case closed
}

/// A message carried in a frame header. `type` names it on the wire.
public protocol WireMessage: Codable, Sendable {
    static var type: String { get }
}

/// One decoded frame: its type and the exact header bytes it arrived as.
public struct WireFrame: Sendable {
    public let type: String
    public let header: Data

    public func decode<T: WireMessage>(_: T.Type) throws -> T {
        guard type == T.type else { throw WireError.unexpected(type) }
        do { return try JSONDecoder().decode(T.self, from: header) } catch { throw WireError.malformed }
    }
}

public enum WireCodec {
    private struct Envelope: Decodable { let type: String }

    /// The JSON header for `message`, with its `type` field added.
    public static func header<T: WireMessage>(_ message: T) throws -> Data {
        let fields = try JSONEncoder().encode(message)
        guard var object = try JSONSerialization.jsonObject(with: fields) as? [String: Any] else { throw WireError.malformed }
        object["type"] = T.type
        let header = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard header.count <= WireProtocol.maxHeader else { throw WireError.frameTooLarge }
        return header
    }

    /// A complete frame: length prefix and header.
    public static func frame(header: Data) throws -> Data {
        guard !header.isEmpty else { throw WireError.emptyFrame }
        guard header.count <= WireProtocol.maxHeader else { throw WireError.frameTooLarge }
        var length = UInt32(header.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(header)
        return frame
    }

    public static func frame<T: WireMessage>(_ message: T) throws -> Data {
        try frame(header: header(message))
    }

    /// Checks that `header` is a JSON object with a short string `type`.
    static func parse(header: Data) throws -> WireFrame {
        guard let object = try? JSONSerialization.jsonObject(with: header), object is [String: Any],
              let envelope = try? JSONDecoder().decode(Envelope.self, from: header),
              !envelope.type.isEmpty, envelope.type.utf8.count <= 64 else { throw WireError.malformed }
        return WireFrame(type: envelope.type, header: header)
    }
}

/// Incremental frame decoder. Input may come from a hostile peer: a length over the limit is
/// refused before any of the header is buffered.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedCount: Int { buffer.count }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete frame, or nil when more bytes are needed.
    public mutating func next() throws -> WireFrame? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0 else { throw WireError.emptyFrame }
        guard length <= WireProtocol.maxHeader else { throw WireError.frameTooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let header = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return try WireCodec.parse(header: header)
    }

    /// Takes up to `maxLength` buffered bytes that follow the last frame (payload bytes).
    public mutating func takeRaw(maxLength: Int) -> Data {
        let taken = Data(buffer.prefix(maxLength))
        buffer = Data(buffer.dropFirst(taken.count))
        return taken
    }
}
