@testable import CatflapLinux
import CatflapCore
import Foundation
import XCTest

/// Which device a `ui invoke` send goes to, against an agent double: only the agent's own list
/// counts, and when its answer is an error or unreadable nothing is sent, even with a device
/// in the panel's own copy.
final class PanelDeviceTargetTests: XCTestCase {
    private let cached = PanelDevice(id: "cached-device", name: "Cached")

    /// An agent whose `devices` reply is `reply`, and which counts the sends asked of it.
    private func agent(_ reply: @escaping @Sendable () throws -> ControlResponse) async throws -> (AgentRuntime, Counter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dt-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = try AgentRuntime(paths: AgentPaths(directory: directory))
        let sends = Counter()
        await runtime.register("devices") { _ in try reply() }
        for command in ["send", "clip.send"] {
            await runtime.register(command) { _ in sends.add(); return ControlResponse(failure: "the double sends nothing") }
        }
        return (runtime, sends, directory)
    }

    private func check(_ reply: @escaping @Sendable () throws -> ControlResponse) async throws -> (Result<PanelDevice, SendRefusal>, Int) {
        let (runtime, sends, directory) = try await agent(reply)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = await PanelActionArguments.target(nil, runtime: runtime, selected: cached, missing: "No paired device. Pair one first.")
        return (outcome, sends.value)
    }

    func testAnErrorFromTheAgentRefusesWithoutSending() async throws {
        let (outcome, sends) = try await check { ControlResponse(error: .storage) }
        guard case .failure(let refusal) = outcome else { return XCTFail("sent to \(outcome)") }
        XCTAssertEqual(refusal.message, "Catflap could not read your paired devices. Try again.")
        XCTAssertEqual(sends, 0)
    }

    func testAnUnreadableListRefusesWithoutSending() async throws {
        let (outcome, sends) = try await check { try ControlResponse(value: ["devices": "not a list"]) }
        guard case .failure(let refusal) = outcome else { return XCTFail("sent to \(outcome)") }
        XCTAssertEqual(refusal.message, PanelActionArguments.unreadableDevices)
        XCTAssertEqual(sends, 0)
    }

    func testTheAgentsListDecidesNotThePanelsCopy() async throws {
        let fresh = DeviceSummary(DeviceRecord(id: "fresh-device", name: "Fresh", clientPublicKey: "unused", address: "unused",
                                               pairSecret: Data(), build: "test", pairedAt: Date(), lastSentAt: nil))
        let (outcome, _) = try await check { try ControlResponse(value: [fresh]) }
        XCTAssertEqual(try outcome.get(), PanelDevice(id: "fresh-device", name: "Fresh"))
    }

    func testAnEmptyListStillMeansNoPairedDevice() async throws {
        let (outcome, _) = try await check { try ControlResponse(value: [DeviceSummary]()) }
        guard case .failure(let refusal) = outcome else { return XCTFail("sent to \(outcome)") }
        XCTAssertEqual(refusal.message, "No paired device. Pair one first.")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
