import CTailcat
import Foundation

/// A TCP stream through the tunnel. One read and one write may run at the same time.
public final class TailcatConnection: Sendable {
    let owned: OwnedHandle
    /// The client or server that owns this connection; closing that object would end it.
    private let keepAlive: any Sendable

    var handle: tc_handle { owned.handle }

    init(handle: tc_handle, owner: tc_handle, keepAlive: any Sendable) {
        owned = OwnedHandle(handle, parent: owner)
        self.keepAlive = keepAlive
    }

    /// Reads up to `maxLength` bytes. Returns `nil` at end of stream.
    ///
    /// Bytes that arrived before a timeout are returned; the timeout then shows on the next
    /// read. If the Swift task is cancelled, the read throws `.cancelled` and any bytes it
    /// received are dropped, so a cancelled connection should be closed.
    public func read(upTo maxLength: Int = 64 * 1024, timeout: Duration? = nil) async throws -> Data? {
        guard maxLength > 0 else {
            throw TailcatError(.invalidArgument, "connection.read", detail: "maxLength must be positive")
        }
        let connection = owned.handle
        let result = try await BlockingCall.run("connection.read", resource: connection, timeout: timeout) { [owned] token in
            _ = owned
            var buffer = [UInt8](repeating: 0, count: maxLength)
            var count = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = buffer.withUnsafeMutableBytes {
                tc_conn_read(connection, token, $0.baseAddress, maxLength, &count, &error)
            }
            return CReturn(status: status, value: Data(buffer[0..<min(count, maxLength)]), message: takeCString(error))
        }
        if !result.value.isEmpty { return result.value }
        if result.status == statusEOF { return nil }
        if result.status == statusOK { return Data() }
        throw TailcatError(status: result.status, operation: "connection.read", message: result.message)
    }

    /// Writes all of `data` under one deadline. On failure some bytes may already have been
    /// sent, so the connection should not be reused for the same message.
    public func write(_ data: Data, timeout: Duration? = nil) async throws {
        let connection = owned.handle
        let bytes = [UInt8](data)
        let result = try await BlockingCall.run("connection.write", resource: connection, timeout: timeout) { [owned] token in
            _ = owned
            var written = 0
            var status = statusOK
            var message: String?
            bytes.withUnsafeBytes { raw in
                while written < raw.count {
                    var count = 0
                    var error: UnsafeMutablePointer<CChar>?
                    let pointer = UnsafeMutableRawPointer(mutating: raw.baseAddress! + written)
                    status = tc_conn_write(connection, token, pointer, raw.count - written, &count, &error)
                    message = takeCString(error)
                    written += count
                    if status != statusOK { break }
                    if count == 0 {
                        // A successful write that moved nothing would loop forever.
                        status = Int32(TC_FAILURE)
                        break
                    }
                }
            }
            return CReturn(status: status, value: written, message: message)
        }
        guard result.status == statusOK else {
            throw TailcatError(status: result.status, operation: "connection.write", message: result.message)
        }
    }

    /// Sends end-of-stream to the peer while keeping the read side open.
    public func closeWrite(timeout: Duration? = nil) async throws {
        let connection = owned.handle
        let result = try await BlockingCall.run("connection.closeWrite", resource: connection, timeout: timeout) { [owned] token in
            _ = owned
            var error: UnsafeMutablePointer<CChar>?
            let status = tc_conn_close_write(connection, token, &error)
            return CReturn(status: status, value: 0, message: takeCString(error))
        }
        guard result.status == statusOK else {
            throw TailcatError(status: result.status, operation: "connection.closeWrite", message: result.message)
        }
    }

    public func close() async {
        await owned.close()
    }
}
