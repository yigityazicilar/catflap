@testable import CatflapCore
import Foundation
import Testing

/// A clipboard command that fails for a reason outside clipboard history says that reason,
/// not "Cannot access clipboard history.", which sends a person looking in the wrong place.
@Suite struct ClipboardErrorTests {
    private struct UnlistedError: Error {}

    @Test func testAFailureOutsideHistoryIsReportedAsItself() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clip-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AgentPaths(directory: root.appendingPathComponent("data"))
        let runtime = try AgentRuntime(paths: paths)
        let store = await runtime.store
        let inbox = try TransferInbox(directory: paths.directory.appendingPathComponent("inbox"))
        let transfers = TransferService(store: store, inbox: inbox)
        let history = try await ClipboardHistory.open(store: store)
        try await ClipboardService(history: history, transfers: transfers, store: store, directory: paths.directory).install(on: runtime)
        try await store.saveDevice(DeviceRecord(id: "device-b", name: "Device B", clientPublicKey: "", address: "", pairSecret: Data(), build: "test"))
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10] + [UInt8](repeating: 7, count: 64))
        let added = try await history.ingest(offeredTypes: ["image/png"], kind: .image) { .init(kind: .image, data: png, mime: "image/png") }
        let id = try #require(added.id)
        // The outbox is a symlink: the agent refuses to write a copy through it.
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: paths.directory.appendingPathComponent("outbox"))
        try FileManager.default.createSymbolicLink(at: paths.directory.appendingPathComponent("outbox"), withDestinationURL: elsewhere)
        let response = await runtime.handle(.init("clip.send", arguments: ["id": id, "device_id": "device-b", "keep": "false"]))
        #expect(!response.ok)
        #expect(response.error == AgentError.unsafePath.rawValue, "clip.send said: \(response.error ?? "nothing")")
        await runtime.stop()
    }

    @Test func testAnUnlistedErrorIsNotCalledAHistoryFault() {
        let message = ClipboardService.failureMessage(for: UnlistedError())
        #expect(message != "Cannot access clipboard history.")
        #expect(message == ClipboardService.unexpectedFailure)
        #expect(ClipboardService.failureMessage(for: ClipboardFailure.missing) == ClipboardFailure.missing.rawValue)
        #expect(ClipboardService.failureMessage(for: AgentError.storage) == AgentError.storage.rawValue)
        #expect(ClipboardService.failureMessage(for: TransferFailure.tooLarge) == TransferFailure.tooLarge.errorDescription)
    }
}
