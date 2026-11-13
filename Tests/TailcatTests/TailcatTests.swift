import CTailcat
import Crypto
import Foundation
import Synchronization
import Testing
@testable import Tailcat

// These tests open real tailcat tunnels through the public relays, so they need internet
// access. They share process-wide test hooks, hence one serialized suite.

private let port: UInt16 = 7447
private let generous: Duration = .seconds(60)

/// A value shared between a test and the hooks that run on call threads.
private final class Shared<Value: Sendable>: Sendable {
    private let state: Mutex<Value>
    init(_ value: Value) { state = Mutex(value) }
    var value: Value { state.withLock { $0 } }
    func update<R>(_ body: (inout Value) -> R) -> R { state.withLock { body(&$0) } }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func installHooks(_ hooks: TestHooks) {
    TestHooks.current.withLock { $0 = hooks }
}

private func clearHooks() {
    TestHooks.current.withLock { $0 = TestHooks() }
}

/// A started server with one listener, admitting `clientKeys`.
private struct Tunnel {
    let serverKeys: TailcatKeys
    let clientKeys: TailcatKeys
    let server: TailcatServer
    let listener: TailcatListener
    let info: TailcatServerInfo

    static func start(
        serverKeys: TailcatKeys? = nil, clientKeys: TailcatKeys? = nil, region: TailcatRegion? = nil
    ) async throws -> Tunnel {
        let serverKeys = try serverKeys ?? TailcatKeys.generate()
        let clientKeys = try clientKeys ?? TailcatKeys.generate()
        let server = try TailcatServer(config: .init(keys: serverKeys, allowedClients: [clientKeys.publicKey], region: region))
        let listener = try await server.listen(port: port, timeout: generous)
        let info = try await server.info(timeout: generous)
        return Tunnel(serverKeys: serverKeys, clientKeys: clientKeys, server: server, listener: listener, info: info)
    }

    /// Dials from an allowlisted client and accepts on the server side.
    func connect() async throws -> (client: TailcatClient, dialed: TailcatConnection, accepted: TailcatConnection) {
        let client = try TailcatClient(address: info.address, key: clientKeys)
        async let accepted = listener.accept(timeout: generous)
        let dialed = try await dialForSetup(client)
        return (client, dialed, try await accepted)
    }
}

/// Dials for test setup. In repeated local dials through the public relays about one dial in
/// a few hundred went unanswered until its deadline, through this wrapper and through the C API
/// alone, so setup retries a dial that timed out.
private func dialForSetup(_ client: TailcatClient) async throws -> TailcatConnection {
    for _ in 1..<3 {
        do {
            return try await client.dial(port: port, timeout: .seconds(15))
        } catch let error as TailcatError where error.code == .timeout {
            continue
        }
    }
    return try await client.dial(port: port, timeout: .seconds(15))
}

private func readAll(_ connection: TailcatConnection) async throws -> Data {
    var data = Data()
    while let chunk = try await connection.read(upTo: 256 * 1024, timeout: generous) {
        data.append(chunk)
    }
    return data
}

/// tc_close on a handle the wrapper already closed must report TC_CLOSED. Handles are never
/// reused, so this cannot close anything else.
private func closeStatus(_ handle: tc_handle) -> Int32 {
    var error: UnsafeMutablePointer<CChar>?
    let status = tc_close(handle, &error)
    if let error { tc_free(error) }
    return status
}

@Suite(.serialized)
struct TailcatTests {
    @Test func testRoundTripOneMiBMatchesSHA256() async throws {
        let tunnel = try await Tunnel.start()
        let (client, dialed, accepted) = try await tunnel.connect()
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<(1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })

        // The server reads everything, then echoes it back.
        async let serverSide: String = {
            let received = try await readAll(accepted)
            try await accepted.write(received, timeout: generous)
            try await accepted.closeWrite(timeout: generous)
            return sha256Hex(received)
        }()
        try await dialed.write(payload, timeout: generous)
        try await dialed.closeWrite(timeout: generous)
        let echoed = try await readAll(dialed)

        let sent = sha256Hex(payload)
        let receivedByServer = try await serverSide
        #expect(receivedByServer == sent)
        #expect(sha256Hex(echoed) == sent)
        #expect(echoed.count == 1024 * 1024)

        await client.close()
        await tunnel.server.close()
    }

    @Test func testUnlistedClientKeyCannotDial() async throws {
        let tunnel = try await Tunnel.start()
        let stranger = try TailcatClient(address: tunnel.info.address, key: TailcatKeys.generate())
        let started = ContinuousClock.now
        let error = await #expect(throws: TailcatError.self) {
            _ = try await stranger.dial(port: port, timeout: .seconds(15))
        }
        #expect(error?.code == .timeout)
        #expect(started.duration(to: .now) < .seconds(20))

        // Nothing reached the listener either.
        let acceptError = await #expect(throws: TailcatError.self) {
            _ = try await tunnel.listener.accept(timeout: .seconds(2))
        }
        #expect(acceptError?.code == .timeout)

        await stranger.close()
        await tunnel.server.close()
    }

    @Test func testCancelledAcceptResumesOnlyAfterTheCCallReturns() async throws {
        let tunnel = try await Tunnel.start()
        let listener = tunnel.listener.handle
        let events = Shared<[String]>([])
        let entered = Shared(false)
        let hookDelay = Duration.milliseconds(500)
        installHooks(TestHooks(
            beforeCCall: { report in
                if report.resource == listener && report.operation == "listener.accept" {
                    entered.update { $0 = true }
                }
            },
            afterCReturn: { report in
                guard report.resource == listener && report.operation == "listener.accept" else { return }
                events.update { $0.append("c-returned:\(report.status)") }
                // Hold the call thread after the C call returned. A wrapper that resumed the
                // Swift caller on cancellation instead of on return would resume during this.
                Thread.sleep(forTimeInterval: 0.5)
                events.update { $0.append("call-thread-done") }
            }
        ))
        defer { clearHooks() }

        let task = Task { () -> TailcatError? in
            do {
                _ = try await tunnel.listener.accept(timeout: generous)
                events.update { $0.append("swift-resumed:accepted") }
                return nil
            } catch let error as TailcatError {
                events.update { $0.append("swift-resumed") }
                return error
            } catch {
                events.update { $0.append("swift-resumed:other") }
                return nil
            }
        }
        while !entered.value { try await Task.sleep(for: .milliseconds(10)) }
        // Let the C call block inside accept; no client is dialing.
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let error = await task.value
        let waited = cancelledAt.duration(to: .now)

        #expect(events.value == ["c-returned:\(TC_CANCELLED)", "call-thread-done", "swift-resumed"])
        #expect(error?.code == .cancelled)
        #expect(waited >= hookDelay - .milliseconds(20))

        // The listener is still usable after a cancelled accept.
        clearHooks()
        let (client, _, accepted) = try await tunnel.connect()
        await accepted.close()
        await client.close()
        await tunnel.server.close()
    }

    @Test func testHandleReturnedDuringCancellationIsClosed() async throws {
        let tunnel = try await Tunnel.start()
        let listener = tunnel.listener.handle
        let acceptTask = Shared<Task<TailcatConnection, any Error>?>(nil)
        let returned = Shared<tc_handle>(0)
        installHooks(TestHooks(
            afterCReturn: { report in
                guard report.resource == listener && report.operation == "listener.accept",
                      report.status == Int32(TC_OK) else { return }
                returned.update { $0 = report.produced }
                // The C call has handed over a connection; cancel the Swift task now, so the
                // handle arrives after cancellation.
                while acceptTask.value == nil { Thread.sleep(forTimeInterval: 0.001) }
                acceptTask.value?.cancel()
            }
        ))
        defer { clearHooks() }

        let task = Task { try await tunnel.listener.accept(timeout: generous) }
        acceptTask.update { $0 = task }
        let client = try TailcatClient(address: tunnel.info.address, key: tunnel.clientKeys)
        let dialed = try await dialForSetup(client)

        let result = await task.result
        let handle = returned.value
        #expect(handle != 0)
        switch result {
        case .success:
            Issue.record("accept delivered a connection to a cancelled task")
        case .failure(let error):
            #expect((error as? TailcatError)?.code == .cancelled)
        }
        #expect(!HandleLedger.shared.isLive(handle))
        #expect(closeStatus(handle) == Int32(TC_CLOSED))

        // The wrapper closed the server side, so the dialer sees the stream end.
        let ended: Bool
        do { ended = try await dialed.read(timeout: .seconds(20)) == nil } catch { ended = (error as? TailcatError)?.code != .timeout }
        #expect(ended)

        await client.close()
        await tunnel.server.close()
    }

    @Test func testThousandCancelRacesLeaveNoLiveHandles() async throws {
        let tunnel = try await Tunnel.start()
        let client = try TailcatClient(address: tunnel.info.address, key: tunnel.clientKeys)
        let watched: Set<tc_handle> = [tunnel.listener.handle, client.handle]
        let issued = Shared<Set<tc_handle>>([])
        installHooks(TestHooks(afterCReturn: { report in
            guard watched.contains(report.resource) else { return }
            issued.update { set in
                set.insert(report.token)
                if report.produced != 0 { set.insert(report.produced) }
            }
        }))
        defer { clearHooks() }

        var accepted = 0, cancelledAccepts = 0, dialed = 0, cancelledDials = 0, timedOutDials = 0, unexpected = 0
        for round in 0..<1000 {
            let acceptTask = Task { try await tunnel.listener.accept(timeout: generous) }
            // Every other round a connection arrives, so cancellation races its delivery.
            let dialTask: Task<TailcatConnection, any Error>? =
                round % 2 == 0 ? Task { try await client.dial(port: port, timeout: .seconds(5)) } : nil
            try await Task.sleep(for: .microseconds(Int.random(in: 0...3000)))
            acceptTask.cancel()
            if round % 4 == 0 { dialTask?.cancel() }

            switch await acceptTask.result {
            case .success(let connection):
                accepted += 1
                await connection.close()
            case .failure(let error):
                if (error as? TailcatError)?.code == .cancelled { cancelledAccepts += 1 } else { unexpected += 1; print("round \(round): accept ended with \(error)") }
            }
            if let dialTask {
                switch await dialTask.result {
                case .success(let connection):
                    dialed += 1
                    await connection.close()
                case .failure(let error):
                    switch (error as? TailcatError)?.code {
                    case .cancelled: cancelledDials += 1
                    // An occasional dial goes unanswered (see dialForSetup); it still ends
                    // through the wrapper and is part of the handle accounting.
                    case .timeout: timedOutDials += 1
                    default: unexpected += 1; print("round \(round): dial ended with \(error)")
                    }
                }
            }
        }
        await client.close()
        await tunnel.server.close()

        let handles = issued.value.union([tunnel.server.handle, tunnel.listener.handle, client.handle])
        let liveInLedger = handles.filter { HandleLedger.shared.isLive($0) }.count
        let openInLibrary = handles.filter { closeStatus($0) != Int32(TC_CLOSED) }.count
        print("cancel races: accepted \(accepted), cancelled accepts \(cancelledAccepts), dialed \(dialed), cancelled dials \(cancelledDials), timed-out dials \(timedOutDials), handles checked \(handles.count)")
        #expect(unexpected == 0)
        #expect(cancelledAccepts > 0)
        #expect(accepted + cancelledAccepts == 1000)
        #expect(dialed + cancelledDials + timedOutDials == 500)
        #expect(timedOutDials <= 10)
        #expect(handles.count >= 1000)
        #expect(liveInLedger == 0)
        #expect(openInLibrary == 0)
    }

    @Test func testClosingServerEndsOpenConnections() async throws {
        let tunnel = try await Tunnel.start()
        let (client, dialed, accepted) = try await tunnel.connect()
        try await dialed.write(Data("ping".utf8), timeout: generous)
        let first = try await accepted.read(upTo: 4, timeout: generous)
        #expect(first == Data("ping".utf8))

        await tunnel.server.close()

        let serverSide = await #expect(throws: TailcatError.self) {
            _ = try await accepted.read(timeout: .seconds(5))
        }
        #expect(serverSide?.code == .closed)

        // The client side ends too: end of stream or an error, but not a wait for the deadline.
        let clientEnded: Bool
        do {
            clientEnded = try await dialed.read(timeout: .seconds(20)) == nil
        } catch {
            clientEnded = (error as? TailcatError)?.code != .timeout
        }
        #expect(clientEnded)
        await client.close()
    }

    @Test func testPinnedRegionKeepsAddressAcrossRestart() async throws {
        let serverKeys = try TailcatKeys.generate()
        let clientKeys = try TailcatKeys.generate()
        let first = try await Tunnel.start(serverKeys: serverKeys, clientKeys: clientKeys)
        let region = try #require(first.info.region)
        let storedAddress = first.info.address
        await first.server.close()

        let second = try await Tunnel.start(serverKeys: serverKeys, clientKeys: clientKeys, region: region)
        #expect(sha256Hex(Data(second.info.address.utf8)) == sha256Hex(Data(storedAddress.utf8)))
        #expect(second.info.region == region)

        // A client that kept the address from before the restart still connects.
        let client = try TailcatClient(address: storedAddress, key: clientKeys)
        async let accepted = second.listener.accept(timeout: generous)
        let dialed = try await dialForSetup(client)
        try await dialed.write(Data("after restart".utf8), timeout: generous)
        let received = try await accepted.read(timeout: generous)
        #expect(received == Data("after restart".utf8))

        await client.close()
        await second.server.close()
    }

    @Test func testErrorTextNeverContainsAnAddress() async throws {
        let tunnel = try await Tunnel.start()
        let address = tunnel.info.address
        var errors: [(String, TailcatError)] = []
        func record(_ label: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                Issue.record("\(label) did not fail")
            } catch let error as TailcatError {
                errors.append((label, error))
            } catch {
                Issue.record("\(label) threw a non-tailcat error")
            }
        }

        let truncated = String(address.prefix(address.count / 2))
        let extended = address + "x"
        await record("truncated address") {
            let client = try TailcatClient(address: truncated, key: tunnel.clientKeys)
            _ = try await client.dial(port: port, timeout: .seconds(5))
        }
        await record("address with trailing data") {
            let client = try TailcatClient(address: extended, key: tunnel.clientKeys)
            _ = try await client.dial(port: port, timeout: .seconds(5))
        }
        await record("allowlist entry built from the address") {
            _ = try TailcatServer(config: .init(keys: tunnel.serverKeys, allowedClients: [address]))
        }
        await record("empty allowlist") {
            _ = try TailcatServer(config: .init(keys: tunnel.serverKeys, allowedClients: []))
        }
        let (client, dialed, _) = try await tunnel.connect()
        await tunnel.server.close()
        let late = try TailcatClient(address: address, key: tunnel.clientKeys)
        await record("dial to a closed server") {
            _ = try await late.dial(port: port, timeout: .seconds(4))
        }
        await late.close()
        await dialed.close()
        await record("write on a closed connection") {
            try await dialed.write(Data("x".utf8), timeout: .seconds(4))
        }
        await client.close()

        #expect(errors.count == 6)
        let empty = errors.first { $0.0 == "empty allowlist" }?.1
        #expect(empty?.code == .invalidArgument)
        let closedWrite = errors.first { $0.0 == "write on a closed connection" }?.1
        #expect(closedWrite?.code == .closed)

        // Every 16-character window of the address, and the keys, count as a leak.
        let addressChars = Array(address)
        var fragments = stride(from: 0, to: max(1, addressChars.count - 15), by: 4).map {
            String(addressChars[$0..<min($0 + 16, addressChars.count)])
        }
        fragments += [truncated, extended] + tunnel.serverKeys.secrets + tunnel.clientKeys.secrets
        for (label, error) in errors {
            let texts = [String(describing: error), String(reflecting: error), error.localizedDescription, error.detail ?? ""]
            for text in texts {
                let leaks = fragments.filter { text.contains($0) }.count
                let showsIPLiteral = text.split(separator: " ").contains { word in
                    word.filter({ $0 == "." }).count >= 3 && word.allSatisfy({ "0123456789.:".contains($0) })
                        || word.lowercased().contains("fd7a:")
                }
                #expect(leaks == 0, "\(label): error text contains secret material")
                #expect(!showsIPLiteral, "\(label): error text contains an IP literal")
            }
        }

        // The value types that carry secrets do not print them either.
        let printed = [String(describing: tunnel.info), String(reflecting: tunnel.info), String(describing: tunnel.serverKeys)]
        let printedLeaks = printed.filter { text in fragments.contains { text.contains($0) } }.count
        #expect(printedLeaks == 0)
    }
}
