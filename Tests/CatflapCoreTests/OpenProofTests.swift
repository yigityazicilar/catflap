import CatflapCore
import Foundation
import Synchronization
import Testing

/// A dial client whose transport is one end of a memory pipe, the other end answered by
/// `PeerOpen.accept`, and whose accepter side can rewrite what it writes.
final class PipeDialClient: PeerDialClient, @unchecked Sendable {
    let near: any WireTransport
    init(near: any WireTransport) { self.near = near }
    func dialTransport(port: UInt16, timeout: Duration?) async throws -> any WireTransport { near }
    func close() async {}
}
struct RewritingTransport: WireTransport {
    let inner: any WireTransport
    let rewrite: @Sendable (Data) -> Data
    func read(upTo maxLength: Int, timeout: Duration?) async throws -> Data? { try await inner.read(upTo: maxLength, timeout: timeout) }
    func write(_ data: Data, timeout: Duration?) async throws { try await inner.write(rewrite(data), timeout: timeout) }
    func closeWrite(timeout: Duration?) async throws { try await inner.closeWrite(timeout: timeout) }
    func close() async { await inner.close() }
}

/// Q5: the accepter's `ok` carries its own proof of the pairing secret, so the dialer never
/// hands a transfer to another device that holds the address.
@Suite struct OpenProofTests {
    static func open(tamper: Bool) async throws -> (Result<PeerSession, any Error>, [String]) {
        let paths = try storeTestPaths(); defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        let identity = await runtime.identityServer.identity
        let secret = Data(repeating: 9, count: 32)
        let accepterID = "accepter-device"
        let device = DeviceRecord(id: accepterID, name: "Device B", clientPublicKey: "unused", address: "unused", pairSecret: secret, build: "test")
        let dialerRecord = DeviceRecord(id: identity.id, name: "Device A", clientPublicKey: "unused", address: "unused", pairSecret: secret, build: "test")
        let (near, far) = MemoryPipe.make()
        let recorded = FaultTransport(wrapping: near)
        let accepterEnd = RewritingTransport(inner: far) { data in
            guard tamper, contains(data, "\"ok\""), let range = data.range(of: Data("\"hmac\":\"".utf8)) else { return data }
            var changed = data
            changed[range.upperBound] = changed[range.upperBound] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
            return changed
        }
        let accepting = Task {
            await PeerOpen.accept(WireConnection(accepterEnd), localID: accepterID) { id in id == dialerRecord.id ? dialerRecord : nil }
        }
        let opened: Result<PeerSession, any Error>
        do { opened = .success(try await PeerOpen.dial(device, identity: identity, build: "test", timeout: .seconds(10), client: PipeDialClient(near: recorded))) }
        catch { opened = .failure(error) }
        _ = await accepting.value
        return (opened, recorded.written)
    }

    @Test func testOkCarriesAReverseProofAndAWrongProofIsRefused() async throws {
        let (honest, honestFrames) = try await Self.open(tamper: false)
        #expect(throws: Never.self) { _ = try honest.get() }
        #expect(honestFrames == ["hello", "auth"])
        let (tampered, frames) = try await Self.open(tamper: true)
        #expect(throws: PeerError.wrongDevice(device: "Device B")) { _ = try tampered.get() }
        // Nothing after `auth`: no transfer frame reached a device that did not prove itself.
        #expect(frames == ["hello", "auth"])
    }
}
