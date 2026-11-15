import CatflapCore
import Foundation
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
private func note(_ text: String) { FileHandle.standardError.write(Data(("TransferV1E2E: " + text + "\n").utf8)) }

private final class ThreeAgents: @unchecked Sendable {
    let a: AgentHarness, b: AgentHarness, c: AgentHarness
    init() throws { a = try AgentHarness(); b = try AgentHarness(); c = try AgentHarness() }
    var all: [AgentHarness] { [a, b, c] }
    func stop() { for agent in all { agent.stop() } }
}

/// Polls `command` on `agent` until `done` holds for the decoded row; a hang guard only.
private func poll<T: Decodable & Sendable>(_ agent: AgentHarness, _ arguments: [String], as type: T.Type, guardSeconds: Double = 180,
                                          until done: @escaping @Sendable (T) -> Bool) async throws -> T? {
    let deadline = ContinuousClock.now + .seconds(guardSeconds)
    while ContinuousClock.now < deadline {
        if let value = try? await offPool({ try agent.command(arguments) }).decode(T.self), done(value) { return value }
        try await Task.sleep(for: .milliseconds(250))
    }
    return nil
}

/// Pairs `first` with `second` through the CLI and returns each one's id for the other.
private func pair(_ first: AgentHarness, _ second: AgentHarness) async throws {
    var pairing = try await offPool { try first.command(["pair", "start"]) }.decode(PairingStatus.self)
    let startDeadline = ContinuousClock.now + .seconds(60)
    while pairing.state == .starting && ContinuousClock.now < startDeadline {
        try await Task.sleep(for: .milliseconds(200))
        pairing = try await offPool { try first.command(["pair", "status"]) }.decode(PairingStatus.self)
    }
    let code = try #require(pairing.code)
    #expect(try await offPool { try second.command(["pair", "join", code]) }.code == 0)
    for agent in [first, second] {
        _ = try await poll(agent, ["pair", "status"], as: PairingStatus.self, guardSeconds: 60) { $0.state == .confirm }
        #expect(try await offPool { try agent.command(["pair", "confirm"]) }.code == 0)
    }
    for agent in [first, second] {
        let end = try await poll(agent, ["pair", "status"], as: PairingStatus.self, guardSeconds: 60) { !$0.isActive }
        #expect(end?.state == .paired)
    }
}

private func inode(_ path: String) -> UInt64? {
    var info = stat()
    return stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
}

/// The four end-to-end runs of plan v4 features 2, 5 and 6, with real agents on this host:
/// a waiting delivery across a receiver restart, a resume after killing the receiver
/// mid-file, a folder with nested folders, a symlink and an unreadable file, and one send to
/// two devices with one away. Then the CLI's listing and cancelling, and `devices`.
@Suite(.timeLimit(.minutes(20)))
struct TransferV1E2E {
    @Test func testWaitingResumeFolderAndTwoDevices() async throws {
        let agents = try ThreeAgents(); defer { agents.stop() }
        for agent in agents.all {
            let store = try Store(paths: AgentPaths(directory: agent.dataDirectory))
            try await store.setSetting("inbox", value: agent.dataDirectory.appendingPathComponent("inbox").path)
        }
        try await offPool { for agent in agents.all { try agent.start() } }
        note("pair A with B, then A with C")
        try await pair(agents.a, agents.b)
        try await pair(agents.a, agents.c)
        let devices = try await offPool { try agents.a.command(["devices"]) }.decode([DeviceSummary].self)
        #expect(devices.count == 2)
        // Newest pairing first: C, then B.
        let c = devices[0].id, b = devices[1].id

        // 1. A waiting delivery across a receiver restart.
        note("run 1: waiting delivery across a receiver restart")
        agents.b.stop()
        let waited = try await offPool { try agents.a.command(["send", "--to", b, "--text", "delivered when B is back"], timeout: 120) }
        note("run 1: send exit \(waited.code)")
        #expect(waited.code == 75)
        let waitingRow = try waited.decode(TransferRecord.self)
        #expect(waitingRow.status == "waiting")
        try await offPool { try agents.b.start() }
        // "Try now", as the person would, instead of waiting out the 30 s backoff.
        _ = try? await offPool { try agents.a.command(["transfers", "retry", waitingRow.id, "--to", b]) }
        let delivered = try await poll(agents.a, ["transfers", "show", waitingRow.id, "--to", b], as: TransferRecord.self) { $0.status == "ok" }
        note("run 1: after B restarted, status \(delivered?.status ?? "not ok in time")")
        #expect(delivered?.status == "ok")
        let arrived = try await offPool { try agents.b.command(["history", "--search", "delivered when B is back"]) }.decode([TransferRecord].self)
        #expect(arrived.first?.direction == "received")

        // 2. A resume after killing the receiver mid-file.
        note("run 2: 256 MiB, receiver killed mid-file")
        let big = agents.a.dataDirectory.appendingPathComponent("big.bin")
        try await offPool {
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let file = try FileHandle(forWritingTo: big); defer { try? file.close() }
            let chunk = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            for index in 0..<256 { var block = chunk; block[0] = UInt8(truncatingIfNeeded: index); try file.write(contentsOf: block) }
        }
        let expected = try await offPool { try TransferInbox.hash(big) }
        let bInbox = agents.b.dataDirectory.appendingPathComponent("inbox")
        let sending = Task { try await offPool { try agents.a.command(["send", "--to", b, "--file", big.path], timeout: 600) } }
        // Kill B once more than two sync points' worth of the file is on its disk.
        var partPath: String?, partSize: Int64 = 0
        let killDeadline = ContinuousClock.now + .seconds(300)
        while partPath == nil && ContinuousClock.now < killDeadline {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: bInbox.path)) ?? [] where name.hasPrefix(".catflap-") && name.hasSuffix(".part") {
                let path = bInbox.appendingPathComponent(name).path
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
                if size >= 40 * 1024 * 1024 { partPath = path; partSize = size }
            }
            if partPath == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let part = try #require(partPath, "no part of 40 MiB appeared in B's inbox")
        let partInode = inode(part)
        agents.b.killAgent()
        note("run 2: killed B with \(partSize) bytes in its part")
        let cut = try await sending.value
        note("run 2: send exit \(cut.code)")
        #expect(cut.code == 75)
        let cutRow = try cut.decode(TransferRecord.self)
        #expect(cutRow.status == "waiting")
        try await offPool { try agents.b.start() }
        // Read B's row before asking A to try now: once A tries, the resume is under way and
        // the row says `receiving`.
        let interrupted = try await offPool { try agents.b.command(["transfers", "list", "--active"]) }.decode(TransferPage.self)
        note("run 2: B after restart lists \(interrupted.items.map(\.status))")
        #expect(interrupted.items.first?.status == "interrupted")
        _ = try? await offPool { try agents.a.command(["transfers", "retry", cutRow.id, "--to", b]) }
        let resumed = try await poll(agents.a, ["transfers", "show", cutRow.id, "--to", b], as: TransferRecord.self, guardSeconds: 400) { $0.status == "ok" }
        #expect(resumed?.status == "ok")
        let received = try await offPool { try agents.b.command(["history", "--search", "big.bin"]) }.decode([TransferRecord].self)
        let path = try #require(received.first?.path)
        let resumedInPlace = inode(path) == partInode
        note("run 2: published file is the part it resumed (same inode): \(resumedInPlace)")
        #expect(resumedInPlace)
        #expect(try await offPool { try TransferInbox.hash(URL(fileURLWithPath: path)) } == expected)

        // 3. A folder with nested folders, a symlink and an unreadable file.
        note("run 3: folder")
        let top = agents.a.dataDirectory.appendingPathComponent("Project")
        let fm = FileManager.default
        try fm.createDirectory(at: top.appendingPathComponent("src/deep/er"), withIntermediateDirectories: true)
        try fm.createDirectory(at: top.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: top.appendingPathComponent("README"))
        try Data("code".utf8).write(to: top.appendingPathComponent("src/main.swift"))
        try Data("deep".utf8).write(to: top.appendingPathComponent("src/deep/er/x.txt"))
        try fm.createSymbolicLink(at: top.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hostname"))
        let locked = top.appendingPathComponent("locked.txt")
        try Data("secret".utf8).write(to: locked); chmod(locked.path, 0)
        defer { chmod(locked.path, 0o600) }
        let folder = try await offPool { try agents.a.command(["send", "--to", b, top.path], timeout: 120) }
        note("run 3: send exit \(folder.code)")
        #expect(folder.code == 0)
        let folderRow = try folder.decode(TransferRecord.self)
        #expect(folderRow.kind == "folder" && folderRow.status == "ok")
        let skipped = Set((folderRow.skipped ?? []).map { $0.path.joined(separator: "/") + ":" + $0.reason })
        note("run 3: skipped \(skipped.sorted())")
        #expect(skipped == ["link:symlink", "locked.txt:unreadable"])
        let landed = bInbox.appendingPathComponent("Project")
        #expect(try Data(contentsOf: landed.appendingPathComponent("src/deep/er/x.txt")) == Data("deep".utf8))
        #expect(!fm.fileExists(atPath: landed.appendingPathComponent("link").path) && !fm.fileExists(atPath: landed.appendingPathComponent("locked.txt").path))
        var isFolder: ObjCBool = false
        #expect(fm.fileExists(atPath: landed.appendingPathComponent("empty").path, isDirectory: &isFolder) && isFolder.boolValue)

        // 4. One send to two devices, one away.
        note("run 4: one send to B and C, C away")
        agents.c.stop()
        let both = try await offPool { try agents.a.command(["send", "--to", b, "--to", c, "--text", "to both devices"], timeout: 120) }
        note("run 4: send exit \(both.code)")
        #expect(both.code == 75)
        let batch = try both.decode(TransferBatch.self)
        #expect(batch.transfers.count == 2 && Set(batch.transfers.map(\.sendID)) == [batch.sendID])
        let toB = try #require(batch.transfers.first(where: { $0.deviceID == b })), toC = try #require(batch.transfers.first(where: { $0.deviceID == c }))
        #expect(toB.status == "ok" && toC.status == "waiting")
        // The CLI lists what waits, and cancels by id.
        let waitingList = try await offPool { try agents.a.command(["transfers", "list", "--waiting"]) }.decode(TransferPage.self)
        #expect(waitingList.items.map(\.id) == [toC.id])
        try await offPool { try agents.c.start() }
        _ = try? await offPool { try agents.a.command(["transfers", "retry", toC.id, "--to", c]) }
        let lateC = try await poll(agents.a, ["transfers", "show", toC.id, "--to", c], as: TransferRecord.self) { $0.status == "ok" }
        note("run 4: C after its restart, status \(lateC?.status ?? "not ok in time")")
        #expect(lateC?.status == "ok")
        agents.c.stop()
        let doomed = try await offPool { try agents.a.command(["send", "--to", c, "--text", "never mind"], timeout: 120) }
        let doomedRow = try doomed.decode(TransferRecord.self)
        let cancelled = try await offPool { try agents.a.command(["transfers", "cancel", doomedRow.id]) }
        #expect(cancelled.code == 0)
        #expect(try await offPool { try agents.a.command(["transfers", "show", doomedRow.id]) }.decode(TransferRecord.self).status == "cancelled")

        // `devices` carries presence and peer state, never an endpoint.
        let listed = try await offPool { try agents.a.command(["devices"], timeout: 60) }
        let text = String(decoding: listed.output, as: UTF8.self)
        #expect(text.contains("\"peer_state\"") && text.contains("\"confirmed\"") && text.contains("\"presence\""))
        #expect(!text.contains("address") && !text.contains("endpoint"))
    }
}
