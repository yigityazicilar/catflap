import CatflapCore
import Foundation
import Testing

struct PlatformStatusTests {
    /// The clipboard watcher and the panel report separately. A later clipboard update, such
    /// as the watcher failing hours after start, must not reset the desktop the panel set.
    @Test func testAClipboardUpdateKeepsTheDesktop() async throws {
        let paths = try storeTestPaths()
        defer { removeStoreTestPaths(paths) }
        let runtime = try AgentRuntime(paths: paths)
        await runtime.updatePlatformStatus { $0.clipboardCapture = "active" }
        await runtime.updatePlatformStatus { $0.desktop = "layer-shell" }
        await runtime.updatePlatformStatus { $0.clipboardCapture = "failed" }
        let status = await runtime.platformStatus()
        #expect(status == PlatformStatus(desktop: "layer-shell", clipboardCapture: "failed"))
        await runtime.stop()
    }
}
