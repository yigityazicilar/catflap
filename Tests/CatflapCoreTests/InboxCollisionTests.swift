import CatflapCore
import Foundation
import Testing

/// Names at the 180-byte limit still get a numbered destination when one is taken: the
/// suffix's bytes are reserved by trimming the stem (then the extension), whole characters
/// only, and every candidate is one `url()` accepts.
@Suite struct InboxCollisionTests {
    private static let budget = 180
    /// ASCII and multibyte names at, or one character short of, the limit, with and without an
    /// extension. "€" is three bytes and "😀" four, so most of these cannot be cut on an
    /// arbitrary byte.
    private static let names: [String] = [
        String(repeating: "a", count: 180),
        String(repeating: "a", count: 176) + ".txt",
        String(repeating: "é", count: 90),
        String(repeating: "€", count: 60),
        "a" + String(repeating: "€", count: 59) + ".b",
        String(repeating: "😀", count: 44) + ".png",
        String(repeating: "名", count: 58) + ".jpeg",
        "x." + String(repeating: "e", count: 178),
        "x." + String(repeating: "€", count: 59),
    ]

    @Test func testRepeatedMaximumLengthCollisionsStayAcceptedAndKeepExistingBytes() throws {
        for name in Self.names {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-collision-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let inbox = try TransferInbox(directory: root)
            let clean = TransferInbox.clean(name)
            #expect(clean.utf8.count <= Self.budget)
            try Data("first".utf8).write(to: inbox.url(clean))
            var taken: Set<String> = [clean]
            // Twelve more: the suffix grows from " (1)" to " (12)", and must fit each time.
            for number in 1...12 {
                let candidate = inbox.availableName(name)
                let accepted = (try? inbox.url(candidate)) != nil
                #expect(accepted, "candidate \(number) for a \(clean.utf8.count)-byte name was refused")
                #expect(candidate.utf8.count <= Self.budget, "candidate \(number) is \(candidate.utf8.count) bytes")
                #expect(candidate == TransferInbox.clean(candidate))
                #expect(!taken.contains(candidate), "candidate \(number) repeats a taken name")
                #expect(candidate.hasSuffix(" (\(number))") || candidate.contains(" (\(number))."), "candidate \(number) has no suffix")
                guard accepted, !taken.contains(candidate) else { break }
                try Data("copy \(number)".utf8).write(to: inbox.url(candidate))
                taken.insert(candidate)
            }
            #expect(try Data(contentsOf: inbox.url(clean)) == Data("first".utf8))
        }
    }

    @Test func testSecondMaximumLengthReceiveGetsANumberedFile() async throws {
        let f = try TransferFixture(); defer { f.cleanup() }
        for name in [String(repeating: "a", count: 180), String(repeating: "€", count: 58) + ".bin"] {
            for copy in 0..<2 {
                let payload = Data("\(name.utf8.count)-\(copy)".utf8)
                await f.service.receive(deviceID: "peer", connection: WireConnection(TransferScript(
                    try transferInput(id: "\(name.utf8.count)-\(copy)", name: name, payload: payload))))
            }
        }
        let rows = try await f.service.history.rows()
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.status == "ok" }, "statuses: \(rows.map(\.status))")
        #expect(Set(rows.compactMap(\.targetName)).count == 4)
        for row in rows {
            let name = try #require(row.targetName)
            #expect(try Data(contentsOf: f.inbox.url(name)) == Data(row.id.utf8))
        }
    }
}
