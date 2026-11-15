import Foundation
import Testing
@testable import CatflapCore

@Suite(.serialized) struct SecretFilterFixtureTests {
    @Test func ordinaryFixturesAreRecorded() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lines = try String(contentsOf: root.appendingPathComponent("Fixtures/secret-filter/ordinary.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let verdicts = await offThread { lines.map { SecretFilter.rejects($0) } }
        for index in lines.indices { #expect(!verdicts[index], "ordinary fixture line \(index + 1)") }
    }
    @Test func versionAndAcronymExemptionsDoNotAcceptRandomTokens() async {
        let accepted = await offThread {
            var random = SeededGenerator(seed: 4129)
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
            var accepted = 0
            for index in 0..<500 {
                let body = String((0..<36).map { _ in alphabet.randomElement(using: &random)! })
                let candidate = index.isMultiple(of: 2) ? body + "_v2" : "HTTP" + body
                if !SecretFilter.rejects(candidate) { accepted += 1 }
            }
            return accepted
        }
        print("identifier exemption random draws: accepted \(accepted) of 500")
        #expect(accepted <= 32)
    }
    @Test func exactDigestsAreRecordedAfterKnownShapes() async {
        let verdicts = await offThread {
            [40,64,128].flatMap { length in
                [false,true].flatMap { upper in
                    let alphabet = upper ? "0123456789ABCDEF" : "0123456789abcdef"
                    let digest = String(String(repeating: alphabet, count: 8).prefix(length))
                    let prefix = length == 40 ? "sha1:" : length == 64 ? "sha256:" : "sha512:"
                    return [SecretFilter.rejects(digest), SecretFilter.rejects(" \n" + prefix + digest + "\n")]
                }
            }
        }
        #expect(verdicts.allSatisfy { !$0 })
        #expect(SecretFilter.rejects("gh" + "p_" + String(repeating: "a", count: 36)))
    }
}
func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: work()) }.start()
    }
}
