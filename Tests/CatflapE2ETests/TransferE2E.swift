import CatflapCore
import Foundation
import Synchronization
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private final class TransferE2EProgress: Sendable {
    private let stage = Mutex("start")
    private let finished = DispatchSemaphore(value: 0)
    init() {
        Thread.detachNewThread { [self] in
            if finished.wait(timeout: .now() + 360) == .timedOut {
                let message = "TransferE2E timed out at: " + stage.withLock { $0 } + "\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(70)
            }
        }
    }
    func mark(_ text: String) {
        stage.withLock { $0 = text }
        FileHandle.standardError.write(Data(("TransferE2E: " + text + "\n").utf8))
    }
    func finish() { finished.signal() }
}

private func transferOffPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
private final class TransferAgents: @unchecked Sendable {
    let first: AgentHarness
    let second: AgentHarness
    init() throws { first = try AgentHarness(); second = try AgentHarness() }
    func stop() { first.stop(); second.stop() }
}
@Suite(.timeLimit(.minutes(10)))
struct TransferE2E {
    @Test func testTextAnd64MiBEachWayThenRestartAndSend() async throws {
        let progress = TransferE2EProgress()
        defer { progress.finish() }
        progress.mark("create agents")
        let agents = try TransferAgents(); defer { progress.mark("stop agents"); agents.stop() }
        for agent in [agents.first, agents.second] {
            let store = try Store(paths: AgentPaths(directory: agent.dataDirectory))
            try await store.setSetting("inbox", value: agent.dataDirectory.appendingPathComponent("inbox").path)
        }
        progress.mark("start agents")
        try await transferOffPool { try agents.first.start(); try agents.second.start() }
        progress.mark("start pairing")
        var pairing = try await transferOffPool { try agents.first.command(["pair", "start"]) }.decode(PairingStatus.self)
        let startDeadline = ContinuousClock.now + .seconds(60)
        while pairing.state == .starting && ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(200))
            pairing = try await transferOffPool { try agents.first.command(["pair", "status"]) }.decode(PairingStatus.self)
        }
        progress.mark("join pairing")
        let code = try #require(pairing.code)
        #expect(try await transferOffPool { try agents.second.command(["pair", "join", code]) }.code == 0)
        for first in [true, false] {
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                let state = try await transferOffPool { try (first ? agents.first : agents.second).command(["pair", "status"]) }.decode(PairingStatus.self)
                if state.state == .confirm { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(try await transferOffPool { try (first ? agents.first : agents.second).command(["pair", "confirm"]) }.code == 0)
        }
        for first in [true, false] {
            let deadline = ContinuousClock.now + .seconds(60)
            var state: PairingStatus
            repeat {
                state = try await transferOffPool { try (first ? agents.first : agents.second).command(["pair", "status"]) }.decode(PairingStatus.self)
                if !state.isActive { break }
                try await Task.sleep(for: .milliseconds(200))
            } while ContinuousClock.now < deadline
            #expect(state.state == .paired)
        }
        for first in [true, false] {
            progress.mark(first ? "forward transfers" : "backward transfers")
            let text = "searchable transfer " + (first ? "forward" : "backward")
            let sentText = try await transferOffPool { try (first ? agents.first : agents.second).command(["send", "--text", text], timeout: 90) }
            #expect(sentText.code == 0)
            let textRow = try sentText.decode(TransferRecord.self)
            #expect(textRow.status == "ok")
            let receivedText = try await transferOffPool { try (first ? agents.second : agents.first).command(["history", "--search", text]) }.decode([TransferRecord].self)
            #expect(receivedText.first?.text == text && receivedText.first?.direction == "received")
            let source = (first ? agents.first : agents.second).dataDirectory.appendingPathComponent("large.bin")
            try await transferOffPool {
                FileManager.default.createFile(atPath: source.path, contents: nil)
                let file = try FileHandle(forWritingTo: source); defer { try? file.close() }
                let chunk = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
                for _ in 0..<64 { try file.write(contentsOf: chunk) }
            }
            let expected = try await transferOffPool { try TransferInbox.hash(source) }
            progress.mark(first ? "forward file" : "backward file")
            let sentFile = try await transferOffPool { try (first ? agents.first : agents.second).command(["send", "--file", source.path], timeout: 180) }
            #expect(sentFile.code == 0)
            let row = try sentFile.decode(TransferRecord.self)
            #expect(row.status == "ok" && row.size == 64 * 1024 * 1024 && row.sha256 == expected)
            let received = try await transferOffPool { try (first ? agents.second : agents.first).command(["history", "--search", "large.bin"]) }.decode([TransferRecord].self)
            let path = try #require(received.first?.path)
            #expect(try await transferOffPool { try TransferInbox.hash(URL(fileURLWithPath: path)) } == expected)
        }
        progress.mark("restart agents")
        try await transferOffPool { try agents.first.restart(); try agents.second.restart() }
        for first in [true, false] {
            progress.mark(first ? "forward after restart" : "backward after restart")
            let found = try await transferOffPool { try (first ? agents.first : agents.second).command(["history", "--search", "searchable transfer"]) }.decode([TransferRecord].self)
            #expect(found.count == 2)
            let result = try await transferOffPool { try (first ? agents.first : agents.second).command(["send", "--text", "after restart"], timeout: 90) }
            #expect(result.code == 0)
            #expect(try result.decode(TransferRecord.self).status == "ok")
        }
    }
}
