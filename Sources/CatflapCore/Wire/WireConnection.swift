import Foundation
import Tailcat

/// The byte stream a wire connection runs over. A tailcat connection in the agent; tests may
/// wrap one to observe or alter what crosses it.
public protocol WireTransport: Sendable {
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data?
    func write(_ data: Data, timeout: Duration?) async throws
    func closeWrite(timeout: Duration?) async throws
    func close() async
}

extension TailcatConnection: WireTransport {}

/// Frames over a transport. One reader and one writer may run at the same time.
public actor WireConnection {
    public nonisolated let transport: any WireTransport
    private var decoder = FrameDecoder()
    private var closed = false
    /// Whether the peer has sent at least one byte. A connection that ends or stays silent
    /// without sending any is not treated as an attempt by anyone.
    public private(set) var receivedAnyByte = false

    public init(_ transport: any WireTransport) { self.transport = transport }

    /// The next frame, or nil when the stream ends cleanly before a new frame starts.
    public func readFrame(deadline: ContinuousClock.Instant) async throws -> WireFrame? {
        while true {
            if let frame = try decoder.next() { return frame }
            guard let data = try await readSome(deadline: deadline) else {
                if decoder.bufferedCount > 0 { throw WireError.truncated }
                return nil
            }
            decoder.append(data)
        }
    }

    public func readFrame(timeout: Duration) async throws -> WireFrame? {
        try await readFrame(deadline: .now + timeout)
    }

    /// Raw bytes after the last frame, for payloads. Nil at end of stream.
    public func readRaw(maxLength: Int, deadline: ContinuousClock.Instant) async throws -> Data? {
        let buffered = decoder.takeRaw(maxLength: maxLength)
        if !buffered.isEmpty { return buffered }
        while true {
            guard let data = try await readSome(deadline: deadline) else { return nil }
            if !data.isEmpty { return data.count > maxLength ? keepRest(data, maxLength) : data }
        }
    }

    private func keepRest(_ data: Data, _ maxLength: Int) -> Data {
        decoder.append(Data(data.dropFirst(maxLength)))
        return Data(data.prefix(maxLength))
    }

    private func readSome(deadline: ContinuousClock.Instant) async throws -> Data? {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw WireError.timedOut }
        do {
            guard let data = try await transport.read(upTo: 64 * 1024, timeout: remaining) else { return nil }
            if !data.isEmpty { receivedAnyByte = true }
            return data
        } catch let error as TailcatError {
            switch error.code {
            case .timeout: throw WireError.timedOut
            case .cancelled: throw CancellationError()
            case .eof: return nil
            default: throw WireError.closed
            }
        }
    }

    public func send<T: WireMessage>(_ message: T, timeout: Duration = .seconds(30)) async throws {
        try await write(WireCodec.frame(message), timeout: timeout)
    }

    /// Sends a header that was already encoded, so the bytes match what the caller hashed.
    public func send(header: Data, timeout: Duration = .seconds(30)) async throws {
        try await write(WireCodec.frame(header: header), timeout: timeout)
    }

    public func write(_ data: Data, timeout: Duration = .seconds(30)) async throws {
        do { try await transport.write(data, timeout: timeout) }
        catch let error as TailcatError { throw error.code == .timeout ? WireError.timedOut : WireError.closed }
    }

    public func closeWrite() async {
        try? await transport.closeWrite(timeout: .seconds(5))
    }

    /// Ends the stream after a last frame: half-closes, waits up to `timeout` for the peer to
    /// end its side, then closes. Closing at once can drop bytes not yet sent. Only for a
    /// connection no other task is reading.
    public func finish(timeout: Duration = .seconds(3)) async {
        await closeWrite()
        let deadline = ContinuousClock.now + timeout
        while let _ = try? await readRaw(maxLength: 64 * 1024, deadline: deadline) {}
        await close()
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await transport.close()
    }
}
