import Foundation
import XCTest

final class GnomeE2E: XCTestCase {
    func testProductionExtensionAndAgent() throws {
        guard ProcessInfo.processInfo.environment["CATFLAP_GNOME_TEST"] == "1" else {
            throw XCTSkip("Run ci/gnome/run.sh swift test --filter GnomeE2E in its isolated Shell session")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<6 {
            let path = directory.appendingPathComponent("catflap")
            if FileManager.default.isExecutableFile(atPath: path.path) { executable = path; break }
            directory.deleteLastPathComponent()
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python")
        child.arguments = [repository.appendingPathComponent("ci/gnome/e2e.py").path, try XCTUnwrap(executable).path]
        child.currentDirectoryURL = repository
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run()
        let end = Date().addingTimeInterval(240)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning {
            child.terminate()
            XCTFail("GNOME scenario exceeded its hang guard")
        }
        let stopped = Date().addingTimeInterval(7)
        while child.isRunning && Date() < stopped { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(child.isRunning)
        if !child.isRunning { XCTAssertEqual(child.terminationStatus, 0) }
    }
}
