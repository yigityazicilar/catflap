import CDataControl
import Foundation
import Glibc
import XCTest

final class WlrootsTransportTests: XCTestCase {
    func testTransportChoiceAndForeignActivationEdges() throws {
        for advertised in [["ext", "wlr"], ["wlr", "ext"], ["wlr"], ["ext"], []] {
            var ext: Int32 = 0
            var wlr: Int32 = 0
            for name in advertised {
                if name == "ext" { ext = 1 }
                if name == "wlr" { wlr = 1 }
            }
            let expected = ext != 0 ? CF_DC_EXT : wlr != 0 ? CF_DC_WLR : CF_DC_NONE
            XCTAssertEqual(cf_dc_choose_transport(ext, wlr), expected, "advertised: \(advertised)")
        }
        try checkPureCEdges()
    }

    private func checkPureCEdges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-edge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("edges.c")
        let executable = root.appendingPathComponent("edges")
        try """
        #include "CDataControl.h"
        #include <stdio.h>
        int main(void) {
            cf_wf_activation pulse = {0};
            cf_wf_activation_state(&pulse, 1);
            cf_wf_activation_state(&pulse, 0);
            int transient = cf_wf_activation_done(&pulse);
            int repeated_done = cf_wf_activation_done(&pulse);
            cf_wf_activation ordinary = {0};
            cf_wf_activation_state(&ordinary, 1);
            int plain = cf_wf_activation_done(&ordinary);
            cf_wf_activation_state(&ordinary, 1);
            int already_active = cf_wf_activation_done(&ordinary);
            printf("active-inactive-done=%d repeat-done=%d active-done=%d already-active=%d\\n",
                   transient, repeated_done, plain, already_active);
            return !(transient == 1 && repeated_done == 0 && plain == 1 && already_active == 0);
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = tree.appendingPathComponent("Sources/CDataControl")
        let compiler = try run("/usr/bin/cc", [source.path, sources.appendingPathComponent("ForeignActivation.c").path,
                                               "-I" + sources.appendingPathComponent("include").path, "-o", executable.path], root: root)
        XCTAssertEqual(compiler.status, 0, compiler.output)
        guard compiler.status == 0 else { return }
        let result = try run(executable.path, [], root: root)
        XCTAssertEqual(result.status, 0, "Pure C edge regression: " + result.output)
        XCTAssertTrue(result.output.contains("active-inactive-done=1"), result.output)
        XCTAssertTrue(result.output.contains("repeat-done=0 active-done=1 already-active=0"), result.output)
    }

    private func run(_ executable: String, _ arguments: [String], root: URL) throws -> (status: Int32, output: String) {
        let file = root.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = handle
        child.standardError = handle
        child.standardInput = FileHandle.nullDevice
        try child.run()
        let end = Date().addingTimeInterval(30)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate()
            let stop = Date().addingTimeInterval(5)
            while child.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            XCTFail("Pure C regression helper timed out")
            return (-1, "helper timed out")
        }
        return (child.terminationStatus, try String(contentsOf: file, encoding: .utf8))
    }
}
