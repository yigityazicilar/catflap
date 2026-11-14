import CatflapCore
import Foundation
import Synchronization
import Testing

/// The row the stand-in agent reports once a send has ended.
private final class SendOutcome: Sendable {
    private let row = Mutex<TransferRecord?>(nil)
    func set(_ value: TransferRecord) { row.withLock { $0 = value } }
    func get() -> TransferRecord? { row.withLock { $0 } }
}

private func sendOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// What `catflap send` prints once a send has ended. The agent is a stand-in that answers
/// `send` and `send.status` with fixed rows, so the command's own output is what is under
/// test and no tunnel is needed.
@Suite(.timeLimit(.minutes(2)))
struct SendOutputE2E {
    @Test func testSendThatEndsBadlyPrintsItsReason() async throws {
        let harness = try AgentHarness()
        let directory = harness.dataDirectory.path
        let executable = harness.executable
        let paths = try AgentPaths(directory: harness.dataDirectory)
        let server = try ControlServer(paths: paths, lock: try AgentLock(paths: paths))
        let outcome = SendOutcome()
        let serving = Task.detached {
            await server.run { request in
                guard var row = outcome.get(), ["send", "send.status"].contains(request.command) else {
                    return ControlResponse(error: .invalidRequest, exitCode: 64)
                }
                // The first answer is the row as a send starts; the poll that follows gets its end.
                if request.command == "send" { row.status = "sending"; row.error = nil }
                return (try? ControlResponse(value: row)) ?? ControlResponse(error: .invalidRequest)
            }
        }
        func send(json: Bool) async throws -> CommandResult {
            try await sendOffPool {
                try runHarnessProcess(executable, arguments: ["send", "--to", "peer", "--text", "x", "--data-dir", directory] + (json ? ["--json"] : []))
            }
        }
        let refused = "The other device refused it: too large."
        let unconfirmed = "Not confirmed. The other device may have it; Retry will not send a second copy."
        // A row read back from the store carries no reason, so the command supplies one.
        let endings: [(status: String, reason: String?, said: String)] = [
            ("failed", refused, refused), ("failed", nil, "Not sent."), ("unconfirmed", nil, unconfirmed),
        ]
        for ending in endings {
            var row = TransferRecord(id: "probe", deviceID: "peer", direction: "sent", kind: "text", size: 1, status: ending.status)
            row.error = ending.reason
            outcome.set(row)

            // With --json: one object on standard output that says it failed, why, and which
            // transfer, in the shape every other failure has. Nothing on standard error.
            let json = try await send(json: true)
            #expect(json.code == 1)
            #expect(json.error.isEmpty)
            #expect(json.output.split(separator: UInt8(ascii: "\n")).count == 1)
            let object = try #require(try JSONSerialization.jsonObject(with: json.output) as? [String: Any])
            #expect(object["ok"] as? Bool == false)
            #expect(object["error"] as? String == ending.said)
            let transfer = try #require(object["transfer"] as? [String: Any])
            #expect(transfer["id"] as? String == "probe")
            #expect(transfer["status"] as? String == ending.status)
            #expect(transfer["can_retry"] as? Bool == true)

            // Without it: the reason on standard error, the row on standard output.
            let plain = try await send(json: false)
            #expect(plain.code == 1)
            #expect(String(decoding: plain.error, as: UTF8.self) == ending.said + "\n")
            #expect(try plain.decode(TransferRecord.self).status == ending.status)
        }

        // A send that ends well prints the row itself, either way.
        outcome.set(TransferRecord(id: "probe", deviceID: "peer", direction: "sent", kind: "text", size: 1, status: "ok"))
        for json in [true, false] {
            let sent = try await send(json: json)
            #expect(sent.code == 0)
            #expect(sent.error.isEmpty)
            #expect(try sent.decode(TransferRecord.self).status == "ok")
            let object = try #require(try JSONSerialization.jsonObject(with: sent.output) as? [String: Any])
            #expect(object["ok"] == nil && object["error"] == nil)
        }
        server.stop()
        await serving.value
    }
}
